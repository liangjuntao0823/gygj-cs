#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 房源板块 HTTP 路由（house_api）
=========================================
以鸭子类型挂载到 8082 的 CloudHandler（复用其 _send/_read_json/_require_auth），
不新开端口。结构化数据落 HouseStore(SQLite)，写入成功后立即异步投递 outbox，
经 notify_hub.broadcast 实时推送到所有接入设备（排除发起设备）。

路由（均需 Bearer，health 除外）：
  GET  /api/house/health
  GET  /api/house/stats
  GET  /api/house/houses?since=&includeDeleted=
  GET  /api/house/houses/{roomKey}
  GET  /api/house/houses/{roomKey}/ledger
  POST /api/house/houses                 upsert（body 带 expectedRevision/originDeviceId/operator）
  POST /api/house/houses:batch
  DELETE /api/house/houses/{roomKey}     软删除（移入回收站）
  POST /api/house/houses/{roomKey}/restore
"""

from __future__ import annotations

import threading
import urllib.parse
from typing import Any

PREFIX = "/api/house"


def _q(handler: Any) -> dict[str, str]:
    parsed = urllib.parse.urlparse(handler.path)
    return dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))


def _bearer(handler: Any) -> str:
    h = handler.headers.get("Authorization") or ""
    return h[7:].strip() if h.startswith("Bearer ") else ""


def deliver_pending(store: Any, hub: Any) -> None:
    """把待投递 outbox 逐条广播；成功标记 sent，失败留 pending 等下轮重试。"""
    try:
        for item in store.pending_outbox(limit=50):
            res = hub.broadcast(
                "house", item["action"], item["title"], item["body"],
                exclude_device_id=item["originDeviceId"], data=item["data"])
            # 标记 sent 的两种情形：①至少一台设备投递成功(ok)；②无任何目标设备
            # (total=0)，事件已在账本可追溯，不永久堆积。有设备却全部失败则保留
            # pending，交由 worker 定时分支下轮重试，避免丢推送。
            if res.get("ok") or res.get("total", 0) == 0:
                store.mark_outbox(item["id"], "sent")
    except Exception:  # 单条失败不影响其余，下轮兜底继续
        import logging
        logging.getLogger("house-api").exception("outbox 投递异常")


def _spawn_deliver(store: Any, hub: Any) -> None:
    if hub is None:
        return
    t = threading.Thread(target=deliver_pending, args=(store, hub), daemon=True)
    t.start()


def route_request(handler: Any, method: str, path: str, store: Any, hub: Any) -> bool:
    if not path.startswith(PREFIX):
        return False
    method = method.upper()

    def send(code: int, obj: dict[str, Any]) -> bool:
        handler._send(obj, code)
        return True

    try:
        if path == f"{PREFIX}/health" and method == "GET":
            return send(200, {"ok": True, "service": "house-keeper", **store.stats()})

        if path == f"{PREFIX}/stats" and method == "GET":
            if not handler._require_auth():
                return True
            return send(200, {"ok": True, **store.stats()})

        # ---- COS 临时凭证：服务器签发，客户端按需取用，永久密钥不落 App ----
        if path == f"{PREFIX}/cos-credentials" and method == "GET":
            if not handler._require_auth():
                return True
            try:
                import cos_sts
                return send(200, cos_sts.credentials_for_client())
            except Exception as e:
                return send(503, {"ok": False, "error": "sts_unavailable",
                                  "detail": str(e)[:200]})

        # ---- 集合级 ----
        if path == f"{PREFIX}/houses" and method == "GET":
            if not handler._require_auth():
                return True
            q = _q(handler)
            since = int(q["since"]) if q.get("since", "").isdigit() else None
            include_deleted = q.get("includeDeleted") in ("1", "true")
            return send(200, store.list_houses(since=since, include_deleted=include_deleted))

        if path in (f"{PREFIX}/houses", f"{PREFIX}/houses:batch") and method == "POST":
            if not handler._require_auth():
                return True
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            operator = str(body.get("operator") or "未知用户")
            origin = str(body.get("originDeviceId") or "")
            expected = body.get("expectedRevision")
            expected = int(expected) if isinstance(expected, int) else None
            items = body.get("houses") if path.endswith(":batch") else [body]
            results = []
            for it in items:
                try:
                    doc = store.upsert_house(
                        it, operator=operator, origin_device_id=origin,
                        expected_revision=expected)
                    results.append({"ok": True, "roomKey": doc["roomKey"],
                                    "revision": doc["revision"]})
                except Exception as e:  # 冲突等回传错误码，客户端刷新重试
                    code = "revision_conflict" if "RevisionConflict" in type(e).__name__ else "bad_request"
                    results.append({"ok": False, "error": code, "detail": str(e)[:200]})
            _spawn_deliver(store, hub)
            return send(200, {"ok": all(r["ok"] for r in results), "results": results})

        # ---- 单套房：解析 roomKey（可能含中文，URL 已编码）----
        rest = path[len(PREFIX) + len("/houses"):]
        rest = urllib.parse.unquote(rest)
        if rest and method == "GET" and not rest.startswith("/"):
            return send(404, {"ok": False, "error": "not_found"})
        segs = [s for s in rest.strip("/").split("/") if s]

        if len(segs) == 1 and method == "GET":
            if not handler._require_auth():
                return True
            doc = store.get_house(segs[0])
            return send(200 if doc else 404, doc or {"ok": False, "error": "not_found"})

        if len(segs) == 1 and method == "DELETE":
            if not handler._require_auth():
                return True
            body = handler._read_json() or {}
            operator = str(body.get("operator") or "未知用户")
            origin = str(body.get("originDeviceId") or "")
            doc = store.set_deleted(segs[0], True, operator, origin)
            _spawn_deliver(store, hub)
            return send(200, {"ok": True, **doc})

        if len(segs) == 2 and segs[1] == "restore" and method == "POST":
            if not handler._require_auth():
                return True
            body = handler._read_json() or {}
            operator = str(body.get("operator") or "未知用户")
            origin = str(body.get("originDeviceId") or "")
            doc = store.set_deleted(segs[0], False, operator, origin)
            _spawn_deliver(store, hub)
            return send(200, {"ok": True, **doc})

        if len(segs) == 2 and segs[1] == "ledger" and method == "GET":
            if not handler._require_auth():
                return True
            return send(200, {"ok": True, "roomKey": segs[0],
                              "ledger": store.ledger(segs[0])})

        return send(404, {"ok": False, "error": "not_found"})
    except Exception:
        import logging
        logging.getLogger("house-api").exception("house 路由异常 path=%s", path)
        return send(500, {"ok": False, "error": "server_error"})
