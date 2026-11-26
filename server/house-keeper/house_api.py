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
import time
import urllib.parse
from typing import Any

PREFIX = "/api/house"
PUBLIC_PREFIX = "/api/public"
# 媒体上传上限 60MB（图片 / 视频）
MEDIA_BODY_LIMIT = 60 * 1024 * 1024
# 备份 zip 上传上限 200MB（全量备份含媒体镜像，体积大于单条媒体）
BACKUP_BODY_LIMIT = 200 * 1024 * 1024
# 备份目录归属：当前单库固定 default；阶段 D 可按令牌隔离
BACKUP_OWNER = "default"


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
    if not (path.startswith(PREFIX) or path.startswith(PUBLIC_PREFIX)):
        return False
    method = method.upper()

    def send(code: int, obj: dict[str, Any]) -> bool:
        handler._send(obj, code)
        return True

    def send_file(code: int, data: bytes, content_type: str, download_name: str = "") -> bool:
        handler.send_response(code)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(data)))
        handler.send_header("Cache-Control", "no-store")
        if download_name:
            handler.send_header("Content-Disposition",
                                 f'inline; filename="{download_name}"')
        handler.end_headers()
        try:
            handler.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return True

    def read_raw(limit: int) -> bytes | None:
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except (TypeError, ValueError):
            length = 0
        if length <= 0 or length > limit:
            return None
        return handler.rfile.read(length)

    # 鉴权 + 房源库授权粒度：令牌有效但 house_access=False 的租户仅保留电表通道，
    # 房源相关接口回 403；缺省视为授权，兼容存量租户。公开通道 /api/public/* 不经过这里。
    def auth_house() -> bool:
        auth = handler._require_auth()
        if not auth:
            return False  # _require_auth 已回 401
        _, tenant = auth
        if isinstance(tenant, dict) and tenant.get("house_access") is False:
            send(403, {"ok": False, "error": "forbidden",
                       "detail": "暂无房源访问权限"})
            return False
        return True

    try:
        # ---- 公开只读：脱敏房源 + 媒体（访客无 token，H5/分享页用）----
        if path == f"{PUBLIC_PREFIX}/rooms" and method == "GET":
            return send(200, {"ok": True, "rooms": store.public_rooms()})

        if path.startswith(f"{PUBLIC_PREFIX}/rooms/") and method == "GET":
            key = urllib.parse.unquote(path[len(f"{PUBLIC_PREFIX}/rooms/"):].strip("/"))
            doc = store.public_single(key)
            return send(200 if doc else 404, doc or {"ok": False, "error": "not_found"})

        if path == f"{PUBLIC_PREFIX}/profile" and method == "GET":
            prof = store.profile_get()
            return send(200, {"ok": True, "profile": {
                "name": prof.get("name", ""), "phone": prof.get("phone", ""),
                "qrPath": prof.get("qrPath", "")}})

        if path in (f"{PUBLIC_PREFIX}/h5", f"{PUBLIC_PREFIX}/h5/") and method == "GET":
            import h5_page
            return send_file(200, h5_page.page_html().encode("utf-8"),
                             "text/html; charset=utf-8")

        if path.startswith(f"{PUBLIC_PREFIX}/media/") and method == "GET":
            rel = urllib.parse.unquote(path[len(f"{PUBLIC_PREFIX}/media/"):])
            data = store.media.read_rel(rel)
            if data is None:
                return send(404, {"ok": False, "error": "not_found"})
            return send_file(200, data, store.media.guess_content_type(rel))

        if path == f"{PREFIX}/health" and method == "GET":
            return send(200, {"ok": True, "service": "house-keeper", **store.stats()})

        if path == f"{PREFIX}/stats" and method == "GET":
            if not auth_house():
                return True
            return send(200, {"ok": True, **store.stats()})

        # ---- 名片（姓名 / 电话；二维码图片走媒体通道）----
        if path == f"{PREFIX}/profile" and method == "GET":
            if not auth_house():
                return True
            return send(200, {"ok": True, "profile": store.profile_get()})

        if path == f"{PREFIX}/profile" and method == "PUT":
            if not auth_house():
                return True
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            prof = store.profile_set(
                name=str(body.get("name") or body.get("profile", {}).get("name") or ""),
                phone=str(body.get("phone") or body.get("profile", {}).get("phone") or ""),
                qr_path=str(body.get("qrPath") or ""))
            return send(200, {"ok": True, "profile": prof})

        # ---- 分享记录 ----
        if path == f"{PREFIX}/share-records" and method == "GET":
            if not auth_house():
                return True
            return send(200, {"ok": True, "records": store.share_records_list()})

        if path == f"{PREFIX}/share-records" and method == "POST":
            if not auth_house():
                return True
            body = handler._read_json() or {}
            rec = store.share_records_add(
                room_key=str(body.get("roomKey") or ""),
                channel=str(body.get("channel") or ""),
                summary=str(body.get("summary") or ""),
                operator=str(body.get("operator") or "未知用户"))
            return send(200, {"ok": True, "record": rec})

        # ---- 远程配置 / 在线更新块（服务器权威，本地可改后回写）----
        if path == f"{PREFIX}/config" and method == "GET":
            if not auth_house():
                return True
            return send(200, {"ok": True, "config": store.config_get("app")})

        if path == f"{PREFIX}/config" and method == "PUT":
            if not auth_house():
                return True
            body = handler._read_json()
            if body is None:
                return send(400, {"ok": False, "error": "bad_json"})
            store.config_set("app", body if isinstance(body, dict) else {})
            return send(200, {"ok": True, "config": store.config_get("app")})

        # ---- 房源媒体（服务器磁盘；二进制直传/直出）----
        if path.startswith(f"{PREFIX}/media/"):
            if not auth_house():
                return True
            rest = urllib.parse.unquote(path[len(f"{PREFIX}/media/"):])
            segs = [s for s in rest.strip("/").split("/") if s]
            if len(segs) == 1 and method == "POST":
                room_key = segs[0]
                file_name = handler.headers.get("X-File-Name") or _q(handler).get("filename", "")
                kind = handler.headers.get("X-Kind") or ("video" if file_name.lower().endswith((".mov", ".mp4", ".m4v")) else "image")
                data = read_raw(MEDIA_BODY_LIMIT)
                if data is None:
                    return send(400, {"ok": False, "error": "bad_or_too_large"})
                if not file_name:
                    file_name = store.media.new_file_name(room_key, "mp4" if kind == "video" else "jpg")
                try:
                    rel = store.media.save_house_media(room_key, file_name, data)
                except ValueError as e:
                    return send(400, {"ok": False, "error": str(e)})
                return send(200, {"ok": True, "objectKey": rel,
                                  "fileName": store.media.safe_file_name(file_name),
                                  "kind": kind})
            if len(segs) == 2 and method == "GET":
                room_key, file_name = segs[0], segs[1]
                data = store.media.read_house_media(room_key, file_name)
                if data is None:
                    return send(404, {"ok": False, "error": "not_found"})
                return send_file(200, data, store.media.guess_content_type(rel_path=store.media.rel_house(room_key, file_name)))
            if len(segs) == 2 and method == "DELETE":
                room_key, file_name = segs[0], segs[1]
                store.media.delete_house_media(room_key, file_name)
                return send(200, {"ok": True, "deleted": file_name})
            return send(405, {"ok": False, "error": "method_not_allowed"})

        # ---- 备份 zip（服务器磁盘；替代旧 COS backups/ 目录）----
        if path == f"{PREFIX}/backups" and method == "GET":
            if not auth_house():
                return True
            return send(200, {"ok": True,
                              "backups": store.backups.list_backups(BACKUP_OWNER)})

        if path == f"{PREFIX}/backups" and method == "POST":
            if not auth_house():
                return True
            file_name = handler.headers.get("X-Backup-Name") or _q(handler).get("name", "")
            is_auto = (handler.headers.get("X-Is-Auto") or "").lower() in ("1", "true", "yes")
            data = read_raw(BACKUP_BODY_LIMIT)
            if data is None:
                return send(400, {"ok": False, "error": "bad_or_too_large"})
            if not file_name:
                file_name = f"backup-{int(time.time())}.zip"
            try:
                record = store.backups.save(BACKUP_OWNER, file_name, data, is_auto)
            except ValueError as e:
                return send(400, {"ok": False, "error": str(e)})
            return send(200, {"ok": True, "record": record})

        if path.startswith(f"{PREFIX}/backups/"):
            if not auth_house():
                return True
            rest = urllib.parse.unquote(path[len(f"{PREFIX}/backups/"):])
            segs = [s for s in rest.strip("/").split("/") if s]
            if len(segs) != 1:
                return send(404, {"ok": False, "error": "not_found"})
            name = segs[0]
            if method == "GET":
                data = store.backups.read(BACKUP_OWNER, name)
                if data is None:
                    return send(404, {"ok": False, "error": "not_found"})
                return send_file(200, data, "application/zip", download_name=name)
            if method == "DELETE":
                deleted = store.backups.delete(BACKUP_OWNER, name)
                if not deleted:
                    return send(404, {"ok": False, "error": "not_found"})
                return send(200, {"ok": True, "deleted": name})
            return send(405, {"ok": False, "error": "method_not_allowed"})


        # ---- 集合级 ----
        if path == f"{PREFIX}/houses" and method == "GET":
            if not auth_house():
                return True
            q = _q(handler)
            since = int(q["since"]) if q.get("since", "").isdigit() else None
            include_deleted = q.get("includeDeleted") in ("1", "true")
            payload = store.list_houses(since=since, include_deleted=include_deleted)
            return send(200, {"ok": True, **payload})

        if path in (f"{PREFIX}/houses", f"{PREFIX}/houses:batch") and method == "POST":
            if not auth_house():
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
                    # 带回完整权威 doc，客户端一次请求即拿到服务器回写的 revision/
                    # 时间戳/媒体，无需再 getObject，单条与 batch 结构一致
                    results.append({"ok": True, "roomKey": doc["roomKey"],
                                    "revision": doc["revision"], "house": doc})
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
            if not auth_house():
                return True
            doc = store.get_house(segs[0])
            return send(200 if doc else 404, doc or {"ok": False, "error": "not_found"})

        if len(segs) == 1 and method == "DELETE":
            if not auth_house():
                return True
            body = handler._read_json() or {}
            operator = str(body.get("operator") or "未知用户")
            origin = str(body.get("originDeviceId") or "")
            # 硬删：服务器库与本地一并移除，不进回收站；COS 媒体实体本轮保留不动
            doc = store.hard_delete(segs[0], operator, origin)
            _spawn_deliver(store, hub)
            return send(200, {"ok": True, **doc})

        if len(segs) == 2 and segs[1] == "restore" and method == "POST":
            if not auth_house():
                return True
            body = handler._read_json() or {}
            operator = str(body.get("operator") or "未知用户")
            origin = str(body.get("originDeviceId") or "")
            doc = store.set_deleted(segs[0], False, operator, origin)
            _spawn_deliver(store, hub)
            return send(200, {"ok": True, **doc})

        if len(segs) == 2 and segs[1] == "ledger" and method == "GET":
            if not auth_house():
                return True
            return send(200, {"ok": True, "roomKey": segs[0],
                              "ledger": store.ledger(segs[0])})

        if len(segs) == 2 and segs[1] == "ledger" and method == "POST":
            if not auth_house():
                return True
            body = handler._read_json() or {}
            operator = str(body.get("operator") or "未知用户")
            events = body.get("events") if isinstance(body.get("events"), list) else [body]
            results = []
            for ev in events:
                if not isinstance(ev, dict):
                    continue
                try:
                    res = store.append_ledger_event(segs[0], ev, operator=operator)
                    results.append({"ok": True, **res})
                except Exception as e:
                    results.append({"ok": False, "error": "bad_request",
                                    "detail": str(e)[:200]})
            return send(200, {"ok": all(r["ok"] for r in results), "results": results})

        return send(404, {"ok": False, "error": "not_found"})
    except Exception:
        import logging
        logging.getLogger("house-api").exception("house 路由异常 path=%s", path)
        return send(500, {"ok": False, "error": "server_error"})
