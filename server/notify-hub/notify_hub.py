#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 统一推送中心（notify-hub）
=====================================
整体思路（用户 2026-11-24 拍板）：

* **通道后（本模块）**：以「用户」为单位，每个用户绑定自己手机的 Bark 设备 key
  （一人可绑多台），通知事件只投递给归属用户的设备，用户之间天然隔离，不会串推。
* **通道前（业务模块）**：电表值守是第一个 producer，只负责把“某用户的低电量/拉闸/
  测试”事件交给 `HubRuntime.dispatch(...)`；以后到期提醒、收租提醒等按同一接口接入，
  不再各写一套 Bark 投递与设备名单。

部署形态（测试期最稳方案）：作为纯标准库模块被同机 `meter_api.py` import，挂载在
**已公网放行的 8082** 端口 `/api/notify/*`，不新开端口、不改云安全组；数据落在
`notify.json`（600）。模块本身不依赖 meter_watch，未来规模变大可原样拆成独立进程/服务。

HTTP 路由由 `route_request(handler, method, path, hub)` 以鸭子类型方式挂到现有
BaseHTTPRequestHandler（复用其 `_send/_read_json`），单测可用 FakeHandler 直接驱动。

注意：Bark 设备 key 属于敏感凭据，只存服务器 600 文件，不写 git、不进日志明文
（日志与 API 出参一律 `mask_key` 脱敏）。
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

log = logging.getLogger("notify-hub")

MAX_DEVICES_PER_USER = 10
MAX_EVENTS_PER_USER = 50       # 磁盘每用户最多保留事件
EVENTS_RETURN = 20             # API 最近事件返回条数
MAX_REMINDERS_PER_SOURCE = 100 # 每台设备最多上报的未来待办提醒
REMINDER_EXPIRE_SEC = 6 * 3600 # 到点超过 6 小时未投递则视为过期，避免离线补推轰炸
REMINDER_INFLIGHT_SEC = 180    # 投递中的租约，进程异常后 3 分钟可重试
REMINDER_MAX_ATTEMPTS = 5      # 单条提醒最多尝试 5 轮，避免 Bark 故障时无限重试
DEDUP_WINDOW_SEC = 300         # 同用户同文案 5 分钟内指纹去重（防重启/多出口重复推）
DEDUP_LOOKBACK = 10
ENROLL_WINDOW_SEC = 600
ENROLL_MAX_FAILS = 10
HTTP_TIMEOUT = 8.0

PREFIX = "/api/notify"

_KEY_RE = re.compile(r"^[A-Za-z0-9._-]{8,128}$")
_BARK_RESERVED = {"push", "info", "ping", "devices", "register", "health", "api", "notify"}
_UNSET = object()

# 通知文案模板：用户可在 App 内自定义主标题/副标题/正文/是否显示时间；未自定义时用下列默认值。
# 正文支持占位符：{label} 房号、{remain} 剩余电量、{threshold} 阈值、{uid} 户号、{time} 时间。
_PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z_]+)\}")

DEFAULT_TEMPLATES: dict[str, dict[str, dict[str, Any]]] = {
    "meter": {
        "low": {
            "title": "【电表低电量】",
            "subtitle": "",
            "body": "{label} 剩余 {remain} 度（阈值 {threshold} 度），请及时充值。{time}",
            "showTime": True,
        },
        "off": {
            "title": "【电表拉闸】",
            "subtitle": "",
            "body": "{label} 电表已拉闸，请及时处理。{time}",
            "showTime": True,
        },
    }
}


def normalize_template(raw: Any, default: dict[str, Any]) -> dict[str, Any]:
    raw = raw if isinstance(raw, dict) else {}
    return {
        "title": str(raw.get("title") or default["title"]).strip()[:120],
        "subtitle": str(raw.get("subtitle") or "").strip()[:120],
        "body": str(raw.get("body") or default["body"]).strip()[:1000],
        "showTime": bool(raw.get("showTime", default.get("showTime", True))),
    }


def render_text(text: str, variables: dict[str, Any]) -> str:
    """占位符替换 + 清理时间隐藏后遗留的空格/空括号/悬空标点。

    保留用户在正文里打的换行（\\n）：只对单行内部折叠多余空白、清理悬空标点，
    不再把跨行的换行压成空格；占位符被清空后变空的整行直接剔除。
    """
    def _repl(m: re.Match) -> str:
        return str(variables.get(m.group(1), ""))
    s = _PLACEHOLDER_RE.sub(_repl, str(text or ""))
    lines: list[str] = []
    for ln in s.split("\n"):
        ln = re.sub(r"[ \t]+", " ", ln)
        ln = ln.replace("（ ）", "").replace("( )", "")
        ln = re.sub(r"\s+([，。；：、）])", r"\1", ln)
        ln = re.sub(r"（\s*）|\(\s*\)", "", ln)
        ln = ln.rstrip()
        if ln.strip():
            lines.append(ln)
    return "\n".join(lines).strip()


def time_string(ts: float | None = None) -> str:
    return time.strftime("%m-%d %H:%M", time.localtime(ts if ts is not None else time.time()))


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

def now_ts() -> float:
    return time.time()


def iso_now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


def mask_key(k: Any) -> str:
    s = str(k or "")
    if not s:
        return ""
    if len(s) <= 10:
        return "****"
    return f"{s[:4]}…{s[-4:]}"


