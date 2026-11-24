#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 电表云端值守服务（meter-watch）
================================================
职责边界（用户拍板的架构）：
- App 是唯一设置入口：查询链接(openId)、阈值、提醒开关、电表清单（uid+房号）
  由 App 通过 meter_api.py 的鉴权接口全量同步到 tenants.json。
- 本文件只负责“执行面”：按固定间隔（默认 1800 秒=30 分钟）串行只读查询第三方
  电表平台 wy.mlh-china.com，做低电量/拉闸判定，走本机自建 Bark 推送，并把最近
  一轮读数写入 state.json 供 App 进页面时拉取云端快照。
- 不做任何资金/充值操作，不监听业务后台页面。

设计要点：
- 纯 Python 标准库，Ubuntu 24.04 自带 python3.12 可直接运行（服务器无 pip）。
- 多租户数据结构：tenants.json 以长期 bearer token 为键，本期 App 单用户也走该结构，
  以后多个微信身份/多个使用者只是多个 tenant，无需重构存储。
- worker 每轮重新从磁盘原子读取 tenants.json（API 进程可并发原子改写）；
  state.json 仅 worker 写，无跨线程写竞争。
- 告警去重状态持久化在 state.json：重启不轰炸；低电量/拉闸首次边沿立即推，
  持续异常按 *_remind_hours 复提醒，恢复合闸/回升阈值各推一条恢复（可关）。

本模块可独立 CLI：
    python3 meter_watch.py --validate     # 校验配置并打印摘要（不联网）
    python3 meter_watch.py --once         # 所有启用租户跑一轮（真实查询/推送）
    python3 meter_watch.py --once --dry-run   # 跑一轮但 Bark 只打印不发送
    python3 meter_watch.py --bindings     # 拉取首个租户微信身份下绑定户号清单
    python3 meter_watch.py --demo         # 向默认 Bark 设备发一条链路演示
    python3 meter_watch.py                # 默认转交 meter_api.serve（API + 值守线程）
