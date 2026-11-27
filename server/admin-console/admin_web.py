#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 管理后台 —— HTTP 路由装配（admin_web）
=================================================
挂载在现有 8082 CloudHandler 下，独立于 App 业务 Bearer 令牌的会话鉴权：
- 除登录接口与静态页外，所有 /admin/api/* 都需 Cookie `admin_session`。
- 后端模块实例由 ctx.admin 注入（auth / sys / meter / house / hub），便于单测替换。

通知范围选择（涉及 App 端的改动）：
- 请求体可带 notifyScope: "none" | "self" | "all"；
  * self：推给对应绑定用户（电表账户操作用），需 notifyUser（hub userToken 或脱敏串）；
  * all：广播给所有参与该模块管理的用户（房源删除/改数据等）；
  * none：不推送。
- 模块归属：电表改动 module="meter"。
- 房源改动只写 outbox，由 house_api.deliver_pending 统一投递；后台不再二次直推。
"""

from __future__ import annotations

import json
import logging
import threading
import urllib.parse
from pathlib import Path
from typing import Any

log = logging.getLogger("admin-web")

PREFIX = "/admin"
SESSION_COOKIE = "admin_session"


# ---------------------------------------------------------------------------
# 小工具（与 handler 解耦，单测可直接调用）
# ---------------------------------------------------------------------------

def _cookies(handler: Any) -> dict[str, str]:
    raw = handler.headers.get("Cookie", "")
    out: dict[str, str] = {}
    for part in raw.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def _send_json(handler: Any, status: int, obj: dict[str, Any],
               cookies: dict[str, str] | None = None) -> None:
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    if cookies is not None:
        for k, v in cookies.items():
            handler.send_header("Set-Cookie", f"{k}={v}; Path=/; HttpOnly; SameSite=Lax")
    handler.end_headers()
    handler.wfile.write(body)


def _send_file(handler: Any, status: int, body: bytes, filename: str,
               content_type: str) -> None:
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header(
        "Content-Disposition",
        f"attachment; filename*=UTF-8''{urllib.parse.quote(filename)}")
    handler.end_headers()
    handler.wfile.write(body)


def _read_body(handler: Any) -> dict[str, Any]:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = handler.rfile.read(min(length, 1_000_000))
        obj = json.loads(raw.decode("utf-8", "replace"))
        return obj if isinstance(obj, dict) else {}
    except Exception:
        return {}


def _notify(admin: Any, scope: str, module: str, title: str, body: str,
            notify_user: str = "", data: dict[str, Any] | None = None) -> dict[str, Any]:
    """按推送范围下发 Bark。返回投递摘要；hub 缺失时返回 not_configured。"""
    hub = getattr(admin, "hub", None)
    if hub is None:
        return {"sent": 0, "total": 0, "reason": "hub_unavailable"}
    scope = str(scope or "none")
    if scope == "none":
        return {"sent": 0, "total": 0, "reason": "not_requested"}
    if scope == "self":
        user_token = _resolve_user_token(admin, notify_user)
        if not user_token:
            return {"sent": 0, "total": 0, "reason": "user_not_found"}
        res = hub.dispatch(user_token, module, "admin_action", title, body, data=data)
        return {"sent": int(res.get("sent") or 0), "total": int(res.get("total") or 0),
                "reason": "dispatched"}
    # all：广播
    res = hub.broadcast(module, "admin_action", title, body, data=data)
    return {"sent": int(res.get("sent") or 0), "total": int(res.get("total") or 0),
            "reason": "broadcast"}


def _resolve_user_token(admin: Any, hint: str) -> str:
    """self 推送：hint 可能是 hub userToken 原文或 username，也可能是电表脱敏 token。"""
    hint = str(hint or "").strip()
    if not hint:
        return ""
    hub = getattr(admin, "hub", None)
    if hub is not None:
        user = hub.store.get_user(hint)
        if user is not None:
            return hint
        # 按用户名回查
        for token, u in hub.store.doc()["users"].items():
            if isinstance(u, dict) and str(u.get("username") or "") == hint:
                return token
    meter = getattr(admin, "meter", None)
    if meter is not None:
        full = meter.resolve_token(hint)
        if full:
            tenant = meter.store.load_tenants().get(full)
            if isinstance(tenant, dict):
                return str(tenant.get("notify_user_token") or "")
    return ""


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------

def _spawn_house_delivery(admin: Any, notify_scope: str) -> None:
    """后台房源写完后只触发 outbox 投递，不直接调用 hub 广播。"""
    if notify_scope == "none":
        return
    house = getattr(admin, "house", None)
    if house is None:
        return
    t = threading.Thread(target=house.deliver_pending, daemon=True)
    t.start()


def route_request(handler: Any, method: str, path: str, admin: Any) -> bool:
    """返回 True 表示已处理；False 表示路径不属于后台，交给上层 404。"""
    if not path.startswith(PREFIX):
        return False

    # 静态页
    if method == "GET" and path in (PREFIX, PREFIX + "/", PREFIX + "/index.html"):
        _serve_static(handler)
        return True

    if not path.startswith(PREFIX + "/api/"):
        return True

    # ---- 鉴权 ----
    auth = admin.auth
    cookies = _cookies(handler)
    token = cookies.get(SESSION_COOKIE, "")

    # 登录 / 退出 免鉴权
    if path == PREFIX + "/api/login" and method == "POST":
        body = _read_body(handler)
        res = auth.login(str(body.get("username") or ""), str(body.get("password") or ""))
        if res.get("ok"):
            _send_json(handler, 200, res,
                       cookies={SESSION_COOKIE: res["token"]})
        else:
            _send_json(handler, 401, res)
        return True

    if path == PREFIX + "/api/logout" and method == "POST":
        auth.logout(token)
        _send_json(handler, 200, {"ok": True}, cookies={SESSION_COOKIE: ""})
        return True

    # 会话探针（公开）：未登录也返回 200，由前端决定展示登录页，避免 401 触发前端刷新循环
    if path == PREFIX + "/api/meta" and method == "GET":
        uname = auth.verify(token)
        if not uname:
            _send_json(handler, 200, {"ok": True, "authenticated": False,
                                      "username": None, "mustChange": False})
        else:
            _send_json(handler, 200, {"ok": True, "authenticated": True,
                                      "username": uname,
                                      "mustChange": auth.must_change(uname)})
        return True

    username = auth.verify(token)
    if not username:
        _send_json(handler, 401, {"ok": False, "error": "unauthorized"})
        return True

    # 改密
    if path == PREFIX + "/api/password" and method == "POST":
        body = _read_body(handler)
        res = auth.change_password(token, str(body.get("newPassword") or ""))
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True

    # ---- 服务器管理 ----
    if path == PREFIX + "/api/sys/overview" and method == "GET":
        _send_json(handler, 200, {"ok": True, "overview": admin.sys.overview()})
        return True
    if path == PREFIX + "/api/sys/services" and method == "GET":
        _send_json(handler, 200, {"ok": True, "services": admin.sys.services()})
        return True
    if path == PREFIX + "/api/sys/audit" and method == "GET":
        _send_json(handler, 200, {"ok": True, "audit": admin.sys.audit_log()})
        return True
    if path == PREFIX + "/api/sys/control" and method == "POST":
        body = _read_body(handler)
        res = admin.sys.control(str(body.get("unit") or ""),
                                str(body.get("action") or ""), username)
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True

    # ---- 电表值守 ----
    if path == PREFIX + "/api/meter/tenants" and method == "GET":
        _send_json(handler, 200, admin.meter.tenants())
        return True
    if path == PREFIX + "/api/meter/code" and method == "GET":
        _send_json(handler, 200, {"ok": True, **admin.meter.code_info()})
        return True
    if path == PREFIX + "/api/meter/code/rotate" and method == "POST":
        _send_json(handler, 200, {"ok": True, **admin.meter.rotate_code()})
        return True
    if path == PREFIX + "/api/meter/export" and method == "GET":
        data, fname = admin.meter.snapshot_export()
        _send_file(handler, 200, data, fname, "application/json; charset=utf-8")
        return True

    rest = path[len(PREFIX + "/api/meter/tenants"):]
    segs = [urllib.parse.unquote(s) for s in rest.strip("/").split("/") if s]
    if len(segs) == 2 and segs[1] == "enabled":
        body = _read_body(handler)
        res = admin.meter.set_enabled(segs[0], bool(body.get("enabled")))
        if res.get("ok"):
            notify = _notify(admin, body.get("notifyScope", "self"), "meter",
                              "电表值守状态变更",
                              f"账户 {segs[0]} 值守已{'开启' if body.get('enabled') else '暂停'}",
                              body.get("notifyUser", ""), {"action": "set_enabled"})
            res["notify"] = notify
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True
    if len(segs) == 2 and segs[1] == "settings":
        body = _read_body(handler)
        res = admin.meter.update_settings(segs[0], body.get("settings") or {})
        if res.get("ok"):
            notify = _notify(admin, body.get("notifyScope", "self"), "meter",
                             "电表值守配置变更", f"账户 {segs[0]} 阈值/轮询已更新",
                             body.get("notifyUser", ""), {"action": "update_settings"})
            res["notify"] = notify
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True

    # ---- 推送中心 ----
    if path == PREFIX + "/api/push/overview" and method == "GET":
        _send_json(handler, 200, admin.push.overview())
        return True

    rest = path[len(PREFIX + "/api/push"):]
    segs = [urllib.parse.unquote(s) for s in rest.strip("/").split("/") if s]
    if len(segs) == 3 and segs[0] == "users" and segs[2] == "prefs" and method == "POST":
        body = _read_body(handler)
        res = admin.push.set_user(segs[1], enabled=body.get("enabled"),
                                  modules=body.get("modules"))
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True
    if len(segs) == 4 and segs[0] == "users" and segs[2] == "devices" and method == "POST":
        body = _read_body(handler)
        res = admin.push.set_device(segs[1], segs[3], enabled=body.get("enabled"),
                                    modules=body.get("modules"), name=body.get("name"))
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True
    if len(segs) == 5 and segs[0] == "users" and segs[2] == "devices" \
            and segs[4] == "remove" and method == "POST":
        res = admin.push.remove_device(segs[1], segs[3])
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True

    # ---- 房源板块接入用户 ----
    if path == PREFIX + "/api/house/users" and method == "GET":
        _send_json(handler, 200, admin.push.house_users())
        return True
    rest = path[len(PREFIX + "/api/house/users"):]
    segs = [urllib.parse.unquote(s) for s in rest.strip("/").split("/") if s]
    if len(segs) == 2 and segs[1] == "access" and method == "POST":
        body = _read_body(handler)
        res = admin.push.set_house_access(segs[0], bool(body.get("enabled")))
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True

    # ---- 房源管理 ----
    if path == PREFIX + "/api/house/export" and method == "GET":
        q = urllib.parse.urlparse(handler.path).query
        fmt = "csv" if "format=csv" in q else "json"
        data, fname = (admin.house.export_csv() if fmt == "csv"
                       else admin.house.export_json())
        ctype = "text/csv; charset=utf-8" if fmt == "csv" else "application/json; charset=utf-8"
        _send_file(handler, 200, data, fname, ctype)
        return True
    if path == PREFIX + "/api/house/houses" and method == "GET":
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(handler.path).query)
        _send_json(handler, 200, admin.house.list(
            q=(qs.get("q") or [""])[0], tower=(qs.get("tower") or [""])[0],
            status=(qs.get("status") or [""])[0]))
        return True

    rest = path[len(PREFIX + "/api/house/houses"):]
    segs = [urllib.parse.unquote(s) for s in rest.strip("/").split("/") if s]
    if len(segs) == 1 and method == "GET":
        doc = admin.house.detail(segs[0])
        if doc is None:
            _send_json(handler, 404, {"ok": False, "error": "not_found"})
        else:
            _send_json(handler, 200, {"ok": True, "house": doc})
        return True
    if len(segs) == 1 and method == "PUT":
        body = _read_body(handler)
        scope = str(body.get("notifyScope") or "all").lower()
        notify_user_token = ""
        if scope == "self":
            notify_user_token = _resolve_user_token(admin, body.get("notifyUser", ""))
            if not notify_user_token:
                scope = "none"
        res = admin.house.update(
            segs[0], body.get("fields") or {},
            notify_scope=scope, notify_user_token=notify_user_token)
        if res.get("ok"):
            _spawn_house_delivery(admin, scope)
            res["notify"] = {"queued": scope != "none", "scope": scope}
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True
    if len(segs) == 2 and segs[1] in ("delete", "restore") and method == "POST":
        body = _read_body(handler)
        deleted = segs[1] == "delete"
        scope = str(body.get("notifyScope") or "all").lower()
        notify_user_token = ""
        if scope == "self":
            notify_user_token = _resolve_user_token(admin, body.get("notifyUser", ""))
            if not notify_user_token:
                scope = "none"
        res = admin.house.set_deleted(
            segs[0], deleted, notify_scope=scope, notify_user_token=notify_user_token)
        if res.get("ok"):
            _spawn_house_delivery(admin, scope)
            res["notify"] = {"queued": scope != "none", "scope": scope}
        _send_json(handler, 200 if res.get("ok") else 400, res)
        return True
    if len(segs) == 2 and segs[1] == "ledger" and method == "GET":
        _send_json(handler, 200, {"ok": True, "ledger": admin.house.ledger(segs[0])})
        return True

    _send_json(handler, 404, {"ok": False, "error": "not_found"})
    return True


def _serve_static(handler: Any) -> None:
    static_dir = Path(__file__).resolve().parent / "admin_static"
    page = static_dir / "index.html"
    try:
        body = page.read_bytes()
    except OSError:
        body = b"<h1>admin console missing</h1>"
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