def parse_bark_key(raw: Any) -> str:
    """宽容解析用户粘贴的 Bark 内容：纯 key、完整推送 URL、文本中夹带 URL、无 scheme 的 host/key 均可。"""
    s = str(raw or "").strip().strip('"').strip()
    if not s:
        return ""
    # 1) 文本任意位置出现 http(s) 链接：直接取域名后第一段合法 key
    m = re.search(r"https?://[^\s\"'<>]+?/([A-Za-z0-9._-]{8,128})(?:/|\b|$)", s, re.IGNORECASE)
    if m and m.group(1).lower() not in _BARK_RESERVED:
        return m.group(1)
    # 2) 无 scheme 的 host/key/标题，或本身就是 key/URL
    candidate = s
    if "://" in candidate:
        # 仅当字符串以 scheme 开头时用 urlparse 路径首段，避免“中文前缀 + URL”被误切
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", candidate):
            try:
                seg = (urllib.parse.urlparse(candidate).path or "").strip("/").split("/")[0]
            except Exception:
                seg = ""
            if seg:
                candidate = seg
    elif "/" in candidate:
        head, rest = candidate.split("/", 1)
        # 第一段像域名/host 时取后面的 key 段；否则视为 “key/标题/正文”
        if ("." in head or ":" in head) and rest:
            candidate = rest.strip("/").split("/")[0]
        else:
            candidate = head
    candidate = candidate.strip().strip("/")
    if candidate.lower() in _BARK_RESERVED:
        return ""
    if _KEY_RE.match(candidate):
        return candidate
    m = re.search(r"[A-Za-z0-9]{16,32}", candidate)
    return m.group(0) if m else ""


def _atomic_write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _read_json_file(path: Path, default: Any) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except Exception:
        log.warning("notify.json 读取失败，按空库处理：%s", path, exc_info=True)
        return default