"""

from __future__ import annotations

import argparse
import hmac
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

DEFAULT_BASE = "http://wy.mlh-china.com"
# 与 iOS 端 MeterQueryService.swift 内一致的微信 MicroMessenger UA（平台仅校验 UA/表单）
WECHAT_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.38(0x1800262b) "
    "NetType/WIFI Language/zh_CN"
)
PATH_INDEX = "kddz/electricmeterpost/index"
PATH_BIND_LIST = "kddz/electricmeterpost/getBindList"
PATH_METER_QUERY = "kddz/electricmeterpost/electricMeterQuery"

DEFAULT_SERVICE: dict[str, Any] = {
    # HTTP 同步 API（meter_api.py）监听地址；App 经公网访问，部署时用安全组+token+后续HTTPS保护
    "listen_host": "0.0.0.0",
    "listen_port": 8082,
    # 与本机 bark-server.service 回环通信（不经过 api.day.app）
    "bark_base": "http://127.0.0.1:8081",
    "default_bark_keys": [],          # 租户未自带 bark_keys 时使用的兜底设备 key（部署时写入）
    "poll_interval_seconds": 1800,    # 用户拍板：30 分钟一轮
    "request_interval_seconds": 1.5,  # 同一租户内串行查询间隔，对齐 App 限速，避免被平台风控
    "request_timeout_seconds": 12,
    "failure_alert_rounds": 3,        # 整组连续失败 N 轮后推一条运维告警
    "low_remind_hours": 24,           # 持续低电量复提醒间隔
    "off_remind_hours": 24,           # 持续拉闸复提醒间隔
    "notify_recovery": True,          # 恢复合闸/电量回升时推一条
    "startup_summary": True,          # 首次成功值守后推一条汇总（state 持久化，不随重启重复）
    "platform_base": DEFAULT_BASE,
    "enroll_code": "",                # 首次启动自动生成；App 用它换取长期 tenant token
}

MAX_METERS_PER_TENANT = 500
MAX_BARK_KEYS = 10

# 租户级云端轮询间隔（App「服务器轮询间隔」下发，单位秒）：快捷档 30/60/120 分钟，允许自定义 5～1440 分钟
DEFAULT_TENANT_POLL_SECONDS = 1800
MIN_TENANT_POLL_SECONDS = 300
MAX_TENANT_POLL_SECONDS = 86400

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [meter-watch] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("meter-watch")


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

def now_ts() -> float:
    return time.time()


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def mask_secret(s: str, head: int = 4, tail: int = 4) -> str:
    s = str(s or "")
    if len(s) <= head + tail:
        return "****" if s else ""
    return f"{s[:head]}…{s[-tail:]}"


def atomic_write_json(path: Path, obj: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chmod(tmp, mode)
    except OSError:
        pass
    os.replace(tmp, path)
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def read_json_file(path: Path, default: Any) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except (json.JSONDecodeError, OSError) as e:
        log.error("JSON 读取失败 %s: %s（使用默认值，不覆盖原文件）", path.name, e)
        return default


def to_float(v: Any, default: float = 0.0) -> float:
    try:
        if v is None or v == "":
            return default
        return float(v)
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# 第三方电表平台只读客户端（接口口径移植自 MeterQueryService.swift，勿随意改字段）
# ---------------------------------------------------------------------------

class PlatformError(Exception):
    """平台查询失败（网络/非 JSON/业务 code 非 0）。"""


class PlatformMeterError(PlatformError):
    """会话/网络正常，但单块电表无有效读数（平台对该表返回“查询失败”，多为电表离线/信号弱）。

    与鉴权/会话类 PlatformError 区分：这类错误重建 openId 会话没有意义，
    _query_one 不再重建会话放大请求，直接交由单表循环跳过并保留上一次成功读数。
    """


class MeterPlatformClient:
    def __init__(self, base: str = DEFAULT_BASE, timeout: float = 12.0,
                 request_interval: float = 1.5, sleeper: Callable[[float], None] | None = None):
        self.base = (base or DEFAULT_BASE).rstrip("/")
        self.timeout = timeout
        self.request_interval = request_interval
        self._sleep = sleeper or time.sleep

    # 测试可覆盖此方法返回带 read() 的假响应对象
    def _open(self, req: urllib.request.Request, timeout: float):
        return urllib.request.urlopen(req, timeout=timeout)  # noqa: S310（明文 HTTP 为第三方平台现状）

    def _post(self, path: str, fields: dict[str, str]) -> dict[str, Any]:
        url = f"{self.base}/{path}"
        data = urllib.parse.urlencode(fields).encode("utf-8")
        headers = {
            "User-Agent": WECHAT_UA,
            "X-Requested-With": "XMLHttpRequest",
            "Origin": self.base,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/x-www-form-urlencoded",
        }
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            resp = self._open(req, self.timeout)
            raw = resp.read()
        except urllib.error.HTTPError as e:
            try:
                e.read()
            except Exception:
                pass
            raise PlatformError(f"HTTP {e.code}") from e
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise PlatformError(f"网络错误: {e}") from e
        try:
            obj = json.loads(raw.decode("utf-8", "replace"))
        except Exception as e:
            raise PlatformError("平台返回非 JSON") from e
        if not isinstance(obj, dict):
            raise PlatformError("平台返回结构异常")
        return obj

    @staticmethod
    def _data_dict(obj: dict[str, Any]) -> dict[str, Any]:
        data = obj.get("data")
        return data if isinstance(data, dict) else {}

    def index_open_id(self, open_id: str) -> str:
        """openId -> 平台会话 wechatId（Int 形态，仅运行期内存/state 缓存）。"""
        obj = self._post(PATH_INDEX, {"openId": open_id})
        if obj.get("code") != 0:
            raise PlatformError(f"建立会话失败 code={obj.get('code')} msg={obj.get('msg')}")
        data = obj.get("data")
        wid = ""
        if isinstance(data, dict):
            wid = str(data.get("wechatId") or data.get("wechatUserId") or "")
        elif data is not None:
            wid = str(data)
        if not wid or wid == "None":
            raise PlatformError("平台未返回 wechatId（查询链接可能已失效，请在 App 重新粘贴微信链接）")
        return wid

    def fetch_bindings(self, wechat_id: str) -> list[str]:
        obj = self._post(PATH_BIND_LIST, {"wechatUserId": str(wechat_id)})
        if obj.get("code") != 0:
            raise PlatformError(f"拉取绑定失败 code={obj.get('code')} msg={obj.get('msg')}")
        data = obj.get("data")
        rows = data if isinstance(data, list) else (data or {}).get("list", []) if isinstance(data, dict) else []
        out: list[str] = []
        for row in rows or []:
            uid = ""
            if isinstance(row, dict):
                uid = str(row.get("bindMeterId") or row.get("electricUserUid") or row.get("meterId") or "")
            elif row is not None:
                uid = str(row)
            uid = uid.strip()
            if uid and uid not in out:
                out.append(uid)
        return out

    def query_meter(self, wechat_id: str, uid: str) -> dict[str, Any]:
        obj = self._post(PATH_METER_QUERY, {"wechatUserId": str(wechat_id), "electricUserUid": str(uid)})
        if obj.get("code") != 0:
            raise PlatformError(f"查询失败 code={obj.get('code')} msg={obj.get('msg')}")
        data = self._data_dict(obj)
        if not data:
            raise PlatformError("查询返回空 data")
        raw_shengyu = data.get("shengyu", "")
        # 平台对离线/弱信号电表会在 code=0、data 内回中文“查询失败”（几个字段同为该文案），
        # 必须识别为该表本轮失败：不能当数值 0，更不能据此误判拉闸/低电量或污染快照时间戳。
        try:
            shengyu_num = float(str(raw_shengyu).strip())
        except (TypeError, ValueError):
            raise PlatformMeterError(
                f"电表 {uid} 平台返回“{raw_shengyu or '查询失败'}”（可能离线/信号弱，保留上次读数）"
            ) from None
        if shengyu_num < 0:
            raise PlatformMeterError(f"电表 {uid} 返回负电量 {shengyu_num:g}，按异常读数跳过")
        return {
            "shengyu": data.get("shengyu", ""),
            "leiji": data.get("leiji", ""),
            "zhuangtai": str(data.get("zhuangtai", "") or ""),
            "shijian": str(data.get("shijian", "") or ""),
        }

    def query_with_retry(self, wechat_id: str, uid: str, retries: int = 1) -> dict[str, Any]:
        last: Exception | None = None
        for attempt in range(retries + 1):
            try:
                return self.query_meter(wechat_id, uid)
            except PlatformError as e:
                last = e
                if attempt < retries:
                    self._sleep(self.request_interval)
        assert last is not None
        raise last


# ---------------------------------------------------------------------------
# Bark 推送（自建 bark-server，POST {bark_base}/push）
# ---------------------------------------------------------------------------

class BarkPusher:
    def __init__(self, base: str, timeout: float = 8.0, dry_run: bool = False):
        self.base = (base or "http://127.0.0.1:8081").rstrip("/")
        self.timeout = timeout
        self.dry_run = dry_run
        self.sent: list[dict[str, Any]] = []   # dry_run 时留存供测试/演示断言

    def push(self, device_key: str, title: str, body: str, opts: dict[str, Any] | None = None) -> bool:
        key = (device_key or "").strip()
        if not key:
            return False
        payload: dict[str, Any] = {
            "device_key": key,
            "title": title,
            "body": body,
            "group": "公寓管家电表",
            "isArchive": 1,
        }
        if opts:
            payload.update({k: v for k, v in opts.items() if v is not None})
        if self.dry_run:
            self.sent.append(payload)
            log.info("[dry-run] Bark -> %s | %s | %s", mask_secret(key), title, body)
            return True
        try:
            req = urllib.request.Request(
                f"{self.base}/push",
                data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                headers={"Content-Type": "application/json; charset=utf-8"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # noqa: S310
                obj = json.loads(resp.read().decode("utf-8", "replace"))
            ok = obj.get("code") == 200
            if not ok:
                log.warning("Bark 返回非成功 key=%s resp=%s", mask_secret(key), str(obj)[:200])
            return ok
        except Exception as e:  # 推送失败不能打断值守轮询
            log.warning("Bark 推送异常 key=%s err=%s", mask_secret(key), e)
            return False

    def push_many(self, keys: list[str], title: str, body: str,
                  opts: dict[str, Any] | None = None, interval: float = 0.2) -> tuple[int, int]:
        keys = [k.strip() for k in (keys or []) if k and k.strip()]
        ok = 0
        for i, key in enumerate(keys):
            if self.push(key, title, body, opts):
                ok += 1
            if i < len(keys) - 1 and interval > 0:
                time.sleep(interval)
        if keys:
            log.info("Bark 推送完成 %d/%d：%s", ok, len(keys), title)
        return ok, len(keys)


# ---------------------------------------------------------------------------
# 持久化存储：service.json（运维侧）/ tenants.json（API 写）/ state.json（worker 写）
# ---------------------------------------------------------------------------

class Store:
    def __init__(self, home: str | Path):
        self.home = Path(home)
        self.home.mkdir(parents=True, exist_ok=True)
        self.service_path = self.home / "service.json"
        self.tenants_path = self.home / "tenants.json"
        self.state_path = self.home / "state.json"
        self.svc = self.load_service()

    # ---- service ----
    def load_service(self) -> dict[str, Any]:
        loaded = read_json_file(self.service_path, {})
        if not isinstance(loaded, dict):
            loaded = {}
        svc = {**DEFAULT_SERVICE, **loaded}
        changed = not self.service_path.exists() or not loaded.get("enroll_code")
        if not svc.get("enroll_code"):
            import secrets
            svc["enroll_code"] = secrets.token_hex(16)
        if changed:
            self.save_service(svc)
        return svc

    def save_service(self, svc: dict[str, Any] | None = None) -> None:
        self.svc = svc or self.svc
        atomic_write_json(self.service_path, self.svc)

    # ---- tenants ----
    def load_tenants_doc(self) -> dict[str, Any]:
        doc = read_json_file(self.tenants_path, {"tenants": {}})
        if not isinstance(doc, dict) or not isinstance(doc.get("tenants"), dict):
            return {"tenants": {}}
        return doc

    def load_tenants(self) -> dict[str, dict[str, Any]]:
        return self.load_tenants_doc()["tenants"]

    def save_tenants(self, tenants: dict[str, dict[str, Any]]) -> None:
        atomic_write_json(self.tenants_path, {"tenants": tenants})

    def tenant_for_token(self, auth_header: str | None) -> tuple[str | None, dict[str, Any] | None]:
        if not auth_header or not auth_header.startswith("Bearer "):
            return None, None
        token = auth_header[7:].strip()
        if not token:
            return None, None
        tenant = self.load_tenants().get(token)
        if not isinstance(tenant, dict):
            return None, None
        return token, tenant

    def enroll(self, code: str, device: str = "") -> str | None:
        expected = str(self.svc.get("enroll_code") or "")
        if not expected or not code or not hmac.compare_digest(str(code).strip(), expected):
            return None
        import secrets
        token = secrets.token_hex(24)
        tenants = self.load_tenants()
        tenants[token] = {
            "enabled": False,           # App 打开云端值守开关并 PUT config 后才置 true
            "created_at": iso_now(),
            "updated_at": iso_now(),
            "device": str(device or "")[:120],
            "settings": {
                "queryLink": "",
                "openId": "",
                "lowThreshold": 30.0,
                "lowAlertEnabled": True,
                "provider": "direct",
            },
            "meters": [],
            "bark_keys": [],
        }
        self.save_tenants(tenants)
        log.info("新租户登记 device=%s token=%s", str(device or "")[:40], mask_secret(token, 6, 4))
        return token

    def upsert_config(self, token: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        tenants = self.load_tenants()
        tenant = tenants.get(token)
        if not isinstance(tenant, dict):
            return None
        if "enabled" in payload:
            tenant["enabled"] = bool(payload["enabled"])
        if "device" in payload:
            tenant["device"] = str(payload.get("device") or "")[:120]
        tenant["updated_at"] = iso_now()

        incoming_s = payload.get("settings")
        if isinstance(incoming_s, dict):
            cur = tenant.get("settings") if isinstance(tenant.get("settings"), dict) else {}
            low = to_float(incoming_s.get("lowThreshold"), default=to_float(cur.get("lowThreshold"), 30.0))
            low = max(1.0, min(9999.0, low))
            provider = str(incoming_s.get("provider") or cur.get("provider") or "direct")
            if provider not in ("direct", "webview"):
                provider = "direct"
            # 租户级云端轮询间隔（秒）：App 用 pollIntervalSeconds 下发，兼容下划线命名；
            # 旧 App 报文不带该字段时保留已存值，再缺省 1800；统一夹到 5 分钟～24 小时。
            cur_poll = cur.get("pollIntervalSeconds", cur.get("poll_interval_seconds",
                                                              DEFAULT_TENANT_POLL_SECONDS))
            poll_raw = incoming_s.get("pollIntervalSeconds",
                                      incoming_s.get("poll_interval_seconds", cur_poll))
            try:
                poll_iv = int(float(poll_raw))
            except (TypeError, ValueError):
                poll_iv = DEFAULT_TENANT_POLL_SECONDS
            poll_iv = max(MIN_TENANT_POLL_SECONDS, min(MAX_TENANT_POLL_SECONDS, poll_iv))
            tenant["settings"] = {
                "queryLink": str(incoming_s.get("queryLink", cur.get("queryLink", "")))[:2000],
                "openId": str(incoming_s.get("openId", cur.get("openId", "")))[:200],
                "lowThreshold": low,
                "lowAlertEnabled": bool(incoming_s.get("lowAlertEnabled", cur.get("lowAlertEnabled", True))),
                "provider": provider,
                "pollIntervalSeconds": poll_iv,
            }
            # 若 App 只给了链接没解析出 openId，服务端兜底解析一次
            if not tenant["settings"]["openId"] and tenant["settings"]["queryLink"]:
                tenant["settings"]["openId"] = parse_open_id(tenant["settings"]["queryLink"])

        if isinstance(payload.get("meters"), list):
            cleaned: list[dict[str, Any]] = []
            seen: set[str] = set()
            for item in payload["meters"][:MAX_METERS_PER_TENANT]:
                if not isinstance(item, dict):
                    continue
                uid = str(item.get("uid") or "").strip()[:64]
                if not uid or uid in seen:
                    continue
                seen.add(uid)
                cleaned.append({
                    "uid": uid,
                    "room": str(item.get("room") or "").strip()[:100],
                    "pinned": bool(item.get("pinned", False)),
                })
            tenant["meters"] = cleaned

        raw_bark_keys = payload.get("barkKeys", payload.get("bark_keys"))
        if isinstance(raw_bark_keys, list):
            keys: list[str] = []
            for k in raw_bark_keys[:MAX_BARK_KEYS]:
                ks = str(k or "").strip()[:128]
                if ks and ks not in keys:
                    keys.append(ks)
            tenant["bark_keys"] = keys

        # 统一推送中心用户绑定：App 在「云端推送通道」注册拿到 userToken 后随 config 同步；
        # 仅非空覆盖，避免旧版 App 报文（不带该字段）把已有绑定清掉。
        raw_user_token = payload.get("userToken", payload.get("user_token"))
        if raw_user_token is not None and str(raw_user_token).strip():
            tenant["notify_user_token"] = str(raw_user_token).strip()[:128]

        tenants[token] = tenant
        self.save_tenants(tenants)
        return tenant

    # ---- state ----
    def load_state_doc(self) -> dict[str, Any]:
        doc = read_json_file(self.state_path, {"tenants": {}})
        if not isinstance(doc, dict) or not isinstance(doc.get("tenants"), dict):
            return {"tenants": {}}
        return doc

    def save_state_doc(self, doc: dict[str, Any]) -> None:
        atomic_write_json(self.state_path, doc)


def parse_open_id(link: str) -> str:
    """与 iOS MeterStore.parseOpenId 同口径：从 query 中取 openId。"""
    try:
        from urllib.parse import urlparse, parse_qs
        q = parse_qs(urlparse(link.strip()).query)
        return (q.get("openId", [""])[0] or "").strip()[:200]
    except Exception:
        return ""


def format_uid_room(uid: str) -> str:
    """按用户给定户号规则推导房号（仅作显示兜底，不替代 App 台账权威房号备注）。

    规则：6 位数字，前两位为座号（仅 01=1座、02=2座），后四位为楼层+房号（不再拆分）；
    电表户号不分上层/下层（同一房号上层/下层共用一块电表）。无法识别时返回空串。
    """
    u = str(uid or "").strip()
    if len(u) == 6 and u.isdigit() and u[:2] in ("01", "02"):
        return ("1座" if u[:2] == "01" else "2座") + u[2:]
    return ""


def meter_label(uid: str, room: str = "") -> str:
    """告警/汇总文案里的电表显示名：App 同步房号备注优先，缺失时按户号规则兜底，再不行用户号尾号。"""
    room = str(room or "").strip()
    if room:
        return room
    derived = format_uid_room(uid)
    if derived:
        return derived
    u = str(uid or "").strip()
    return f"电表{u[-4:]}" if len(u) > 4 else (u or "未知电表")


# ---------------------------------------------------------------------------
# 值守引擎
# ---------------------------------------------------------------------------

def _new_meter_state(room: str = "") -> dict[str, Any]:
    return {
        "room": room, "shengyu": 0.0, "leiji": 0.0, "zhuangtai": "", "shijian": "",
        "last_ok_ts": 0.0,
        "low_active": False, "low_since": 0.0, "last_low_push": 0.0,
        "off_active": False, "off_since": 0.0, "last_off_push": 0.0,
    }


def _new_tenant_state() -> dict[str, Any]:
    return {
        "last_round_at": 0.0, "last_ok_at": 0.0, "last_error": "",
        "consecutive_failures": 0, "fail_alerted": False,
        "startup_sent": False, "discovered": [], "meters": {},
    }


class Engine:
    def __init__(self, store: Store, dry_run: bool = False, pusher: BarkPusher | None = None):
        self.store = store
        self.dry_run = dry_run
        self._pusher = pusher
        self._sessions: dict[str, str] = {}   # token -> 平台 wechatId（仅内存）
        # 统一通知中心 HubRuntime：由 API 进程启动时注入；None（如纯 CLI/单测）时走旧 Bark 直推
        self.hub: Any = None

    # 可替换工厂（测试注入假平台）
    def make_client(self, svc: dict[str, Any]) -> MeterPlatformClient:
        return MeterPlatformClient(
            base=str(svc.get("platform_base") or DEFAULT_BASE),
            timeout=float(svc.get("request_timeout_seconds", 12)),
            request_interval=float(svc.get("request_interval_seconds", 1.5)),
        )

    def pusher(self, svc: dict[str, Any]) -> BarkPusher:
        if self._pusher is None:
            self._pusher = BarkPusher(str(svc.get("bark_base")), dry_run=self.dry_run)
        return self._pusher

    @staticmethod
    def tenant_keys(svc: dict[str, Any], tenant: dict[str, Any]) -> list[str]:
        keys = list(tenant.get("bark_keys") or [])
        for k in svc.get("default_bark_keys") or []:
            if k not in keys:
                keys.append(k)
        return [str(k) for k in keys if str(k).strip()]

    @staticmethod
    def tenant_poll_interval(svc: dict[str, Any], tenant: dict[str, Any]) -> int:
        """该租户云端值守轮询间隔（秒）。

        优先级：租户 App 下发的 settings.pollIntervalSeconds → 服务器全局 poll_interval_seconds
        （旧租户/旧 App 兼容）→ 内置 1800；结果统一夹到 5 分钟～24 小时。
        """
        settings = tenant.get("settings") if isinstance(tenant.get("settings"), dict) else {}
        raw = settings.get("pollIntervalSeconds", settings.get("poll_interval_seconds"))
        if raw in (None, ""):
            raw = (svc or {}).get("poll_interval_seconds") or DEFAULT_TENANT_POLL_SECONDS
        try:
            iv = int(float(raw))
        except (TypeError, ValueError):
            iv = DEFAULT_TENANT_POLL_SECONDS
        return max(MIN_TENANT_POLL_SECONDS, min(MAX_TENANT_POLL_SECONDS, iv))

    def run_all(self, startup: bool = False, only_token: str | None = None,
                only_due: bool = False) -> None:
        svc = self.store.svc
        tenants = self.store.load_tenants()
        doc = self.store.load_state_doc()
        tstates = doc["tenants"]
        try:
            for token, tenant in tenants.items():
                if only_token and token != only_token:
                    continue
                ts = tstates.setdefault(token, _new_tenant_state())
                if only_due:
                    # 定时 tick（非 App 唤醒）：按该租户自己的间隔与上轮实际执行时间判断是否到期，
                    # 多账号可各自 30/60/120 分钟而互不影响；未启用或未到期直接跳过，且不刷新 last_round_at。
                    if not tenant.get("enabled"):
                        continue
                    last_round = float(ts.get("last_round_at") or 0.0)
                    interval = self.tenant_poll_interval(svc, tenant)
                    if last_round > 0 and now_ts() - last_round < interval:
                        continue
                try:
                    self.run_tenant(token, svc, tenant, ts, startup)
                except Exception as e:  # 单租户兜底，不影响其他租户与常驻进程
                    log.exception("租户值守异常 token=%s: %s", mask_secret(token, 6, 4), e)
                    ts["last_error"] = f"internal: {e}"[:300]
                finally:
                    ts["last_round_at"] = now_ts()
                    self.store.save_state_doc(doc)
        finally:
            self.store.save_state_doc(doc)

    # ---- 单租户 ----
    def run_tenant(self, token: str, svc: dict[str, Any], tenant: dict[str, Any],
                  ts: dict[str, Any], startup: bool) -> None:
        if not tenant.get("enabled"):
            log.info("租户未开启云端值守，跳过 token=%s", mask_secret(token, 6, 4))
            return
        settings = tenant.get("settings") if isinstance(tenant.get("settings"), dict) else {}
        open_id = str(settings.get("openId") or "").strip()
        if not open_id and settings.get("queryLink"):
            open_id = parse_open_id(str(settings["queryLink"]))
        if not open_id:
            ts["last_error"] = "missing_open_id"
            log.warning("租户已启用但缺少 openId（等 App 同步查询链接）token=%s", mask_secret(token, 6, 4))
            return

        threshold = to_float(settings.get("lowThreshold"), 30.0)
        threshold = max(1.0, threshold)
        client = self.make_client(svc)
        room_map = {str(m.get("uid")): str(m.get("room") or "")
                    for m in tenant.get("meters") or [] if isinstance(m, dict) and m.get("uid")}
        configured = [str(m.get("uid")).strip() for m in tenant.get("meters") or []
                      if isinstance(m, dict) and str(m.get("uid") or "").strip()]

        try:
            wechat_id = self._ensure_wechat(client, token, open_id)
            if configured:
                targets = configured
            else:
                # App 清单为空（例如首期服务器直接配置）：自动发现该微信绑定户号并缓存到 state
                discovered = client.fetch_bindings(wechat_id)
                ts["discovered"] = discovered
                targets = discovered
            if not targets:
                ts["last_error"] = "no_meters"
                log.info("租户暂无电表户号 token=%s", mask_secret(token, 6, 4))
                return

            mstates: dict[str, Any] = ts.setdefault("meters", {})
            ok_count = 0
            for idx, uid in enumerate(targets):
                m = mstates.setdefault(uid, _new_meter_state(room_map.get(uid, "")))
                if uid in room_map:
                    m["room"] = room_map[uid]
                try:
                    data = self._query_one(client, token, open_id, uid)
                except PlatformError as e:
                    log.warning("户号查询失败 %s：%s", uid, e)
                    if idx < len(targets) - 1:
                        time.sleep(float(svc.get("request_interval_seconds", 1.5)))
                    continue
                m["shengyu"] = to_float(data.get("shengyu"), m["shengyu"])
                m["leiji"] = to_float(data.get("leiji"), m["leiji"])
                m["zhuangtai"] = str(data.get("zhuangtai") or m["zhuangtai"] or "")
                m["shijian"] = str(data.get("shijian") or m["shijian"] or "")
                m["last_ok_ts"] = now_ts()
                ok_count += 1
                self.evaluate_meter(svc, tenant, uid, m, threshold, now_ts())
                if idx < len(targets) - 1:
                    time.sleep(float(svc.get("request_interval_seconds", 1.5)))

            if ok_count > 0:
                was_failing = bool(ts.get("fail_alerted")) or int(ts.get("consecutive_failures", 0)) > 0
                ts["consecutive_failures"] = 0
                ts["fail_alerted"] = False
                ts["last_error"] = ""
                ts["last_ok_at"] = now_ts()
                if was_failing:
                    self._push_tenant(svc, tenant, "【电表监控恢复】", "电表查询已恢复正常。")
                if startup and svc.get("startup_summary", True) and not ts.get("startup_sent"):
                    self._startup_summary(svc, tenant, ts, threshold)
                    ts["startup_sent"] = True
            else:
                self._register_failure(svc, tenant, ts, "本轮所有户号查询失败")
        except PlatformError as e:
            self._register_failure(svc, tenant, ts, str(e)[:300])

    def _ensure_wechat(self, client: MeterPlatformClient, token: str, open_id: str) -> str:
        wid = self._sessions.get(token)
        if wid:
            return wid
        wid = client.index_open_id(open_id)
        self._sessions[token] = wid
        return wid

    def _query_one(self, client: MeterPlatformClient, token: str, open_id: str, uid: str) -> dict[str, Any]:
        try:
            wid = self._ensure_wechat(client, token, open_id)
            return client.query_with_retry(wid, uid)
        except PlatformMeterError:
            # 该表自身查询失败（离线/弱信号），重建微信会话无意义；重试已在 query_with_retry 内做过
            raise
        except PlatformError:
            # 其余多为会话过期/网络抖动：清缓存重建一次再试（仅一次，避免死循环）
            self._sessions.pop(token, None)
            wid = self._ensure_wechat(client, token, open_id)
            return client.query_with_retry(wid, uid)

    def _register_failure(self, svc: dict[str, Any], tenant: dict[str, Any],
                          ts: dict[str, Any], error: str) -> None:
        ts["consecutive_failures"] = int(ts.get("consecutive_failures", 0)) + 1
        ts["last_error"] = error
        rounds = int(svc.get("failure_alert_rounds", 3))
        log.error("租户连续失败 %d 轮：%s", ts["consecutive_failures"], error)
        if ts["consecutive_failures"] >= rounds and not ts.get("fail_alerted"):
            ts["fail_alerted"] = True
            self._push_tenant(
                svc, tenant, "【电表监控异常】",
                f"云端值守已连续 {ts['consecutive_failures']} 轮无法查询电表平台，"
                "请检查服务器网络或在 App 重新粘贴微信查询链接。",
            )

    # ---- 判定与推送（纯状态迁移，便于单测直接调用）----
    def evaluate_meter(self, svc: dict[str, Any], tenant: dict[str, Any],
                       uid: str, m: dict[str, Any], threshold: float, now: float) -> list[str]:
        sent_titles: list[str] = []
        keys = self.tenant_keys(svc, tenant)
        label = meter_label(uid, m.get("room") or "")
        shengyu = float(m.get("shengyu") or 0.0)
        is_off = str(m.get("zhuangtai") or "") == "拉闸"
        # 保护：合闸状态下平台给 0 度常是通信异常/空值，不据此误报低电量
        is_low = (not is_off) and shengyu > 0 and shengyu < threshold

        # 1) 拉闸：边沿立即推 + 持续复提醒 + 合闸恢复
        if is_off:
            if not m.get("off_active"):
                m["off_active"] = True
                m["off_since"] = now
                title, body = "【电表拉闸】", f"{label} 电表已拉闸，请及时处理。"
                if self._push_tenant(svc, tenant, title, body, keys=keys) > 0:
                    m["last_off_push"] = now
                    sent_titles.append(title)
            elif now - float(m.get("last_off_push") or 0) >= float(svc.get("off_remind_hours", 24)) * 3600:
                title, body = "【电表拉闸提醒】", f"{label} 仍处于拉闸状态，请尽快处理。"
                if self._push_tenant(svc, tenant, title, body, keys=keys) > 0:
                    m["last_off_push"] = now
                    sent_titles.append(title)
            # 拉闸期间挂起低电量状态，避免重复噪音
            m["low_active"] = False
        elif m.get("off_active"):
            m["off_active"] = False
            if svc.get("notify_recovery", True):
                title, body = "【电表恢复】", f"{label} 已恢复合闸供电。"
                if self._push_tenant(svc, tenant, title, body, keys=keys) > 0:
                    sent_titles.append(title)

        # 2) 低电量：边沿立即推 + 持续复提醒 + 回升恢复
        if is_low:
            if not m.get("low_active"):
                m["low_active"] = True
                m["low_since"] = now
                title = "【电表低电量】"
                body = f"{label} 剩余 {shengyu:g} 度（阈值 {threshold:g} 度），请及时充值。"
                if self._push_tenant(svc, tenant, title, body, keys=keys) > 0:
                    m["last_low_push"] = now
                    sent_titles.append(title)
            elif now - float(m.get("last_low_push") or 0) >= float(svc.get("low_remind_hours", 24)) * 3600:
                title = "【电表低电量提醒】"
                body = f"{label} 仍剩 {shengyu:g} 度（阈值 {threshold:g} 度），请尽快充值。"
                if self._push_tenant(svc, tenant, title, body, keys=keys) > 0:
                    m["last_low_push"] = now
                    sent_titles.append(title)
        elif m.get("low_active") and not is_off:
            m["low_active"] = False
            if svc.get("notify_recovery", True) and shengyu > 0 and shengyu >= threshold:
                title = "【电量恢复】"
                body = f"{label} 剩余 {shengyu:g} 度，已高于阈值 {threshold:g} 度。"
                if self._push_tenant(svc, tenant, title, body, keys=keys) > 0:
                    sent_titles.append(title)
        return sent_titles

    def _push_tenant(self, svc: dict[str, Any], tenant: dict[str, Any],
                     title: str, body: str, keys: list[str] | None = None,
                     event_type: str = "alert", data: dict[str, Any] | None = None) -> int:
        # 优先走统一通知中心：按租户绑定的用户投到该用户自己的 Bark 设备，实现多用户隔离
        user_token = str(tenant.get("notify_user_token") or "")
        if user_token and self.hub is not None:
            try:
                res = self.hub.dispatch(user_token, "meter", event_type, title, body, data=data or {})
                total = int(res.get("total") or 0)
                if total > 0:
                    # 已找到用户设备并完成投递尝试（含全部失败 sent=0），不再降级重复推
                    return int(res.get("sent") or 0)
                reason = str(res.get("reason") or "")
                if reason in ("user_disabled", "module_disabled"):
                    log.info("用户在推送中心关闭该类通知（%s），不降级直推：%s", reason, title)
                    return 0
                # unknown_user / no_device：测试期平滑落到旧直推（租户自带 key + 全局兜底）
                log.info("通知中心暂无可投设备（%s），降级租户直推：%s", reason or "empty", title)
            except Exception:
                log.exception("通知中心投递异常，降级 Bark 直推：%s", title)

        keys = keys if keys is not None else self.tenant_keys(svc, tenant)
        if not keys:
            log.info("（未配置 Bark 接收设备，仅记录告警）%s %s", title, body)
            return 0
        ok, _ = self.pusher(svc).push_many(keys, title, body)
        return ok

    def _startup_summary(self, svc: dict[str, Any], tenant: dict[str, Any],
                        ts: dict[str, Any], threshold: float) -> None:
        mstates = ts.get("meters") or {}
        rows = [(float(m.get("shengyu") or 0), meter_label(uid, m.get("room") or ""),
                 str(m.get("zhuangtai") or ""))
                for uid, m in mstates.items() if float(m.get("last_ok_ts") or 0) > 0]
        rows.sort(key=lambda x: x[0])
        head = "，".join(f"{room} {s:g}度({st or '未知'})" for s, room, st in rows[:3]) or "暂无读数"
        total = len(rows)
        off_n = sum(1 for _, _, st in rows if st == "拉闸")
        body = f"云端值守已启动：共 {total} 块表，最低 {head}；拉闸 {off_n} 户。阈值 {threshold:g} 度，每 30 分钟轮询。"
        self._push_tenant(svc, tenant, "公寓管家电表值守", body)

    # ---- CLI 辅助 ----
    def cli_bindings(self) -> int:
        svc = self.store.svc
        for token, tenant in self.store.load_tenants().items():
            if not tenant.get("enabled"):
                continue
            s = tenant.get("settings") or {}
            open_id = str(s.get("openId") or parse_open_id(str(s.get("queryLink") or "")))
            if not open_id:
                continue
            client = self.make_client(svc)
            wid = client.index_open_id(open_id)
            uids = client.fetch_bindings(wid)
            print(f"tenant={mask_secret(token, 6, 4)} 绑定 {len(uids)} 户：")
            for u in uids:
                print(" ", u)
            return 0
        print("没有已启用且含 openId 的租户；请先由 App 同步或手工填写 tenants.json")
        return 1

    def cli_demo(self) -> int:
        svc = self.store.svc
        keys = list(svc.get("default_bark_keys") or [])
        if not keys:
            for t in self.store.load_tenants().values():
                keys = self.tenant_keys(svc, t)
                if keys:
                    break
        if not keys:
            print("未找到任何 Bark key：请先在 service.json 的 default_bark_keys 或租户 bark_keys 配置")
            return 2
        ok, total = self.pusher(svc).push_many(
            keys, "公寓管家电表值守演示",
            "云端值守服务与自建 Bark 链路正常；正式运行时低电量/拉闸会推送到这里。",
        )
        print(f"演示推送 {ok}/{total} 成功（dry_run={self.dry_run}）")
        return 0 if ok > 0 else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="公寓管家电表云端值守 meter-watch")
    default_home = os.environ.get("METER_WATCH_HOME", str(Path(__file__).resolve().parent))
    p.add_argument("--config-dir", default=default_home, help="service/tenants/state.json 所在目录")
    p.add_argument("--once", action="store_true", help="所有启用租户跑一轮后退出")
    p.add_argument("--bindings", action="store_true", help="拉取首个启用租户的平台绑定户号")
    p.add_argument("--demo", action="store_true", help="向 Bark 设备发一条链路演示")
    p.add_argument("--validate", action="store_true", help="校验配置并打印摘要，不联网")
    p.add_argument("--dry-run", action="store_true", help="Bark 只记录不实际发送")
    args = p.parse_args(argv)

    store = Store(args.config_dir)
    engine = Engine(store, dry_run=args.dry_run)

    if args.validate:
        tenants = store.load_tenants()
        enabled = sum(1 for t in tenants.values() if t.get("enabled"))
        key_n = len(store.svc.get("default_bark_keys") or [])
        print("meter-watch 配置校验通过")
        print(f"  home={store.home}")
        print(f"  listen={store.svc['listen_host']}:{store.svc['listen_port']}")
        print(f"  poll={store.svc['poll_interval_seconds']}s bark={store.svc['bark_base']}")
        print(f"  tenants={len(tenants)} enabled={enabled} default_bark_keys={key_n}")
        print(f"  enroll_code={mask_secret(str(store.svc.get('enroll_code') or ''), 4, 4)}")
        for tok, t in tenants.items():
            s = t.get("settings") or {}
            print(f"    - {mask_secret(tok, 6, 4)} enabled={t.get('enabled')} "
                  f"meters={len(t.get('meters') or [])} threshold={s.get('lowThreshold')} "
                  f"openId={mask_secret(str(s.get('openId') or ''), 4, 4)}")
        return 0

    if args.bindings:
        return engine.cli_bindings()
    if args.demo:
        return engine.cli_demo()
    if args.once:
        engine.run_all(startup=False)
        return 0

    # 默认：启动 HTTP 同步 API + 常驻值守线程（实现在 meter_api.py，同目录部署）
    try:
        from meter_api import serve  # 延迟导入，保证 --once/测试不依赖 HTTP 层
    except ImportError as e:
        log.error("缺少 meter_api.py（与 meter_watch.py 同目录）：%s", e)
        return 2
    return serve(store, engine)


if __name__ == "__main__":
    raise SystemExit(main())
