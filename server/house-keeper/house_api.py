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

import logging
import threading
import time
import urllib.parse
from typing import Any

PREFIX = "/api/house"
PUBLIC_PREFIX = "/api/public"
# 媒体上传上限 500MB（图片 / 视频）
MEDIA_BODY_LIMIT = 500 * 1024 * 1024
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


_DELIVER_LOCK = threading.Lock()


def _public_event_data(raw: Any) -> dict[str, Any]:
    """投递事件里不携带内部通知范围字段，避免把目标用户 token 带进事件详情。"""
    data = dict(raw) if isinstance(raw, dict) else {}
    data.pop("notifyScope", None)
    data.pop("notifyUserToken", None)
    return data


def deliver_pending(store: Any, hub: Any) -> None:
    """把待投递 outbox 逐条投递；同一进程同一时刻只允许一个投递者。

    这是单进程部署的单飞锁：后台保存、App 保存、值守 tick 同时触发时，
    不会再有两条线程同时拿到同一条 pending outbox 而重复广播。
    """
    if hub is None:
        return
    if not _DELIVER_LOCK.acquire(blocking=False):
        return
    try:
        for item in store.pending_outbox(limit=50):
            data = item.get("data") if isinstance(item.get("data"), dict) else {}
            scope = str(data.get("notifyScope") or "all").lower()
            public_data = _public_event_data(data)

            if scope == "none":
                store.mark_outbox(item["id"], "skipped")
                continue

            if scope == "self":
                target = str(data.get("notifyUserToken") or "")
                if not target:
                    store.mark_outbox(item["id"], "failed")
                    continue
                res = hub.dispatch(
                    target, "house", item["action"], item["title"], item["body"],
                    data=public_data)
            else:
                res = hub.broadcast(
                    "house", item["action"], item["title"], item["body"],
                    exclude_device_id=item["originDeviceId"], data=public_data)

            # broadcast 没有目标设备时允许标记 sent（账本已可追溯，不永久堆积）。
            # 全部目标失败则保留 pending，交由值守 tick 下一轮重试。
            if res.get("ok") or (scope != "self" and res.get("total", 0) == 0):
                store.mark_outbox(item["id"], "sent")
            elif scope == "self" and res.get("reason") in ("unknown_user", "no_device",
                                                            "module_access_denied",
                                                            "user_disabled", "module_disabled"):
                store.mark_outbox(item["id"], "failed")
    except Exception:  # 单条失败不影响其余，下轮兜底继续
        logging.getLogger("house-api").exception("outbox 投递异常")
    finally:
        _DELIVER_LOCK.release()


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

        # b29：公开在线更新块。检查更新只依赖这份非敏感信息，不再受房屋库授权 token 影响。
        if path == f"{PUBLIC_PREFIX}/app-update" and method == "GET":
            app_cfg = store.config_get("app")
            keys = ("update", "changelog", "minimumVersion")
            public_cfg = {k: app_cfg[k] for k in keys if k in app_cfg}
            return send(200, {"ok": True, **public_cfg})

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

        # b29：设置页服务器磁盘用量（鉴权后返回；后台看板早就有同一口径）
        if path == f"{PREFIX}/storage" and method == "GET":
            if not auth_house():
                return True
            return send(200, {"ok": True, **store.storage_stats()})

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

        # ---- 操作日志（云端日志区，服务器权威；App 与后台共用）----
        if path == f"{PREFIX}/ops":
            if not auth_house():
                return True
            if method == "GET":
                q = _q(handler)
                try:
                    limit = int(q.get("limit") or 200)
                except ValueError:
                    limit = 200
                return send(200, {"ok": True, "records": store.list_ops(limit)})
            if method == "POST":
                body = handler._read_json()
                if not isinstance(body, dict):
                    return send(400, {"ok": False, "error": "bad_json"})
                res = store.append_op(
                    category=str(body.get("category") or ""),
                    action=str(body.get("action") or ""),
                    result=str(body.get("result") or ""),
                    detail=str(body.get("detail") or ""),
                    room=str(body.get("room") or ""),
                    operator=str(body.get("operator") or body.get("user") or ""))
                return send(200, res)
            if method == "DELETE":
                q = _q(handler)
                store.delete_op(
                    op_id=q.get("id") or "", t=q.get("t") or "",
                    op=q.get("op") or "", room=q.get("room") or "",
                    user=q.get("user") or "", detail=q.get("detail") or "")
                return send(200, {"ok": True})
            return send(405, {"ok": False, "error": "method_not_allowed"})

        # ---- 孤儿媒体（设置页「清理服务器孤儿媒体」；只扫 media_v2/houses）----
        if path == f"{PREFIX}/media-orphans" and method == "GET":
            if not auth_house():
                return True
            q = _q(handler)
            try:
                min_age = int(q.get("minAge") or 3600)
            except ValueError:
                min_age = 3600
            return send(200, {"ok": True, **store.list_orphan_media(min_age)})

        if path == f"{PREFIX}/media-orphans" and method == "DELETE":
            if not auth_house():
                return True
            body = handler._read_json()
            if not isinstance(body, dict):
                return send(400, {"ok": False, "error": "bad_json"})
            try:
                min_age = int(body.get("minAge") or 3600)
            except (TypeError, ValueError):
                min_age = 3600
            keys = body.get("objectKeys") or []
            if not isinstance(keys, list):
                return send(400, {"ok": False, "error": "objectKeys must be array"})
            return send(200, store.delete_orphan_media(keys, min_age))

        # ---- 房源媒体（服务器磁盘；二进制直传/直出）----
        if path.startswith(f"{PREFIX}/media/"):
            if not auth_house():
                return True
            rest = urllib.parse.unquote(path[len(f"{PREFIX}/media/"):])
            segs = [s for s in rest.strip("/").split("/") if s]
            if len(segs) == 1 and method == "POST":
                room_key = segs[0]
                # 客户端把中文文件名百分号编码后放进 HTTP 头（HTTP 头只能是 ASCII），
                # 这里必须还原，否则中文房号会被截成 "1-1234" 这类 ASCII 前缀，落盘名与账本对不上。
                raw_file_name = (handler.headers.get("X-File-Name")
                                 or _q(handler).get("filename", ""))
                file_name = urllib.parse.unquote(raw_file_name or "")
                kind = handler.headers.get("X-Kind") or ("video" if file_name.lower().endswith((".mov", ".mp4", ".m4v")) else "image")
                try:
                    length = int(handler.headers.get("Content-Length") or 0)
                except (TypeError, ValueError):
                    length = 0
                # 诊断日志：只记录文件名/类型/长度/传输头，不记录令牌和请求体
                print(
                    f"[media] upload room={room_key!r} file={file_name!r} kind={kind!r} "
                    f"length={length} te={handler.headers.get('Transfer-Encoding')!r} "
                    f"ct={handler.headers.get('Content-Type')!r} "
                    f"ua={handler.headers.get('User-Agent')!r}",
                    flush=True,
                )
                if length <= 0 or length > MEDIA_BODY_LIMIT:
                    print(f"[media] reject length={length} limit={MEDIA_BODY_LIMIT} file={file_name!r} path={handler.path}", flush=True)
                    # 请求体未消费就回 400：必须关闭 keep-alive，否则剩余二进制会被当成下一个请求行解析
                    handler.close_connection = True
                    return send(400, {"ok": False, "error": "bad_or_too_large", "length": length, "limit": MEDIA_BODY_LIMIT})
                if not file_name or not store.media.safe_file_name(file_name):
                    file_name = store.media.new_file_name(room_key, "mp4" if kind == "video" else "jpg")
                # 同名/无后缀先唯一化：返回给客户端的 fileName 与实际落盘名必须一致，
                # 不能出现“第一张被后一张同名文件覆盖、账本却仍指旧名”的静默丢图。
                file_name = store.media.unique_house_file_name(room_key, file_name, kind=kind)
                try:
                    # 文件名后缀白名单只用于常规落盘；HTTP 上传入口放宽未知后缀，
                    # 避免历史/跨端文件名（.heif/.avi/编码差异）让整次媒体上传 400。
                    rel = store.media.save_house_media_stream(
                        room_key, file_name, handler.rfile, length,
                        allow_unknown_ext=True, kind=kind)
                except ValueError as e:
                    print(f"[media] fail room={room_key!r} file={file_name!r} kind={kind!r} length={length} error={e!r}", flush=True)
                    # 出错时请求体可能仍未读完，关闭连接，避免 Bad request version 噪声
                    handler.close_connection = True
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
            top_expected = body.get("expectedRevision")
            top_expected = int(top_expected) if isinstance(top_expected, int) else None
            items = body.get("houses") if path.endswith(":batch") else [body]
            results = []
            for it in items:
                if not isinstance(it, dict):
                    results.append({"ok": False, "error": "bad_request",
                                    "detail": "item must be object"})
                    continue
                # 批量条目自己的 expectedRevision 优先；顶层仅作兼容旧客户端的兜底。
                item_expected = it.get("expectedRevision")
                expected = (int(item_expected) if isinstance(item_expected, int)
                            else top_expected)
                try:
                    doc = store.upsert_house(
                        it, operator=operator, origin_device_id=origin,
                        expected_revision=expected,
                        create_only=bool(it.get("createOnly") or body.get("createOnly")))
                    # 带回完整权威 doc，客户端一次请求即拿到服务器回写的 revision/
                    # 时间戳/媒体，无需再 getObject，单条与 batch 结构一致
                    results.append({"ok": True, "roomKey": doc["roomKey"],
                                    "revision": doc["revision"], "house": doc})
                except Exception as e:  # 冲突等回传错误码，客户端刷新重试
                    name = type(e).__name__
                    if "DuplicateHouse" in name:
                        code = "duplicate_room"
                        detail = f"房号 {it.get('roomKey') or ''} 已存在，同一座同一房号不能重复添加"
                    elif "FieldConflict" in name:
                        code = "field_conflict"
                        detail = "同一字段已被其他设备修改"
                        results.append({"ok": False, "error": code, "detail": detail,
                                        "conflicts": getattr(e, "conflicts", [])})
                        continue
                    elif "RevisionConflict" in name:
                        code = "revision_conflict"
                        detail = str(e)[:200]
                    else:
                        code = "bad_request"
                        detail = str(e)[:200]
                    results.append({"ok": False, "error": code, "detail": detail})
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