def default_bark_sender(base: str, device_key: str, payload: dict[str, Any],
                        timeout: float = HTTP_TIMEOUT) -> tuple[bool, int, dict[str, Any]]:
    """真实 Bark /push 投递器；返回 (是否成功, HTTP状态码, 响应字典)。不抛异常。"""
    try:
        req = urllib.request.Request(
            f"{base.rstrip('/')}/push",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310（自建 Bark，地址来自服务器 600 配置）
            status = int(getattr(resp, "status", 200) or 200)
            obj = json.loads(resp.read().decode("utf-8", "replace"))
        return (obj.get("code") == 200), status, obj if isinstance(obj, dict) else {}
    except Exception as e:  # 投递失败不能打断业务轮询
        log.warning("Bark 投递异常 key=%s err=%s", mask_key(device_key), e)
        return False, 0, {"error": str(e)[:200]}


# ---------------------------------------------------------------------------
# 存储：notify.json（600）。结构 {"version":1,"users":{token:user},"username_index":{lower:token}}
# ---------------------------------------------------------------------------

class HubStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.lock = threading.RLock()

    def doc(self) -> dict[str, Any]:
        d = _read_json_file(self.path, None)
        if not isinstance(d, dict) or not isinstance(d.get("users"), dict):
            d = {"version": 1, "users": {}, "username_index": {}}
        if not isinstance(d.get("username_index"), dict):
            d["username_index"] = {}
        return d

    def save(self, d: dict[str, Any]) -> None:
        _atomic_write_json(self.path, d)

    def get_user(self, token: str) -> dict[str, Any] | None:
        if not token:
            return None
        with self.lock:
            u = self.doc()["users"].get(token)
            return u if isinstance(u, dict) else None

    def counts(self) -> tuple[int, int]:
        with self.lock:
            d = self.doc()
            users = d["users"]
            devices = sum(len(u.get("devices") or []) for u in users.values() if isinstance(u, dict))
            return len(users), devices


# ---------------------------------------------------------------------------
# 运行时：注册 / 档案 / 偏好 / 设备 / 事件投递
# ---------------------------------------------------------------------------

class HubRuntime:
    def __init__(self, data_path: str | Path, config: dict[str, Any] | None = None,
                 sender: Callable[..., tuple[bool, int, dict[str, Any]]] | None = None):
        self.store = HubStore(data_path)
        # 直接持有 meter Store.svc dict 引用：服务器配置变更 restart 后生效；测试可传普通 dict
        self.config = config if isinstance(config, dict) else {}
        self._sender = sender or default_bark_sender
        # 业务板块准入校验：由服务启动时注入（如房源板块 house_access=False 时禁止 house 通知）。
        # 签名 (notify_user_token, module) -> allowed；未注入时一律放行（兼容旧部署）。
        self.access_checker: Callable[[str, str], bool] | None = None

    # ---- 配置（复用 meter service.json 的 enroll_code / bark_base，也支持 notify_ 前缀覆盖）----

    def _cfg(self, key: str, default: Any = None) -> Any:
        v = self.config.get(key)
        return v if v not in (None, "") else default

    def code_ok(self, code: str) -> bool:
        expected = str(self._cfg("notify_enroll_code") or self._cfg("enroll_code") or "")
        if not expected:
            return False
        return hmac.compare_digest(str(code or "").strip(), expected)

    def bark_base(self) -> str:
        return str(self._cfg("notify_bark_base") or self._cfg("bark_base")
                   or "http://127.0.0.1:8081").rstrip("/")

    # ---- 档案视图（出参脱敏，绝不含完整 bark_key）----

    def public_view(self, user: dict[str, Any], include_events: bool = True) -> dict[str, Any]:
        devices = [{
            "deviceId": d.get("device_id", ""),
            "name": d.get("name", ""),
            "platform": d.get("platform", ""),
            "serverBase": d.get("server_base", ""),
            "enabled": d.get("enabled", True) is not False,
            "modules": d.get("modules", {}) if isinstance(d.get("modules"), dict) else {},
            "keyMasked": mask_key(d.get("bark_key")),
            "addedAt": d.get("added_at", ""),
            "lastOkAt": d.get("last_ok_at", 0),
            "lastError": d.get("last_error", ""),
        } for d in user.get("devices", []) if isinstance(d, dict)]
        view: dict[str, Any] = {
            "ok": True,
            "token": user.get("token", ""),
            "username": user.get("username", ""),
            "createdAt": user.get("created_at", ""),
            "updatedAt": user.get("updated_at", ""),
            "prefs": user.get("prefs", {}) if isinstance(user.get("prefs"), dict) else {},
            "devices": devices,
            "devicesCount": len(devices),
        }
        if include_events:
            events = list(user.get("events", []) or [])[-EVENTS_RETURN:][::-1]
            view["events"] = events
        return view

    # ---- 注册 / 更新 ----

    @staticmethod
    def _upsert_device(user: dict[str, Any], key: str, name: str,
                       platform: str, server_base: str) -> str | None:
        for d in user.setdefault("devices", []):
            if isinstance(d, dict) and d.get("bark_key") == key:
                if name:
                    d["name"] = name
                if platform:
                    d["platform"] = platform
                if server_base:
                    d["server_base"] = server_base
                return None
        if len(user["devices"]) >= MAX_DEVICES_PER_USER:
            return "device_limit"
        user["devices"].append({
            "device_id": "dv_" + secrets.token_hex(6),
            "bark_key": key,
            "name": name or "我的 iPhone",
            "platform": platform or "ios",
            "server_base": server_base or "",
            "enabled": True,
            "modules": {},
            "added_at": iso_now(),
            "last_ok_at": 0,
            "last_error": "",
        })
        return None

    def _rename_locked(self, doc: dict[str, Any], user: dict[str, Any], new_name: str) -> str | None:
        new_name = str(new_name or "").strip()[:40]
        if not new_name or new_name == user.get("username"):
            return None
        idx = doc["username_index"]
        low = new_name.lower()
        other = idx.get(low)
        if other and other != user.get("token") and other in doc["users"]:
            return "username_exists"
        old_low = str(user.get("username") or "").lower()
        if old_low and idx.get(old_low) == user.get("token"):
            idx.pop(old_low, None)
        user["username"] = new_name
        idx[low] = user["token"]
        return None

    def register(self, code: str = "", token: str = "", username: str = "",
                 bark_key: str = "", device_name: str = "", platform: str = "",
                 server_base: str = "") -> tuple[dict[str, Any] | None, str | None]:
        """返回 (脱敏用户档案, 错误码)。token 有效=已登录更新（加/换设备、改名）；否则凭接入码新建。"""
        username = str(username or "").strip()[:40]
        key = parse_bark_key(bark_key)
        dname = str(device_name or "").strip()[:60] or "我的 iPhone"
        plat = str(platform or "").strip()[:20] or "ios"
        sbase = str(server_base or "").strip()[:200]

        with self.store.lock:
            doc = self.store.doc()
            users, idx = doc["users"], doc["username_index"]
            existing = users.get(token) if token else None

            if isinstance(existing, dict):
                err = self._rename_locked(doc, existing, username)
                if err:
                    return None, err
                if bark_key and not key:
                    return None, "invalid_bark_key"
                if key:
                    err = self._upsert_device(existing, key, dname, plat, sbase)
                    if err:
                        return None, err
                existing["updated_at"] = iso_now()
                users[token] = existing
                self.store.save(doc)
                log.info("用户档案更新 token=%s devices=%d", mask_key(token), len(existing.get("devices", [])))
                return self.public_view(existing), None

            # 新用户注册必须接入码正确 + 本机 Bark key 可识别
            if not self.code_ok(code):
                return None, "invalid_code"
            if not key:
                return None, "invalid_bark_key"
            if not username:
                username = "用户" + secrets.token_hex(2)
            if idx.get(username.lower()) in users:
                return None, "username_exists"

            nt = "nt_" + secrets.token_hex(20)
            now = iso_now()
            user = {
                "token": nt,
                "username": username,
                "created_at": now,
                "updated_at": now,
                "devices": [],
                "prefs": {"enabled": True, "modules": {"meter": True, "house": True, "todo": True}},
                "events": [],
            }
            self._upsert_device(user, key, dname, plat, sbase)
            users[nt] = user
            idx[username.lower()] = nt
            self.store.save(doc)
            log.info("新推送用户登记 username=%s token=%s devices=%d",
                     username[:20], mask_key(nt), len(user["devices"]))
            return self.public_view(user), None

    def set_prefs(self, token: str, enabled: Any = _UNSET, modules: dict | None = None,
                  username: str = _UNSET) -> tuple[dict[str, Any] | None, str | None]:  # type: ignore[assignment]
        with self.store.lock:
            doc = self.store.doc()
            user = doc["users"].get(token)
            if not isinstance(user, dict):
                return None, "unauthorized"
            if username is not _UNSET:
                err = self._rename_locked(doc, user, str(username or ""))
                if err:
                    return None, err
            prefs = user.setdefault("prefs", {"enabled": True, "modules": {}})
            if enabled is not _UNSET:
                prefs["enabled"] = bool(enabled)
            if isinstance(modules, dict):
                cur = prefs.get("modules") if isinstance(prefs.get("modules"), dict) else {}
                for k, v in list(modules.items())[:32]:
                    kk = str(k)[:32]
                    if isinstance(v, bool):
                        cur[kk] = v
                prefs["modules"] = cur
            user["updated_at"] = iso_now()
            doc["users"][token] = user
            self.store.save(doc)
            return self.public_view(user), None

    # ---- 待办提醒：App 上报未来到点的提醒，服务端到点经 Bark 投递 ----
    def replace_reminders(self, token: str, source: str, raw: Any) -> tuple[dict[str, Any] | None, str | None]:
        """按设备来源替换提醒清单；同一账号多台手机互不覆盖各自待办。"""
        if not isinstance(raw, list):
            return None, "bad_reminders"
        src = str(source or "").strip()[:64] or "default"
        now = now_ts()
        clean: list[dict[str, Any]] = []
        with self.store.lock:
            doc = self.store.doc()
            user = doc["users"].get(token)
            if not isinstance(user, dict):
                return None, "unauthorized"
            all_rem = user.get("reminders")
            if not isinstance(all_rem, dict):
                all_rem = {}
            existing = {
                str(r.get("id")): r for r in (all_rem.get(src) or [])
                if isinstance(r, dict) and r.get("id")
            }
            for item in raw[:MAX_REMINDERS_PER_SOURCE]:
                if not isinstance(item, dict):
                    continue
                rid = str(item.get("id") or "").strip()[:80]
                if not rid:
                    continue
                try:
                    due = float(item.get("dueAt") or item.get("due_at") or 0)
                except (TypeError, ValueError):
                    continue
                if due <= 0:
                    continue
                # 已经过去太久的提醒不再补推，避免用户离线几天后一次收到一堆旧待办
                if due < now - REMINDER_EXPIRE_SEC:
                    continue
                body = str(item.get("body") or "").strip()[:1000]
                if not body:
                    continue
                title = str(item.get("title") or "待办提醒").strip()[:120] or "待办提醒"
                old = existing.get(rid)
                sent_at = None
                if old and abs(float(old.get("due_at") or 0) - due) <= 1:
                    sent_at = old.get("sent_at")
                clean.append({"id": rid, "due_at": due, "title": title, "body": body,
                              "sent_at": sent_at, "updated_at": now})
            all_rem[src] = clean
            user["reminders"] = all_rem
            user["updated_at"] = iso_now()
            doc["users"][token] = user
            self.store.save(doc)
        return {"ok": True, "count": len(clean), "source": src}, None

    def run_due_reminders(self, now: float | None = None, limit: int = 50) -> int:
        """到点扫描待办提醒并投递；由 meter-watch 常驻 worker 每 tick 调用。"""
        now = float(now if now is not None else time.time())
        claimed: list[tuple[str, str, str, str]] = []
        with self.store.lock:
            doc = self.store.doc()
            changed = False
            for token, user in doc["users"].items():
                if not isinstance(user, dict):
                    continue
                prefs = user.get("prefs") if isinstance(user.get("prefs"), dict) else {}
                if prefs.get("enabled") is False:
                    continue
                modules = prefs.get("modules") if isinstance(prefs.get("modules"), dict) else {}
                if modules.get("todo", True) is False:
                    continue
                all_rem = user.get("reminders")
                if not isinstance(all_rem, dict):
                    continue
                for src, items in all_rem.items():
                    if not isinstance(items, list):
                        continue
                    for r in items:
                        if not isinstance(r, dict) or r.get("sent_at"):
                            continue
                        try:
                            due = float(r.get("due_at") or 0)
                        except (TypeError, ValueError):
                            due = 0
                        if due <= 0 or due > now:
                            continue
                        if now - due > REMINDER_EXPIRE_SEC:
                            r["sent_at"] = now
                            r["status"] = "expired"
                            changed = True
                            continue
                        inflight = float(r.get("in_flight_at") or 0)
                        if inflight and now - inflight < REMINDER_INFLIGHT_SEC:
                            continue
                        attempts = int(r.get("attempts") or 0) + 1
                        if attempts > REMINDER_MAX_ATTEMPTS:
                            r["sent_at"] = now
                            r["status"] = "failed_too_many_attempts"
                            changed = True
                            continue
                        r["in_flight_at"] = now
                        r["attempts"] = attempts
                        r["status"] = "sending"
                        changed = True
                        claimed.append((token, str(r.get("id") or ""),
                                        str(r.get("title") or "待办提醒"),
                                        str(r.get("body") or "")))
                        break  # 每 tick 每个来源只取一条，避免一次 tick 长时间阻塞
                    if len(claimed) >= limit:
                        break
                if len(claimed) >= limit:
                    break
            if changed:
                self.store.save(doc)

        sent = 0
        for token, rid, title, body in claimed:
            try:
                # event_type 带上提醒 ID，避免两条同文案待办被 5 分钟指纹去重
                res = self.dispatch(token, "todo", "todo_" + rid[:20], title, body,
                                    data={"reminderId": rid})
            except Exception:
                log.exception("待办提醒投递异常 user=%s id=%s", mask_key(token), rid)
                res = {"ok": False, "reason": "exception"}
            ok = bool(res.get("ok"))
            if ok:
                sent += 1
            with self.store.lock:
                doc = self.store.doc()
                user = doc["users"].get(token)
                if isinstance(user, dict):
                    all_rem = user.get("reminders")
                    if isinstance(all_rem, dict):
                        for items in all_rem.values():
                            if not isinstance(items, list):
                                continue
                            for r in items:
                                if not isinstance(r, dict) or str(r.get("id") or "") != rid:
                                    continue
                                r.pop("in_flight_at", None)
                                if ok:
                                    r["sent_at"] = now
                                    r["status"] = "sent"
                                elif res.get("reason") in ("unknown_user", "no_device", "user_disabled",
                                                            "module_disabled", "module_access_denied"):
                                    r["sent_at"] = now
                                    r["status"] = "suppressed:" + str(res.get("reason"))
                                else:
                                    r["status"] = "retry"
                                break
                        self.store.save(doc)
        if claimed:
            log.info("待办提醒本轮处理 %d 条，成功 %d 条", len(claimed), sent)
        return sent

    def remove_device(self, token: str, device_id: str = "", bark_key: str = "") -> dict[str, Any] | None:
        key = parse_bark_key(bark_key) if bark_key else ""
        with self.store.lock:
            doc = self.store.doc()
            user = doc["users"].get(token)
            if not isinstance(user, dict):
                return None
            before = len(user.get("devices", []))
            kept = []
            for d in user.get("devices", []):
                if not isinstance(d, dict):
                    continue
                if device_id and d.get("device_id") == device_id:
                    continue
                if key and d.get("bark_key") == key:
                    continue
                kept.append(d)
            if len(kept) != before:
                user["devices"] = kept
                user["updated_at"] = iso_now()
                self.store.save(doc)
            return self.public_view(user)

    # ---- 设备级模块开关 / 板块准入 ----

    @staticmethod
    def device_allows(device: dict[str, Any], module: str) -> bool:
        """单台设备是否接收某板块：设备总开关 + 设备自己的模块开关（缺省=允许）。"""
        if not isinstance(device, dict) or not device.get("bark_key"):
            return False
        if device.get("enabled") is False:
            return False
        modules = device.get("modules") if isinstance(device.get("modules"), dict) else {}
        return modules.get(str(module), True) is not False

    def set_device_prefs(self, token: str, device_id: str,
                         enabled: Any = _UNSET, modules: dict | None = None,
                         name: Any = _UNSET) -> tuple[dict[str, Any] | None, str | None]:  # type: ignore[assignment]
        """后台管理单台设备：总开关 / 按板块开关 / 备注名。"""
        device_id = str(device_id or "").strip()
        if not device_id:
            return None, "device_id_required"
        with self.store.lock:
            doc = self.store.doc()
            user = doc["users"].get(token)
            if not isinstance(user, dict):
                return None, "unauthorized"
            target = None
            for d in user.get("devices", []):
                if isinstance(d, dict) and str(d.get("device_id") or "") == device_id:
                    target = d
                    break
            if target is None:
                return None, "device_not_found"
            if enabled is not _UNSET:
                target["enabled"] = bool(enabled)
            if name is not _UNSET:
                new_name = str(name or "").strip()[:60]
                if new_name:
                    target["name"] = new_name
            if isinstance(modules, dict):
                cur = target.get("modules") if isinstance(target.get("modules"), dict) else {}
                for k, v in list(modules.items())[:32]:
                    kk = str(k)[:32]
                    if isinstance(v, bool):
                        cur[kk] = v
                target["modules"] = cur
            user["updated_at"] = iso_now()
            doc["users"][token] = user
            self.store.save(doc)
            return self.public_view(user), None

    def _module_access_allowed(self, user_token: str, module: str) -> bool:
        """业务板块准入（如房源 house_access）优先于推送中心的模块开关。"""
        if module == "system" or self.access_checker is None:
            return True
        try:
            return bool(self.access_checker(str(user_token or ""), str(module or "")))
        except Exception:
            log.warning("通知板块准入校验异常 user=%s module=%s", mask_key(user_token), module, exc_info=True)
            return False

    # ---- 事件投递 ----

    @staticmethod
    def _fingerprint(user_token: str, module: str, event_type: str, title: str, body: str) -> str:
        raw = "|".join([user_token, module, event_type, title, body])
        return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:20]

    @staticmethod
    def _trim_events(user: dict[str, Any]) -> None:
        evs = user.get("events")
        if isinstance(evs, list) and len(evs) > MAX_EVENTS_PER_USER:
            user["events"] = evs[-MAX_EVENTS_PER_USER:]

    def _suppressed_locked(self, doc: dict[str, Any], user: dict[str, Any], module: str,
                           event_type: str, title: str, body: str, data: dict | None,
                           reason: str) -> dict[str, Any]:
        """开关关闭/无设备等未实际下发也落一条事件，方便 App「最近投递」排查。调用方持锁。"""
        event = {
            "id": "ev_" + secrets.token_hex(8), "ts": now_ts(), "at": iso_now(),
            "module": module, "type": event_type, "title": title, "body": body,
            "data": data if isinstance(data, dict) else {}, "status": reason,
            "sent": 0, "total": 0, "results": [],
        }
        user.setdefault("events", []).append(event)
        self._trim_events(user)
        self.store.save(doc)
        return {"ok": False, "reason": reason, "sent": 0, "total": 0, "event_id": event["id"]}

    @staticmethod
    def _group(module: str) -> str:
        return {"system": "公寓管家-通道", "meter": "公寓管家-电表",
                "house": "公寓管家-房源", "todo": "公寓管家-待办"}.get(
                    module, f"公寓管家-{module}")

    def broadcast(self, module: str, event_type: str, title: str, body: str,
                  exclude_device_id: str = "", data: dict[str, Any] | None = None,
                  level: str | None = None, subtitle: str = "") -> dict[str, Any]:
        """房源板块广播：投给所有 enabled、模块未禁用、有设备的用户名下设备；
        exclude_device_id 为发起本次修改的设备，跳过它（本机走本地通知，沿用现有文案）。
        改一条推一条，不做合并。"""
        module = str(module or "house")[:32]
        event_type = str(event_type or "change")[:32]
        title = str(title or "通知")[:120]
        body = str(body or "")[:1000]

        # 阶段 A：锁内收集每个用户的投递设备快照（跨用户）
        targets: list[tuple[str, dict, list]] = []
        with self.store.lock:
            doc = self.store.doc()
            for user_token, user in doc["users"].items():
                if not isinstance(user, dict):
                    continue
                # 板块准入优先：如房源板块 house_access=False，即使推送中心开着也不发。
                if not self._module_access_allowed(user_token, module):
                    continue
                prefs = user.get("prefs") if isinstance(user.get("prefs"), dict) else {}
                if prefs.get("enabled") is False:
                    continue
                modules = prefs.get("modules") if isinstance(prefs.get("modules"), dict) else {}
                if modules.get(module, True) is False:
                    continue
                devices = [d for d in user.get("devices", [])
                           if self.device_allows(d, module)
                           and str(d.get("device_id")) != str(exclude_device_id)]
                if not devices:
                    continue
                event = {
                    "id": "ev_" + secrets.token_hex(8), "ts": now_ts(), "at": iso_now(),
                    "module": module, "type": event_type, "title": title, "body": body,
                    "data": data if isinstance(data, dict) else {},
                    "status": "pending", "sent": 0, "total": len(devices), "results": [],
                }
                user.setdefault("events", []).append(event)
                self._trim_events(user)
                snap = [(event["id"], str(d.get("device_id")), str(d.get("bark_key")),
                         str(d.get("name") or "")) for d in devices]
                targets.append((user_token, event, snap))
            self.store.save(doc)

        # 阶段 B：锁外逐用户逐设备投递
        base = self.bark_base()
        timeout = float(self._cfg("bark_timeout_seconds") or HTTP_TIMEOUT)
        group = self._group(module)
        total_sent = total_dev = 0
        reach_users = 0
        for user_token, event, snap in targets:
            results, updates = [], []
            sent = 0
            for _, device_id, key, name in snap:
                payload = {"device_key": key, "title": title, "body": body,
                           "group": group, "isArchive": 1}
                if subtitle:
                    payload["subtitle"] = subtitle[:120]
                if level:
                    payload["level"] = level
                ok, status, resp = self._sender(base, key, payload, timeout)
                err = "" if ok else str((resp or {}).get("error") or (resp or {}).get("message")
                                        or f"Bark 返回状态 {status}")[:200]
                if ok:
                    sent += 1
                results.append({"deviceId": device_id, "name": name,
                                "keyMasked": mask_key(key), "ok": bool(ok),
                                "status": int(status or 0), "error": err, "at": iso_now()})
                updates.append((device_id, bool(ok), err))
                time.sleep(float(self._cfg("device_interval_seconds") or 0.15))
            # 阶段 C：写回该用户事件结果
            with self.store.lock:
                d = self.store.doc()
                u = d["users"].get(user_token)
                if isinstance(u, dict):
                    for dev in u.get("devices", []):
                        for device_id, ok, err in updates:
                            if dev.get("device_id") == device_id:
                                if ok:
                                    dev["last_ok_at"] = now_ts()
                                    dev["last_error"] = ""
                                else:
                                    dev["last_error"] = err
                    for ev in u.get("events", []):
                        if ev.get("id") == event["id"]:
                            ev["results"] = results
                            ev["sent"] = sent
                            ev["total"] = len(snap)
                            ev["status"] = "sent" if sent == len(snap) else (
                                "partial" if sent > 0 else "failed")
                            break
                    self.store.save(doc)
            total_sent += sent
            total_dev += len(snap)
            if sent > 0:
                reach_users += 1
        log.info("房源广播 %s/%s 投递 %d/%d，触达用户 %d",
                 module, event_type, total_sent, total_dev, reach_users)
        return {"ok": total_sent > 0, "sent": total_sent, "total": total_dev,
                "users": len(targets), "reachUsers": reach_users}

    def dispatch(self, user_token: str, module: str, event_type: str, title: str, body: str,
                 data: dict[str, Any] | None = None, idem_key: str | None = None,
                 level: str | None = None, subtitle: str = "") -> dict[str, Any]:
        """业务模块统一入口：只按 user_token 投该用户名下设备，绝不跨用户群发。"""
        module = str(module or "generic")[:32]
        event_type = str(event_type or "alert")[:32]
        title = str(title or "通知")[:120]
        body = str(body or "")[:1000]
        user_token = str(user_token or "")

        # 阶段 A：锁内校验/去重/建事件/取设备快照
        with self.store.lock:
            doc = self.store.doc()
            user = doc["users"].get(user_token)
            if not isinstance(user, dict):
                return {"ok": False, "reason": "unknown_user", "sent": 0, "total": 0}

            # 板块准入优先于推送中心的模块开关（如房源 house_access=False）
            if not self._module_access_allowed(user_token, module):
                return self._suppressed_locked(doc, user, module, event_type, title, body, data,
                                               "module_access_denied")

            prefs = user.get("prefs") if isinstance(user.get("prefs"), dict) else {}
            if prefs.get("enabled") is False:
                return self._suppressed_locked(doc, user, module, event_type, title, body, data,
                                               "user_disabled")
            modules = prefs.get("modules") if isinstance(prefs.get("modules"), dict) else {}
            if modules.get(module, True) is False:
                return self._suppressed_locked(doc, user, module, event_type, title, body, data,
                                               "module_disabled")

            devices = [d for d in user.get("devices", [])
                       if self.device_allows(d, module)]
            if not devices:
                return self._suppressed_locked(doc, user, module, event_type, title, body, data, "no_device")

            fp = self._fingerprint(user_token, module, event_type, title, body)
            ts_now = now_ts()
            for ev in reversed(list(user.get("events", []))[-DEDUP_LOOKBACK:]):
                if (isinstance(ev, dict) and ev.get("fingerprint") == fp
                        and ts_now - float(ev.get("ts") or 0) < DEDUP_WINDOW_SEC
                        and ev.get("status") in ("sent", "partial", "ok")):
                    return {"ok": int(ev.get("sent") or 0) > 0, "dedup": True,
                            "sent": int(ev.get("sent") or 0), "total": int(ev.get("total") or 0),
                            "event_id": ev.get("id")}

            event = {
                "id": "ev_" + secrets.token_hex(8), "ts": ts_now, "at": iso_now(),
                "module": module, "type": event_type, "title": title, "body": body,
                "data": data if isinstance(data, dict) else {},
                "fingerprint": fp, "idem_key": idem_key or fp,
                "status": "pending", "sent": 0, "total": len(devices), "results": [],
            }
            user.setdefault("events", []).append(event)
            self._trim_events(user)
            self.store.save(doc)
            event_id = event["id"]
            snapshot = [(str(d.get("device_id")), str(d.get("bark_key")), str(d.get("name") or ""))
                        for d in devices]

        # 阶段 B：锁外逐设备投递（避免慢 HTTP 阻塞注册/其他事件）
        base, timeout, group = self.bark_base(), float(self._cfg("bark_timeout_seconds") or HTTP_TIMEOUT), self._group(module)
        results: list[dict[str, Any]] = []
        updates: list[tuple[str, bool, str, float]] = []
        sent = 0
        for device_id, key, name in snapshot:
            payload: dict[str, Any] = {
                "device_key": key, "title": title, "body": body,
                "group": group, "isArchive": 1,
            }
            if subtitle:
                payload["subtitle"] = subtitle[:120]
            if level:
                payload["level"] = level
            try:
                ok, status, resp = self._sender(base, key, payload, timeout)
            except Exception as e:  # sender 约定不抛，这里再兜底
                ok, status, resp = False, 0, {"error": str(e)[:200]}
            err = "" if ok else str((resp or {}).get("error") or (resp or {}).get("message")
                                    or f"Bark 返回状态 {status}")[:200]
            if ok:
                sent += 1
            results.append({"deviceId": device_id, "name": name, "keyMasked": mask_key(key),
                            "ok": bool(ok), "status": int(status or 0), "error": err, "at": iso_now()})
            updates.append((device_id, bool(ok), err, now_ts()))
            interval = float(self._cfg("device_interval_seconds") or 0.15)
            if interval > 0 and device_id != snapshot[-1][0]:
                time.sleep(interval)
        total = len(snapshot)

        # 阶段 C：锁内写回投递结果与设备最近状态
        with self.store.lock:
            doc = self.store.doc()
            u = doc["users"].get(user_token)
            if isinstance(u, dict):
                for d in u.get("devices", []):
                    for device_id, ok, err, ts in updates:
                        if d.get("device_id") == device_id:
                            d["last_ok_at"] = ts if ok else d.get("last_ok_at", 0)
                            d["last_error"] = "" if ok else err
                for ev in u.get("events", []):
                    if ev.get("id") == event_id:
                        ev["results"] = results
                        ev["sent"] = sent
                        ev["total"] = total
                        ev["status"] = "sent" if sent == total else ("partial" if sent > 0 else "failed")
                        break
                self._trim_events(u)
                self.store.save(doc)

        log.info("通知事件 %s/%s 投递 %d/%d：%s", module, event_type, sent, total, title)
        return {"ok": sent > 0, "sent": sent, "total": total, "event_id": event_id, "results": results}

    def send_test(self, user_token: str) -> dict[str, Any]:
        user = self.store.get_user(user_token)
        if not user:
            return {"ok": False, "reason": "unknown_user", "sent": 0, "total": 0}
        return self.dispatch(
            user_token, "system", "test", "公寓管家推送通道测试",
            f"通道正常 · {iso_now()} · 本条仅发送到你账号绑定的设备。", level="active")

    # ---- 通知文案模板（用户级，存 notify.json）----

    def get_templates(self, user_token: str, module: str = "meter") -> dict[str, dict] | None:
        defaults = DEFAULT_TEMPLATES.get(module)
        if defaults is None:
            return None
        with self.store.lock:
            user = self.store.doc()["users"].get(user_token)
            if not isinstance(user, dict):
                return None
            saved_m = (user.get("templates") or {}).get(module, {})
            saved_m = saved_m if isinstance(saved_m, dict) else {}
            return {key: normalize_template(saved_m.get(key), dflt)
                    for key, dflt in defaults.items()}

    def set_templates(self, user_token: str, module: str, raw: Any) -> dict[str, dict] | None:
        defaults = DEFAULT_TEMPLATES.get(module)
        if defaults is None:
            return None
        raw = raw if isinstance(raw, dict) else {}
        with self.store.lock:
            doc = self.store.doc()
            user = doc["users"].get(user_token)
            if not isinstance(user, dict):
                return None
            saved_m = user.setdefault("templates", {}).setdefault(module, {})
            for key, dflt in defaults.items():
                if key in raw and isinstance(raw[key], dict):
                    saved_m[key] = normalize_template(raw[key], dflt)
            user["updated_at"] = iso_now()
            doc["users"][user_token] = user
            self.store.save(doc)
            return {key: normalize_template(saved_m.get(key), dflt)
                    for key, dflt in defaults.items()}

    def render_meter(self, user_token: str, event_key: str,
                     variables: dict[str, Any]) -> tuple[str, str, str] | None:
        """返回渲染后的 (title, subtitle, body)；用户不存在返回 None，调用方走硬编码兜底。"""
        tpls = self.get_templates(user_token, "meter")
        if not tpls or event_key not in tpls:
            return None
        tpl = tpls[event_key]
        vars_copy = dict(variables)
        vars_copy["time"] = time_string() if tpl["showTime"] else ""
        return (render_text(tpl["title"], vars_copy),
                render_text(tpl["subtitle"], vars_copy),
                render_text(tpl["body"], vars_copy))

    def preview_template(self, user_token: str, module: str, event_key: str) -> dict[str, Any]:
        if event_key not in DEFAULT_TEMPLATES.get(module, {}):
            return {"ok": False, "error": "unknown_event"}
        sample = {"label": "示例房号", "uid": "012334", "remain": "12.5", "threshold": "30"}
        rendered = self.render_meter(user_token, event_key, sample)
        if rendered is None:
            return {"ok": False, "error": "unauthorized"}
        title, subtitle, body = rendered
        return self.dispatch(user_token, module, "preview_" + event_key, title, body,
                             subtitle=subtitle, data={"preview": True})


