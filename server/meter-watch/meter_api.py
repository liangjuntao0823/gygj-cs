#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 电表云端值守 HTTP 同步层（meter_api）
=================================================
只做 App ↔ 值守引擎之间的小 JSON API，不做网页后台：

    GET  /api/meter/health    存活探针（无鉴权，不返回明细）
    POST /api/meter/enroll    {code, device} 用部署侧接入码换长期 bearer token
    GET  /api/meter/config    读取当前租户已同步配置（不回传完整 Bark key）
    PUT  /api/meter/config    全量同步开关/设置/电表清单（Bearer），写入后唤醒值守线程
    GET  /api/meter/state     读取最近一轮云端值守快照（App 进电表页时拉取）
    POST /api/meter/test-push 向该租户 Bark 设备发一条测试推送（Bearer）
    POST /api/meter/run-now 手动触发该租户立即轮询一轮（Bearer，10 秒节流，唤醒 worker 异步执行）

鉴权：除 health/enroll 外均需 `Authorization: Bearer <tenant token>`；
token 由 enroll 生成并作为 tenants.json 的键持久化（文件 600，部署时注意备份权限）。
初版为 HTTP 明文（第三方电表平台本身也是 HTTP），公网部署必须配合安全组强随机 token，
HTTPS 反代/证书作为随后的加固项，不在本文件内硬编码证书。

直接运行（systemd ExecStart）：
    python3 /opt/meter-watch/meter_api.py --config-dir /opt/meter-watch
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import threading
import time
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import meter_watch as mw

try:  # 生产部署：notify_hub.py 与本文件同目录（/opt/meter-watch）直接导入
    import notify_hub as nh
except ImportError:  # 本地源码树兜底：server/notify-hub 与 server/meter-watch 平级
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "notify-hub"))
    import notify_hub as nh

try:  # 房源板块（house-keeper）：生产同目录导入，本地源码树兜底
    import house_api as ha
    import house_store as hs
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "house-keeper"))
    import house_api as ha
    import house_store as hs

try:  # 管理后台（admin-console）：生产同目录导入，本地源码树兜底
    import admin_web as aw
    import admin_auth as aauth
    import admin_sys as asym
    import admin_meter as amet
    import admin_house as ahou
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "admin-console"))
    import admin_web as aw
    import admin_auth as aauth
    import admin_sys as asym
    import admin_meter as amet
    import admin_house as ahou

log = logging.getLogger("meter-watch.api")

BODY_LIMIT = 65536
ENROLL_WINDOW_SEC = 600
ENROLL_MAX_FAILS = 10