# ---------------------------------------------------------------------------
# HTTP 挂载（复用 meter_api 的 handler：_send / _read_json / headers / client_address）
# ---------------------------------------------------------------------------

_fail_lock = threading.Lock()
_fails: dict[str, list[float]] = {}


def _rate_limited(ip: str) -> bool:
    now = time.time()
    with _fail_lock:
        arr = [t for t in _fails.get(ip, []) if now - t < ENROLL_WINDOW_SEC]
        _fails[ip] = arr
        return len(arr) >= ENROLL_MAX_FAILS


def _add_fail(ip: str) -> None:
    with _fail_lock:
        _fails.setdefault(ip, []).append(time.time())


def _clear_fails(ip: str) -> None:
    with _fail_lock:
        _fails.pop(ip, None)


def _bearer(handler: Any) -> str:
    h = ""
    try:
        h = handler.headers.get("Authorization") or ""
    except Exception:
        h = ""
    return h[7:].strip() if h.startswith("Bearer ") else ""


def route_request(handler: Any, method: str, path: str, hub: HubRuntime) -> bool:
    """处理 /api/notify/*；不属于本模块返回 False 交回主路由。任何本前缀路径都算已处理。"""
    if not path.startswith(PREFIX):
        return False
    sub = path[len(PREFIX):].strip("/")
    method = method.upper()

    def send(code: int, obj: dict[str, Any]) -> bool:
        try:
            handler._send(obj, code)
        except Exception:
            log.exception("notify 响应写出失败")
        return True

    try:
        ip = handler.client_address[0] if getattr(handler, "client_address", None) else "?"
        token = _bearer(handler)
        auth_user = hub.store.get_user(token) if token else None

        # 健康探针（无鉴权）
        if sub == "health" and method == "GET":
            users, devices = hub.store.counts()
            return send(200, {"ok": True, "service": "notify-hub", "users": users,
                              "devices": devices, "time": iso_now()})

        # 注册 / 首次绑定 / 已登录更新（Bearer 可选：有有效 token 走更新，否则凭 code 新建）
        if sub == "register" and method == "POST":
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            if auth_user is None and _rate_limited(ip):
                return send(429, {"ok": False, "error": "too_many_attempts"})
            token_arg = token if auth_user is not None else str(body.get("token") or "")
            view, err = hub.register(
                code=str(body.get("code") or ""),
                token=token_arg,
                username=str(body.get("username") or body.get("name") or ""),
                bark_key=str(body.get("barkKey") or body.get("bark_key") or body.get("key") or ""),
                device_name=str(body.get("deviceName") or body.get("device_name") or ""),
                platform=str(body.get("platform") or ""),
                server_base=str(body.get("serverBase") or body.get("server_base") or ""),
            )
            if err:
                if auth_user is None and err == "invalid_code":
                    _add_fail(ip)
                status = {"invalid_code": 403, "username_exists": 409,
                          "invalid_bark_key": 400, "device_limit": 400}.get(err, 400)
                return send(status, {"ok": False, "error": err})
            _clear_fails(ip)
            return send(200, view or {"ok": True})

        # 以下端点必须登录
        if auth_user is None:
            return send(401, {"ok": False, "error": "unauthorized"})

        if sub == "me" and method == "GET":
            return send(200, hub.public_view(auth_user))

        if sub == "events" and method == "GET":
            view = hub.public_view(auth_user, include_events=True)
            return send(200, {"ok": True, "events": view.get("events", [])})

        if sub == "test" and method == "POST":
            return send(200, hub.send_test(token))

        if sub == "prefs" and method == "POST":
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            enabled = body["enabled"] if "enabled" in body else _UNSET
            modules = body.get("modules") if isinstance(body.get("modules"), dict) else None
            username = body["username"] if "username" in body else _UNSET
            view, err = hub.set_prefs(token, enabled=enabled, modules=modules, username=username)
            if err:
                return send(400, {"ok": False, "error": err})
            return send(200, view or {"ok": True})

        if sub == "devices" and method == "POST":
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            action = str(body.get("action") or "remove")
            if action == "remove":
                view = hub.remove_device(
                    token,
                    device_id=str(body.get("deviceId") or body.get("device_id") or ""),
                    bark_key=str(body.get("barkKey") or body.get("bark_key") or ""),
                )
                if view is None:
                    return send(401, {"ok": False, "error": "unauthorized"})
                return send(200, view)
            return send(400, {"ok": False, "error": "unsupported_action"})

        if sub == "reminders" and method == "POST":
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            view, err = hub.replace_reminders(
                token,
                str(body.get("source") or ""),
                body.get("reminders") if isinstance(body.get("reminders"), list) else None,
            )
            if err:
                status = 401 if err == "unauthorized" else 400
                return send(status, {"ok": False, "error": err})
            return send(200, view or {"ok": True})

        # 通知文案模板：读取 / 保存 / 预览（预览会按当前模板真实推送到该用户设备）
        if sub == "templates/meter" and method == "GET":
            tpls = hub.get_templates(token, "meter")
            if tpls is None:
                return send(404, {"ok": False, "error": "module_not_found"})
            return send(200, {"ok": True, "module": "meter", "templates": tpls})

        if sub == "templates/meter" and method == "POST":
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            raw_tpls = body.get("templates") if isinstance(body.get("templates"), dict) else body
            tpls = hub.set_templates(token, "meter", raw_tpls)
            if tpls is None:
                return send(404, {"ok": False, "error": "module_not_found"})
            return send(200, {"ok": True, "module": "meter", "templates": tpls})

        if sub == "templates/meter/preview" and method == "POST":
            body = handler._read_json()
            event_key = str((body or {}).get("eventKey") or "low")
            return send(200, hub.preview_template(token, "meter", event_key))

        if sub.startswith("register") or sub in ("me", "events", "test", "prefs", "devices", "reminders", "health"):
            return send(405, {"ok": False, "error": "method_not_allowed"})
        return send(404, {"ok": False, "error": "not_found"})

    except Exception:
        log.exception("notify 路由处理异常 path=%s method=%s", path, method)
        return send(500, {"ok": False, "error": "notify_server_error"})