class CloudHandler(BaseHTTPRequestHandler):
    server_version = "meter-watch/1.0"
    protocol_version = "HTTP/1.1"

    # 接入码试错节流（所有请求线程共享）
    _enroll_lock = threading.Lock()
    _enroll_fails: dict[str, list[float]] = {}

    # run-now 手动立即轮询：同一租户两次触发最小间隔，防止连点导致集中请求电表平台被限流
    _run_now_lock = threading.Lock()
    _run_now_last: dict[str, float] = {}
    RUN_NOW_MIN_INTERVAL_SEC = 10.0

    # ---- 基础 ----
    def log_message(self, fmt: str, *args) -> None:
        # 成功请求保持 DEBUG 不刷屏；4xx/5xx 与错误行提升到 INFO，便于真机问题在 journal 定位。
        # 仅记录请求行/状态码/字节数，Authorization 令牌头与请求体不落日志。
        # 注意：BaseHTTPRequestHandler.log_request 传入的状态码是 str，log_error 第二参是错误文案，需统一解析。
        try:
            code_arg = args[1] if len(args) >= 2 else None
            code_num = int(code_arg) if str(code_arg).isdigit() else None
            noisy = code_num is None or code_num >= 400
            line = "http %s - %s" % (self.address_string(), fmt % args)
            if noisy:
                mw.log.info(line)
            else:
                mw.log.debug(line)
        except Exception:
            mw.log.debug("http log render failed: %r", args)

    @property
    def ctx(self):
        return self.server.ctx  # type: ignore[attr-defined]

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else "?"

    def _send(self, obj: dict, code: int = 200, extra_headers: dict[str, str] | None = None) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_json(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except (TypeError, ValueError):
            length = 0
        if length <= 0:
            return {}
        if length > BODY_LIMIT:
            return None
        try:
            raw = self.rfile.read(length)
            obj = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            return None
        return obj if isinstance(obj, dict) else None

    def _require_auth(self) -> tuple[str, dict] | None:
        token, tenant = self.ctx.store.tenant_for_token(self.headers.get("Authorization"))
        if not token or tenant is None:
            self._send({"ok": False, "error": "unauthorized"}, 401,
                       {"WWW-Authenticate": "Bearer"})
            return None
        return token, tenant

    @staticmethod
    def _enroll_rate_limited(ip: str) -> bool:
        now = time.time()
        with CloudHandler._enroll_lock:
            arr = [t for t in CloudHandler._enroll_fails.get(ip, []) if now - t < ENROLL_WINDOW_SEC]
            CloudHandler._enroll_fails[ip] = arr
            return len(arr) >= ENROLL_MAX_FAILS

    @staticmethod
    def _enroll_add_fail(ip: str) -> None:
        with CloudHandler._enroll_lock:
            CloudHandler._enroll_fails.setdefault(ip, []).append(time.time())

    @staticmethod
    def _enroll_clear(ip: str) -> None:
        with CloudHandler._enroll_lock:
            CloudHandler._enroll_fails.pop(ip, None)

    def _admin_route(self, method: str, path: str) -> bool:
        admin = getattr(self.ctx, "admin", None)
        if admin is None:
            return False
        return aw.route_request(self, method, path, admin)

    # ---- GET ----
    def do_GET(self) -> None:  # noqa: N802
        try:
            self._route_get()
        except Exception:
            log.exception("GET 处理异常 path=%s", self.path)
            self._send({"ok": False, "error": "server_error"}, 500)

    def _route_get(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if self._admin_route("GET", path):
            return
        if path == nh.PREFIX or path.startswith(nh.PREFIX + "/"):
            nh.route_request(self, "GET", path, self.ctx.hub)
            return
        if path == ha.PREFIX or path.startswith(ha.PREFIX + "/"):
            ha.route_request(self, "GET", path, self.ctx.house_store, self.ctx.hub)
            return
        if path == "/api/meter/health":
            tenants = self.ctx.store.load_tenants()
            enabled = sum(1 for t in tenants.values() if isinstance(t, dict) and t.get("enabled"))
            self._send({"ok": True, "service": "meter-watch", "time": mw.iso_now(),
                        "tenants": len(tenants), "enabled": enabled})
            return
        if path == "/api/meter/config":
            auth = self._require_auth()
            if not auth:
                return
            _, tenant = auth
            keys = list(tenant.get("bark_keys") or [])
            masked = [mw.mask_secret(k) for k in keys]
            self._send({
                "ok": True,
                "enabled": bool(tenant.get("enabled")),
                "device": tenant.get("device", ""),
                "updated_at": tenant.get("updated_at", ""),
                "settings": tenant.get("settings", {}),
                "meters": tenant.get("meters", []),
                "notifyUserBound": bool(tenant.get("notify_user_token")),
                "barkKeysCount": len(keys),
                "barkKeysMasked": masked,
                # 兼容下划线命名
                "bark_keys_count": len(keys),
                "bark_keys_masked": masked,
            })
            return
        if path == "/api/meter/state":
            auth = self._require_auth()
            if not auth:
                return
            token, tenant = auth
            self._send({"ok": True, **self._snapshot(token, tenant)})
            return
        self._send({"ok": False, "error": "not_found"}, 404)

    def _snapshot(self, token: str, tenant: dict) -> dict:
        doc = self.ctx.store.load_state_doc().get("tenants", {}).get(token, {}) or {}
        mstates = doc.get("meters", {}) if isinstance(doc.get("meters"), dict) else {}
        room_map = {str(m.get("uid")): str(m.get("room") or "")
                    for m in tenant.get("meters") or [] if isinstance(m, dict) and m.get("uid")}
        ordered: list[str] = []
        seen: set[str] = set()
        for m in tenant.get("meters") or []:
            uid = str((m or {}).get("uid") or "")
            if uid and uid not in seen:
                seen.add(uid)
                ordered.append(uid)
        for uid in mstates.keys():
            if uid not in seen:
                seen.add(uid)
                ordered.append(uid)
        meters = []
        for uid in ordered:
            ms = mstates.get(uid, {}) if isinstance(mstates.get(uid), dict) else {}
            meters.append({
                "uid": uid,
                "room": room_map.get(uid) or str(ms.get("room") or ""),
                "shengyu": float(ms.get("shengyu") or 0.0),
                "leiji": float(ms.get("leiji") or 0.0),
                "zhuangtai": str(ms.get("zhuangtai") or ""),
                "shijian": str(ms.get("shijian") or ""),
                "last_ok_ts": float(ms.get("last_ok_ts") or 0.0),
            })
        return {
            "server_time": mw.now_ts(),
            "enabled": bool(tenant.get("enabled")),
            "last_round_at": float(doc.get("last_round_at") or 0.0),
            "last_ok_at": float(doc.get("last_ok_at") or 0.0),
            "consecutive_failures": int(doc.get("consecutive_failures") or 0),
            "last_error": str(doc.get("last_error") or ""),
            "meters": meters,
        }

    # ---- POST ----
    def do_POST(self) -> None:  # noqa: N802
        try:
            self._route_post()
        except Exception:
            log.exception("POST 处理异常 path=%s", self.path)
            self._send({"ok": False, "error": "server_error"}, 500)

    def _route_post(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if self._admin_route("POST", path):
            return
        if path == nh.PREFIX or path.startswith(nh.PREFIX + "/"):
            nh.route_request(self, "POST", path, self.ctx.hub)
            return
        if path == ha.PREFIX or path.startswith(ha.PREFIX + "/"):
            ha.route_request(self, "POST", path, self.ctx.house_store, self.ctx.hub)
            return
        if path == "/api/meter/enroll":
            ip = self._client_ip()
            if self._enroll_rate_limited(ip):
                self._send({"ok": False, "error": "too_many_attempts"}, 429)
                return
            body = self._read_json()
            if body is None:
                self._send({"ok": False, "error": "bad_json"}, 400)
                return
            code = str(body.get("code") or "")
            device = str(body.get("device") or "")
            user_token = str(body.get("userToken") or body.get("user_token") or "")
            token = self.ctx.store.enroll(code, device, user_token=user_token)
            if not token:
                self._enroll_add_fail(ip)
                self._send({"ok": False, "error": "invalid_code"}, 403)
                return
            self._enroll_clear(ip)
            self._send({"ok": True, "token": token, "token_type": "Bearer"})
            return
        if path == "/api/meter/run-now":
            auth = self._require_auth()
            if not auth:
                return
            token, tenant = auth
            # 未开启云端轮询的租户不允许触发（App 按钮也只在开启后展示，服务端兜底）
            if not tenant.get("enabled"):
                self._send({"ok": False, "error": "poll_disabled",
                            "hint": "请先在电表设置开启云端轮询并完成同步"}, 409)
                return
            now = time.time()
            with CloudHandler._run_now_lock:
                last = CloudHandler._run_now_last.get(token, 0.0)
                if now - last < CloudHandler.RUN_NOW_MIN_INTERVAL_SEC:
                    retry_after = int(CloudHandler.RUN_NOW_MIN_INTERVAL_SEC - (now - last)) + 1
                    self._send({"ok": False, "error": "too_frequent",
                                "retry_after": retry_after}, 429)
                    return
                CloudHandler._run_now_last[token] = now
            # 定向唤醒：只把该租户放入 kick 集合，worker 唤醒分支取出后 run_all(only_token=)
            kick = getattr(self.ctx, "kick_tokens", None)
            kick_lock = getattr(self.ctx, "kick_lock", None)
            scoped = isinstance(kick, set)
            if scoped:
                if kick_lock is not None:
                    with kick_lock:
                        kick.add(token)
                else:
                    kick.add(token)
            wake = getattr(self.ctx, "wake", None)
            if wake is None:
                self._send({"ok": False, "error": "scheduler_unavailable"}, 503)
                return
            wake.set()  # worker wake 分支有 3s 合并防抖，并在后台线程执行，HTTP 立即返回避免 App 超时
            log.info("租户 %s 手动触发立即轮询 meters=%s scoped=%s",
                     mw.mask_secret(token, 6, 4), len(tenant.get("meters") or []), scoped)
            self._send({"ok": True, "queued": True, "scoped": scoped,
                        "note": "服务器约 3 秒后立即查询一轮，完成后更新云端快照，达到阈值或拉闸会推送"})
            return
        if path == "/api/meter/test-push":
            auth = self._require_auth()
            if not auth:
                return
            _, tenant = auth
            svc = self.ctx.store.svc
            user_token = str(tenant.get("notify_user_token") or "")
            # 已绑定统一推送用户：测试事件也走通知中心，顺带验证框架投递与设备隔离
            if user_token and getattr(self.ctx, "hub", None) is not None:
                try:
                    res = self.ctx.hub.dispatch(
                        user_token, "meter", "test",
                        "公寓管家云端值守测试", "收到此条说明统一推送通道（电表告警）链路正常。")
                    total = int(res.get("total") or 0)
                    if total > 0:
                        self._send({"ok": int(res.get("sent") or 0) > 0,
                                    "sent": int(res.get("sent") or 0), "total": total,
                                    "via": "notify-hub"})
                        return
                    if res.get("reason") in ("user_disabled", "module_disabled"):
                        self._send({"ok": False, "sent": 0, "total": 0,
                                    "error": "notify_disabled", "reason": res.get("reason")}, 409)
                        return
                except Exception:
                    log.exception("test-push 通知中心异常，降级 Bark 直推")
            keys = mw.Engine.tenant_keys(svc, tenant)
            if not keys:
                self._send({"ok": False, "sent": 0, "total": 0,
                            "error": "no_bark_device"})
                return
            ok, total = self.ctx.engine.pusher(svc).push_many(
                keys, "公寓管家云端值守测试", "收到此条说明云端电表告警推送链路正常。")
            self._send({"ok": ok > 0, "sent": ok, "total": total, "via": "legacy"})
            return
        self._send({"ok": False, "error": "not_found"}, 404)

    # ---- PUT ----
    def do_PUT(self) -> None:  # noqa: N802
        try:
            self._route_put()
        except Exception:
            log.exception("PUT 处理异常 path=%s", self.path)
            self._send({"ok": False, "error": "server_error"}, 500)

    def _route_put(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if self._admin_route("PUT", path):
            return
        if path != "/api/meter/config":
            self._send({"ok": False, "error": "not_found"}, 404)
            return
        auth = self._require_auth()
        if not auth:
            return
        token, _ = auth
        body = self._read_json()
        if body is None:
            self._send({"ok": False, "error": "bad_json_or_too_large"}, 400)
            return
        tenant = self.ctx.store.upsert_config(token, body)
        if tenant is None:
            self._send({"ok": False, "error": "unauthorized"}, 401)
            return
        wake = getattr(self.ctx, "wake", None)
        if wake is not None and tenant.get("enabled"):
            wake.set()   # 打开开关/同步后尽快跑一轮（worker 内有 3s 合并防抖）
        self._send({"ok": True, "enabled": bool(tenant.get("enabled")),
                    "meters": len(tenant.get("meters") or []),
                    "updated_at": tenant.get("updated_at", "")})

    # ---- 非常用方法：统一 JSON，避免 BaseHTTPRequestHandler 对未实现方法回裸 HTML 501（客户端解不出错误码，只会显示“服务器错误 HTTP 501”）----
    def do_DELETE(self) -> None:  # noqa: N802
        self._route_nonstandard("DELETE")

    def do_PATCH(self) -> None:  # noqa: N802
        self._route_nonstandard("PATCH")

    def do_OPTIONS(self) -> None:  # noqa: N802
        # 原生 App 不发 CORS 预检；这里兜底返回 Allow，避免默认 501
        self.send_response(204)
        self.send_header("Allow", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _route_nonstandard(self, method: str) -> None:
        try:
            path = self.path.split("?", 1)[0].rstrip("/") or "/"
            if self._admin_route(method, path):
                return
            if path == nh.PREFIX or path.startswith(nh.PREFIX + "/"):
                hub = getattr(self.ctx, "hub", None)
                if hub is None:
                    self._send({"ok": False, "error": "hub_unavailable"}, 503)
                    return
                # hub 对不支持的方法/子路径会回 JSON 401/405/404，保证客户端可解码
                nh.route_request(self, method, path, hub)
                return
            if path == ha.PREFIX or path.startswith(ha.PREFIX + "/"):
                ha.route_request(self, method, path, self.ctx.house_store, self.ctx.hub)
                return
            self._send({"ok": False, "error": "method_not_allowed"}, 405,
                       extra_headers={"Allow": "GET, POST, PUT, DELETE, OPTIONS"})
        except Exception:
            log.exception("%s 处理异常 path=%s", method, self.path)
            self._send({"ok": False, "error": "server_error"}, 500)


# ---------------------------------------------------------------------------
# 常驻入口：HTTP 线程 + 值守主线程
# ---------------------------------------------------------------------------

def serve(store: mw.Store, engine: mw.Engine) -> int:
    svc = store.svc
    host = str(svc.get("listen_host") or "0.0.0.0")
    port = int(svc.get("listen_port") or 8082)

    # 统一推送中心：同进程挂载 /api/notify/*，notify.json 与租户文件同目录（600）；
    # config 直接复用 meter service.json 的 enroll_code / bark_base，测试期不新增端口与配置文件
    hub = nh.HubRuntime(str(store.home / "notify.json"), config=svc)
    engine.hub = hub

    # 房源板块：SQLite 权威库。全新架构用独立空库 house_v2.db + media_v2/，
    # 不承接旧 house.db 存量（历史数据由用户后续自行导入迁移）；可用 HOUSE_DB 覆盖。
    import os
    house_db = str(store.home / os.environ.get("HOUSE_DB", "house_v2.db"))
    house_media = str(store.home / os.environ.get("HOUSE_MEDIA_DIR", "media_v2"))
    house_store = hs.HouseStore(house_db, media_root=house_media)

    # 管理后台：鉴权会话 + 服务器看板 + 电表值守 + 房源管理，复用现有 store/hub/house_store
    admin_auth = aauth.AdminAuth(store.home)
    admin_sys = asym.SystemBoard()
    admin_meter = amet.MeterConsole(store, hub)
    admin_house = ahou.HouseConsole(house_store)
    admin_ctx = types.SimpleNamespace(auth=admin_auth, sys=admin_sys,
                                       meter=admin_meter, house=admin_house, hub=hub)

    httpd = ThreadingHTTPServer((host, port), CloudHandler)
    httpd.daemon_threads = True
    wake = threading.Event()
    stop = threading.Event()
    httpd.ctx = types.SimpleNamespace(store=store, engine=engine, wake=wake, hub=hub,
                                      house_store=house_store, admin=admin_ctx,
                                      kick_lock=threading.Lock(), kick_tokens=set())

    server_thread = threading.Thread(target=httpd.serve_forever,
                                     kwargs={"poll_interval": 0.5}, daemon=True)
    server_thread.start()
    mw.log.info("meter-watch 同步 API 监听 http://%s:%s（探针 /api/meter/health）", host, port)
    mw.log.info("统一推送中心已挂载：/api/notify/health（数据 %s）", store.home / "notify.json")
    mw.log.info("首次接入码 enroll_code=%s（明文存于 %s，勿提交公开仓库）",
                mw.mask_secret(str(svc.get("enroll_code") or ""), 4, 4), store.service_path)

    import signal

    def _handle_stop(signum, _frame) -> None:
        mw.log.info("收到信号 %s，准备停止 meter-watch…", signum)
        stop.set()
        wake.set()

    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    # 常驻 worker 以固定细粒度 tick 唤醒：定时分支只跑“按各自间隔到期”的租户（间隔由 App 下发并随
    # tenants.json 每轮热加载，改间隔无需重启服务）；App 保存配置触发的 wake 仍立即全量跑一轮（3s 合并防抖）。
    tick_seconds = max(15, min(300, int(svc.get("scheduler_tick_seconds") or 30)))
    try:
        engine.run_all(startup=True)
    except Exception:
        mw.log.exception("启动首轮值守异常（不影响同步 API）")

    while not stop.is_set():
        awakened = wake.wait(timeout=tick_seconds)
        if stop.is_set():
            break
        if awakened:
            wake.clear()
            time.sleep(3)   # 合并 App 连续保存（设置+清单可能分多次 PUT）与 run-now 连点
            try:
                # run-now 定向触发：窗口内收集到的租户逐个只跑自己；普通配置保存唤醒（集合为空）仍全量一轮
                kick_tokens: set[str] = set()
                kick_lock = getattr(httpd.ctx, "kick_lock", None)
                kick_set = getattr(httpd.ctx, "kick_tokens", None)
                if isinstance(kick_set, set):
                    if kick_lock is not None:
                        with kick_lock:
                            kick_tokens |= kick_set
                            kick_set.clear()
                    else:
                        kick_tokens |= kick_set
                        kick_set.clear()
                if kick_tokens:
                    for kick_token in kick_tokens:
                        engine.run_all(startup=False, only_token=kick_token)
                else:
                    engine.run_all(startup=False)
            except Exception:
                mw.log.exception("唤醒值守轮询异常，下一轮重试")
        else:
            try:
                engine.run_all(startup=False, only_due=True)
                ha.deliver_pending(house_store, hub)  # 兜底：异步投递失败的 outbox 下轮补发
            except Exception:
                mw.log.exception("值守调度异常，下一 tick 重试")

    try:
        httpd.shutdown()
        httpd.server_close()
    except Exception:
        pass
    mw.log.info("meter-watch 已停止")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="公寓管家电表云端值守 API 服务")
    default_home = __import__("os").environ.get(
        "METER_WATCH_HOME", str(__import__("pathlib").Path(__file__).resolve().parent))
    parser.add_argument("--config-dir", default=default_home)
    parser.add_argument("--dry-run", action="store_true", help="Bark 只记录不实际发送")
    args = parser.parse_args(argv)

    store = mw.Store(args.config_dir)
    engine = mw.Engine(store, dry_run=args.dry_run)
    return serve(store, engine)


if __name__ == "__main__":
    raise SystemExit(main())
