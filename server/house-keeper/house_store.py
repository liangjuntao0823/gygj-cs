#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 房源板块服务器权威存储（house_store）
================================================
用户 2026-11-25 拍板：SQLite + 8082 内模块化扩展。本模块只负责结构化数据，
媒体文件实体仍在腾讯云 COS，这里只存对象引用（object_key）。

设计要点：
* 服务器为唯一权威：客户端不再做拉合并，所有写操作走本模块，单事务内完成
  「写房源 + 修订号 +1 + 操作账本 + 字段 diff + outbox 变更事件」，保证一次
  改动必有一条可推送事件，不丢。
* 乐观锁：写入带期望修订号，被他人抢先则抛 RevisionConflict，客户端刷新后重试。
* 增量同步：房源带单调 revision，客户端按 since 拉取，避免全量。
* 标准库 sqlite3，零额外依赖；数据库文件 600，备份=复制文件。
"""

from __future__ import annotations

import json
import secrets
import sqlite3
import threading
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

import media_store as ms
import backup_store as bs

# 字段键 -> 中文名（账本与推送展示）
FIELD_LABELS: dict[str, str] = {
    "roomNo": "房号",
    "tower": "座",
    "landlord": "房东",
    "layout": "户型",
    "price": "租金",
    "password": "密码",
    "remark": "备注",
    "status": "状态",
}

STATUS_LABELS = {"available": "待租", "rented": "已租"}
_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS houses (
  room_key TEXT PRIMARY KEY,
  room_no TEXT NOT NULL,
  tower INTEGER NOT NULL,
  landlord TEXT NOT NULL DEFAULT '',
  layout TEXT NOT NULL DEFAULT '',
  price INTEGER NOT NULL DEFAULT 0,
  password TEXT NOT NULL DEFAULT '',
  remark TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'available',
  revision INTEGER NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  updated_by TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS media_refs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  room_key TEXT NOT NULL,
  object_key TEXT NOT NULL,
  file_name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'image',
  sort_order INTEGER NOT NULL DEFAULT 0,
  UNIQUE(room_key, object_key)
);
CREATE TABLE IF NOT EXISTS ledger_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  room_key TEXT NOT NULL,
  ts TEXT NOT NULL,
  operator TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  migrated INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS field_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL,
  field TEXT NOT NULL,
  old_value TEXT NOT NULL DEFAULT '',
  new_value TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL,
  room_key TEXT NOT NULL,
  action TEXT NOT NULL,
  operator TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  data TEXT NOT NULL DEFAULT '{}',
  origin_device_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS app_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS profile (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  name TEXT NOT NULL DEFAULT '',
  phone TEXT NOT NULL DEFAULT '',
  qr_path TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS share_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  room_key TEXT NOT NULL DEFAULT '',
  ts TEXT NOT NULL,
  channel TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  operator TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_houses_rev ON houses(revision);
CREATE INDEX IF NOT EXISTS idx_media_room ON media_refs(room_key);
CREATE INDEX IF NOT EXISTS idx_ledger_room ON ledger_events(room_key);
CREATE INDEX IF NOT EXISTS idx_outbox_status ON outbox(status);
"""


class RevisionConflict(Exception):
    """乐观锁冲突：房源修订号已被他人推进。"""

    def __init__(self, room_key: str, expected: int, actual: int):
        super().__init__(f"revision conflict {room_key}: expect {expected} actual {actual}")
        self.room_key = room_key
        self.expected = expected
        self.actual = actual


class HouseNotFound(Exception):
    def __init__(self, room_key: str):
        super().__init__(f"house not found: {room_key}")
        self.room_key = room_key


def now_local() -> datetime:
    # 服务器为东八区，统一本地时间，便于人工排查
    return datetime.now(timezone(timedelta(hours=8)))


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%S+08:00")


def human_time(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M")


def _display(field: str, value: Any) -> str:
    if field == "status":
        return STATUS_LABELS.get(str(value), str(value))
    if field == "tower":
        return f"{value}座"
    return str(value)


class HouseStore:
    """SQLite 房源权威存储；线程安全（连接 check_same_thread=False + 全局锁）。"""

    def __init__(self, db_path: str | Path, media_root: str | Path | None = None,
                 backup_root: str | Path | None = None):
        self.path = Path(db_path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.media = ms.MediaStore(media_root or (self.path.parent / "media"))
        self.backups = bs.BackupStore(backup_root or (self.path.parent / "backups"))
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL;")
        self._conn.execute("PRAGMA foreign_keys=ON;")
        with self._lock:
            self._conn.executescript(_SCHEMA)
            self._conn.commit()
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # ------------------------------------------------------------------
    # 读取
    # ------------------------------------------------------------------
    def _row_to_dict(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "roomKey": row["room_key"],
            "roomNo": row["room_no"],
            "tower": row["tower"],
            "landlord": row["landlord"],
            "layout": row["layout"],
            "price": row["price"],
            "password": row["password"],
            "remark": row["remark"],
            "status": row["status"],
            "revision": row["revision"],
            "isDeleted": bool(row["is_deleted"]),
            "deletedAt": row["deleted_at"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "updatedBy": row["updated_by"],
        }

    def _media(self, conn: sqlite3.Connection, room_key: str) -> list[dict[str, Any]]:
        rows = conn.execute(
            "SELECT object_key, file_name, kind, sort_order FROM media_refs "
            "WHERE room_key=? ORDER BY sort_order, id", (room_key,)).fetchall()
        return [{"objectKey": r["object_key"], "fileName": r["file_name"],
                 "kind": r["kind"], "sortOrder": r["sort_order"]} for r in rows]

    def get_house(self, room_key: str, with_media: bool = True) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM houses WHERE room_key=?", (room_key,)).fetchone()
            if row is None:
                return None
            doc = self._row_to_dict(row)
            if with_media:
                doc["media"] = self._media(self._conn, room_key)
            return doc

    def list_houses(self, since: int | None = None,
                    include_deleted: bool = False) -> dict[str, Any]:
        with self._lock:
            sql = "SELECT * FROM houses"
            cond = []
            params: list[Any] = []
            if since is not None:
                cond.append("revision > ?")
                params.append(since)
            if not include_deleted:
                cond.append("is_deleted = 0")
            if cond:
                sql += " WHERE " + " AND ".join(cond)
            sql += " ORDER BY tower, room_no"
            rows = self._conn.execute(sql, params).fetchall()
            houses = []
            for row in rows:
                d = self._row_to_dict(row)
                d["media"] = self._media(self._conn, row["room_key"])
                houses.append(d)
            top = self._conn.execute(
                "SELECT COALESCE(MAX(revision),0) AS m FROM houses").fetchone()["m"]
            return {"serverTime": iso(now_local()), "topRevision": int(top),
                    "count": len(houses), "houses": houses}

    def ledger(self, room_key: str) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM ledger_events WHERE room_key=? ORDER BY seq DESC",
                (room_key,)).fetchall()
            out = []
            for r in rows:
                changes = self._conn.execute(
                    "SELECT field, old_value, new_value FROM field_changes "
                    "WHERE event_id=?", (r["id"],)).fetchall()
                out.append({
                    "id": r["id"], "ts": r["ts"], "operator": r["operator"],
                    "action": r["action"], "detail": r["detail"],
                    "migrated": bool(r["migrated"]),
                    "fieldChanges": [{"field": c["field"],
                                      "oldValue": c["old_value"],
                                      "newValue": c["new_value"]} for c in changes],
                })
            return out

    def append_ledger_event(self, room_key: str, event: dict[str, Any],
                            operator: str = "") -> dict[str, Any]:
        """追加一条真实账本事件（append-only，按事件 id 幂等去重）。
        账本事件只作操作留痕，不进 outbox、不触发实时广播。"""
        room_key = str(room_key or "").strip()
        if not room_key:
            raise ValueError("roomKey required")
        event_id = str(event.get("id") or "").strip() or secrets.token_hex(8)
        with self._lock:
            conn = self._conn
            already = conn.execute(
                "SELECT 1 FROM ledger_events WHERE id=?", (event_id,)).fetchone()
            if already:
                return {"id": event_id, "deduplicated": True}
            ts = str(event.get("ts") or iso(now_local()))
            op = str(event.get("operator") or operator or "未知用户")
            action = str(event.get("action") or "")
            detail = str(event.get("detail") or "")
            migrated = 1 if event.get("migrated") in (True, 1, "1", "true", "True") else 0
            conn.execute(
                "INSERT OR IGNORE INTO ledger_events "
                "(id,room_key,ts,operator,action,detail,migrated) "
                "VALUES (?,?,?,?,?,?,?)",
                (event_id, room_key, ts, op, action, detail, migrated))
            for ch in event.get("fieldChanges") or []:
                conn.execute(
                    "INSERT OR IGNORE INTO field_changes "
                    "(event_id,field,old_value,new_value) VALUES (?,?,?,?)",
                    (event_id, str(ch.get("field") or ""),
                     str(ch.get("oldValue") or ""), str(ch.get("newValue") or "")))
            conn.commit()
            return {"id": event_id, "deduplicated": False}

    # ------------------------------------------------------------------
    # 写入：新增 / 编辑（核心）
    # ------------------------------------------------------------------
    def upsert_house(self, payload: dict[str, Any], operator: str,
                     origin_device_id: str = "",
                     expected_revision: int | None = None) -> dict[str, Any]:
        """新增或更新一套房源。payload 字段用客户端命名（roomNo/tower/...）。"""
        room_key = str(payload.get("roomKey") or "").strip()
        if not room_key:
            raise ValueError("roomKey required")
        fields = {
            "roomNo": str(payload.get("roomNo") or room_key),
            "tower": int(payload.get("tower") or 1),
            "landlord": str(payload.get("landlord") or ""),
            "layout": str(payload.get("layout") or ""),
            "price": int(payload.get("price") or 0),
            "password": str(payload.get("password") or ""),
            "remark": str(payload.get("remark") or ""),
            "status": str(payload.get("status") or "available"),
        }
        media = payload.get("media") or []
        with self._lock:
            conn = self._conn
            existing = conn.execute(
                "SELECT * FROM houses WHERE room_key=?", (room_key,)).fetchone()
            now = now_local()
            if existing is None:
                return self._insert(conn, room_key, fields, media, operator,
                                    origin_device_id, now)
            return self._update(conn, existing, room_key, fields, media, operator,
                                origin_device_id, now, expected_revision)

    def import_house(self, payload: dict[str, Any],
                     ledger_events: list[dict[str, Any]] | None = None,
                     operator: str = "迁移") -> dict[str, Any]:
        """存量迁移专用落库（一次性从旧 COS 搬入）。

        - 只落结构化数据 + 媒体引用，媒体实体仍在 COS；
        - 保留原始 updatedAt/updatedBy（ISO 字符串，由迁移侧换算），不套用当前时间；
        - 写历史账本（migrated=1），但**不写 outbox、不触发广播**，避免存量 229 套
          各推一条「新增房源」轰炸在线设备；
        - 幂等：重复运行不产生重复账本事件、不推进修订号；已存在的房保留原 revision。
        """
        room_key = str(payload.get("roomKey") or "").strip()
        if not room_key:
            raise ValueError("roomKey required")
        fields = {
            "roomNo": str(payload.get("roomNo") or room_key),
            "tower": int(payload.get("tower") or 1),
            "landlord": str(payload.get("landlord") or ""),
            "layout": str(payload.get("layout") or ""),
            "price": int(payload.get("price") or 0),
            "password": str(payload.get("password") or ""),
            "remark": str(payload.get("remark") or ""),
            "status": str(payload.get("status") or "available"),
        }
        media = payload.get("media") or []
        created_at = str(payload.get("createdAt") or "") or iso(now_local())
        updated_at = str(payload.get("updatedAt") or "") or created_at
        updated_by = str(payload.get("updatedBy") or operator)
        with self._lock:
            conn = self._conn
            existing = conn.execute(
                "SELECT * FROM houses WHERE room_key=?", (room_key,)).fetchone()
            if existing is None:
                top = conn.execute(
                    "SELECT COALESCE(MAX(revision),0) AS m FROM houses"
                ).fetchone()["m"]
                new_rev = int(top) + 1
                conn.execute(
                    "INSERT INTO houses (room_key,room_no,tower,landlord,layout,price,"
                    "password,remark,status,revision,is_deleted,created_at,updated_at,"
                    "updated_by) VALUES (?,?,?,?,?,?,?,?,?,?,0,?,?,?)",
                    (room_key, fields["roomNo"], fields["tower"], fields["landlord"],
                     fields["layout"], fields["price"], fields["password"],
                     fields["remark"], fields["status"], new_rev,
                     created_at, updated_at, updated_by))
            else:
                conn.execute(
                    "UPDATE houses SET room_no=?,tower=?,landlord=?,layout=?,price=?,"
                    "password=?,remark=?,status=?,updated_at=?,updated_by=? "
                    "WHERE room_key=?",
                    (fields["roomNo"], fields["tower"], fields["landlord"],
                     fields["layout"], fields["price"], fields["password"],
                     fields["remark"], fields["status"], updated_at, updated_by,
                     room_key))
            self._replace_media(conn, room_key, media)
            for ev in ledger_events or []:
                event_id = str(ev.get("id") or "")
                if not event_id:
                    continue
                already = conn.execute(
                    "SELECT 1 FROM ledger_events WHERE id=?",
                    (event_id,)).fetchone()
                if already:
                    continue  # 幂等：历史事件已在，字段变更一并跳过
                conn.execute(
                    "INSERT OR IGNORE INTO ledger_events "
                    "(id,room_key,ts,operator,action,detail,migrated) "
                    "VALUES (?,?,?,?,?,?,1)",
                    (event_id, room_key, str(ev.get("ts") or updated_at),
                     str(ev.get("operator") or updated_by),
                     str(ev.get("action") or ""), str(ev.get("detail") or "")))
                for ch in ev.get("fieldChanges") or []:
                    conn.execute(
                        "INSERT OR IGNORE INTO field_changes "
                        "(event_id,field,old_value,new_value) VALUES (?,?,?,?)",
                        (event_id, str(ch.get("field") or ""),
                         str(ch.get("oldValue") or ""), str(ch.get("newValue") or "")))
            conn.commit()
            return self.get_house(room_key)  # type: ignore[return-value]

    def _insert(self, conn, room_key, fields, media, operator,
                origin_device_id, now) -> dict[str, Any]:
        event_id = "ev_" + secrets.token_hex(10)
        # revision 为全局单调递增版本号（增量同步基准），新增取当前最大 +1
        top = conn.execute("SELECT COALESCE(MAX(revision),0) AS m FROM houses").fetchone()["m"]
        new_rev = int(top) + 1
        conn.execute(
            "INSERT INTO houses (room_key,room_no,tower,landlord,layout,price,password,"
            "remark,status,revision,is_deleted,created_at,updated_at,updated_by) "
            "VALUES (?,?,?,?,?,?,?,?,?,? ,0,?,?,?)",
            (room_key, fields["roomNo"], fields["tower"], fields["landlord"],
             fields["layout"], fields["price"], fields["password"], fields["remark"],
             fields["status"], new_rev, iso(now), iso(now), operator))
        self._replace_media(conn, room_key, media)
        conn.execute(
            "INSERT INTO ledger_events (id,room_key,ts,operator,action,detail,migrated) "
            "VALUES (?,?,?,?,?,?,0)",
            (event_id, room_key, iso(now), operator, "新增房源", ""))
        title, body = self._compose_new(room_key, fields, operator, now)
        self._write_outbox(conn, event_id, room_key, "新增房源", operator,
                           title, body, {"fields": fields}, origin_device_id, now)
        conn.commit()
        return self.get_house(room_key)  # type: ignore[return-value]

    def _update(self, conn, existing, room_key, fields, media, operator,
                origin_device_id, now, expected_revision) -> dict[str, Any]:
        old_rev = int(existing["revision"])
        if expected_revision is not None and expected_revision != old_rev:
            raise RevisionConflict(room_key, expected_revision, old_rev)
        # 计算字段 diff
        old_values = {k: existing[self._column(k)] for k in fields}
        changes = []
        for key, new_val in fields.items():
            old_val = old_values[key]
            if old_val != new_val:
                changes.append((key, old_val, new_val))
        media_changed = self._media_changed(conn, room_key, media)
        if not changes and not media_changed:
            # 无实质变化：不产生事件、不推进修订号
            return self.get_house(room_key)  # type: ignore[return-value]
        event_id = "ev_" + secrets.token_hex(10)
        new_rev = old_rev + 1
        conn.execute(
            "UPDATE houses SET room_no=?,tower=?,landlord=?,layout=?,price=?,"
            "password=?,remark=?,status=?,revision=?,updated_at=?,updated_by=? "
            "WHERE room_key=?",
            (fields["roomNo"], fields["tower"], fields["landlord"], fields["layout"],
             fields["price"], fields["password"], fields["remark"], fields["status"],
             new_rev, iso(now), operator, room_key))
        self._replace_media(conn, room_key, media)
        action = "编辑保存"
        conn.execute(
            "INSERT INTO ledger_events (id,room_key,ts,operator,action,detail,migrated) "
            "VALUES (?,?,?,?,?,?,0)",
            (event_id, room_key, iso(now), operator, action, ""))
        for key, old_val, new_val in changes:
            conn.execute(
                "INSERT INTO field_changes (event_id,field,old_value,new_value) "
                "VALUES (?,?,?,?)",
                (event_id, key, _display(key, old_val), _display(key, new_val)))
        title, body = self._compose_update(room_key, changes, media_changed,
                                          operator, now)
        data = {"fieldChanges": [{"field": k, "oldValue": _display(k, o),
                                   "newValue": _display(k, n)} for k, o, n in changes],
                "mediaChanged": media_changed}
        self._write_outbox(conn, event_id, room_key, action, operator, title, body,
                           data, origin_device_id, now)
        conn.commit()
        return self.get_house(room_key)  # type: ignore[return-value]

    @staticmethod
    def _column(field_key: str) -> str:
        return {"roomNo": "room_no", "tower": "tower", "landlord": "landlord",
                "layout": "layout", "price": "price", "password": "password",
                "remark": "remark", "status": "status"}[field_key]

    # ------------------------------------------------------------------
    # 软删除 / 恢复
    # ------------------------------------------------------------------
    def set_deleted(self, room_key: str, deleted: bool, operator: str,
                    origin_device_id: str = "") -> dict[str, Any]:
        with self._lock:
            conn = self._conn
            existing = conn.execute(
                "SELECT * FROM houses WHERE room_key=?", (room_key,)).fetchone()
            if existing is None:
                raise HouseNotFound(room_key)
            already = bool(existing["is_deleted"])
            if already == deleted:
                return self.get_house(room_key)  # type: ignore[return-value]
            now = now_local()
            event_id = "ev_" + secrets.token_hex(10)
            new_rev = int(existing["revision"]) + 1
            action = "删除房源" if deleted else "恢复房源"
            deleted_at = iso(now) if deleted else None
            conn.execute(
                "UPDATE houses SET is_deleted=?, deleted_at=?, revision=?, "
                "updated_at=?, updated_by=? WHERE room_key=?",
                (1 if deleted else 0, deleted_at, new_rev, iso(now), operator, room_key))
            conn.execute(
                "INSERT INTO ledger_events (id,room_key,ts,operator,action,detail,migrated)"
                " VALUES (?,?,?,?,?,?,0)",
                (event_id, room_key, iso(now), operator, action, ""))
            title = f"房源{('删除' if deleted else '恢复')} · {room_key}"
            body = f"{operator} {action}（{human_time(now)}）"
            self._write_outbox(conn, event_id, room_key, action, operator, title, body,
                               {"deleted": deleted}, origin_device_id, now)
            conn.commit()
            return self.get_house(room_key)  # type: ignore[return-value]

    # ------------------------------------------------------------------
    # 物理删除（硬删，不进回收站）
    # ------------------------------------------------------------------
    def hard_delete(self, room_key: str, operator: str,
                    origin_device_id: str = "") -> dict[str, Any]:
        """彻底删除房源：级联清掉账本事件、字段变更、媒体引用与房源行；
        outbox 仍写一条删除事件，供其他接入设备同步本地删除。媒体实体仍留在 COS，不在此处清理。"""
        with self._lock:
            conn = self._conn
            existing = conn.execute(
                "SELECT * FROM houses WHERE room_key=?", (room_key,)).fetchone()
            if existing is None:
                raise HouseNotFound(room_key)
            now = now_local()
            event_id = "ev_" + secrets.token_hex(10)
            action = "删除房源"
            title = f"房源删除 · {room_key}"
            body = f"{operator} 彻底删除房源（{human_time(now)}）"
            # 级联清理：字段变更 → 账本事件 → 媒体引用 → 房源行
            led = conn.execute(
                "SELECT id FROM ledger_events WHERE room_key=?", (room_key,)).fetchall()
            for r in led:
                conn.execute("DELETE FROM field_changes WHERE event_id=?", (r["id"],))
            conn.execute("DELETE FROM ledger_events WHERE room_key=?", (room_key,))
            conn.execute("DELETE FROM media_refs WHERE room_key=?", (room_key,))
            conn.execute("DELETE FROM houses WHERE room_key=?", (room_key,))
            # 级联清理服务器磁盘上该房源的媒体实体
            try:
                self.media.delete_house_dir(room_key)
            except Exception:
                pass
            self._write_outbox(conn, event_id, room_key, action, operator, title, body,
                               {"deleted": True, "hardDelete": True}, origin_device_id, now)
            conn.commit()
            return {"ok": True, "roomKey": room_key, "hardDelete": True}

    # ------------------------------------------------------------------
    # 媒体
    # ------------------------------------------------------------------
    def _replace_media(self, conn, room_key: str, media: list[dict[str, Any]]) -> None:
        conn.execute("DELETE FROM media_refs WHERE room_key=?", (room_key,))
        seen: set[str] = set()
        idx = 0
        for m in media:
            object_key = str(m.get("objectKey") or "")
            if not object_key or object_key in seen:
                continue  # 防御性去重，避免同实体重复引用撞唯一约束
            seen.add(object_key)
            conn.execute(
                "INSERT INTO media_refs (room_key,object_key,file_name,kind,sort_order) "
                "VALUES (?,?,?,?,?)",
                (room_key, object_key, str(m.get("fileName") or ""),
                 str(m.get("kind") or "image"), int(m.get("sortOrder") or idx)))
            idx += 1

    def _media_changed(self, conn, room_key: str, media: list[dict[str, Any]]) -> dict | None:
        cur = self._media(conn, room_key)
        cur_keys = [(m["objectKey"], m["kind"]) for m in cur]
        new_keys = [(str(m.get("objectKey") or ""), str(m.get("kind") or "image"))
                    for m in media]
        if cur_keys == new_keys:
            return None
        added = [k for k in new_keys if k not in cur_keys]
        removed = [k for k in cur_keys if k not in new_keys]
        return {"added": len(added), "removed": len(removed)}

    # ------------------------------------------------------------------
    # 文案组装
    # ------------------------------------------------------------------
    def _compose_new(self, room_key, fields, operator, now) -> tuple[str, str]:
        title = f"房源新增 · {room_key}"
        bits = [f"租金 {fields['price']}", f"房东 {fields['landlord'] or '—'}",
                f"状态 {STATUS_LABELS.get(fields['status'], fields['status'])}"]
        body = f"{operator} 新增房源（{human_time(now)}）：" + "，".join(bits)
        return title, body

    def _compose_update(self, room_key, changes, media_changed, operator, now
                        ) -> tuple[str, str]:
        title = f"房源变更 · {room_key}"
        parts = []
        for key, old_val, new_val in changes:
            label = FIELD_LABELS.get(key, key)
            parts.append(f"{label} {_display(key, old_val)}→{_display(key, new_val)}")
        if media_changed:
            if media_changed["added"]:
                parts.append(f"新增媒体 {media_changed['added']} 项")
            if media_changed["removed"]:
                parts.append(f"删除媒体 {media_changed['removed']} 项")
        body = f"{operator} {('，'.join(parts) or '更新了房源')}（{human_time(now)}）"
        return title, body

    def _write_outbox(self, conn, event_id, room_key, action, operator, title, body,
                      data, origin_device_id, now) -> None:
        conn.execute(
            "INSERT INTO outbox (event_id,room_key,action,operator,title,body,data,"
            "origin_device_id,status,created_at) VALUES (?,?,?,?,?,?,?,?, 'pending',?)",
            (event_id, room_key, action, operator, title, body,
             json.dumps(data, ensure_ascii=False), origin_device_id, iso(now)))

    # ------------------------------------------------------------------
    # outbox 投递对接
    # ------------------------------------------------------------------
    def pending_outbox(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM outbox WHERE status='pending' ORDER BY id LIMIT ?",
                (limit,)).fetchall()
            return [{"id": r["id"], "eventId": r["event_id"], "roomKey": r["room_key"],
                     "action": r["action"], "operator": r["operator"],
                     "title": r["title"], "body": r["body"],
                     "data": json.loads(r["data"] or "{}"),
                     "originDeviceId": r["origin_device_id"] or ""} for r in rows]

    def mark_outbox(self, outbox_id: int, status: str = "sent") -> None:
        with self._lock:
            self._conn.execute("UPDATE outbox SET status=? WHERE id=?",
                               (status, outbox_id))
            self._conn.commit()

    def stats(self) -> dict[str, Any]:
        with self._lock:
            total = self._conn.execute(
                "SELECT COUNT(*) c FROM houses WHERE is_deleted=0").fetchone()["c"]
            t1 = self._conn.execute(
                "SELECT COUNT(*) c FROM houses WHERE is_deleted=0 AND tower=1"
            ).fetchone()["c"]
            t2 = self._conn.execute(
                "SELECT COUNT(*) c FROM houses WHERE is_deleted=0 AND tower=2"
            ).fetchone()["c"]
            pending = self._conn.execute(
                "SELECT COUNT(*) c FROM outbox WHERE status='pending'").fetchone()["c"]
            return {"total": total, "tower1": t1, "tower2": t2,
                    "pendingOutbox": pending}

    # ------------------------------------------------------------------
    # 远程配置（app_config：可变配置 / 在线更新块，服务器为权威）
    # ------------------------------------------------------------------
    def config_get(self, key: str) -> dict[str, Any]:
        with self._lock:
            row = self._conn.execute(
                "SELECT value FROM app_config WHERE key=?", (key,)).fetchone()
        if row is None:
            return {}
        try:
            return json.loads(row["value"] or "{}")
        except json.JSONDecodeError:
            return {}

    def config_set(self, key: str, value: dict[str, Any]) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO app_config (key,value,updated_at) VALUES (?,?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, "
                "updated_at=excluded.updated_at",
                (key, json.dumps(value, ensure_ascii=False), iso(now_local())))
            self._conn.commit()

    # ------------------------------------------------------------------
    # 名片（姓名 / 电话 / 二维码引用；二维码图片实体在 media.profile）
    # ------------------------------------------------------------------
    def profile_get(self) -> dict[str, Any]:
        with self._lock:
            row = self._conn.execute(
                "SELECT name,phone,qr_path,updated_at FROM profile WHERE id=1"
            ).fetchone()
        if row is None:
            return {"name": "", "phone": "", "qrPath": "", "updatedAt": ""}
        return {"name": row["name"], "phone": row["phone"],
                "qrPath": row["qr_path"], "updatedAt": row["updated_at"]}

    def profile_set(self, name: str, phone: str, qr_path: str = "") -> dict[str, Any]:
        with self._lock:
            self._conn.execute(
                "INSERT INTO profile (id,name,phone,qr_path,updated_at) "
                "VALUES (1,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
                "name=excluded.name, phone=excluded.phone, qr_path=excluded.qr_path, "
                "updated_at=excluded.updated_at",
                (name, phone, qr_path, iso(now_local())))
            self._conn.commit()
        return self.profile_get()

    # ------------------------------------------------------------------
    # 分享记录（取代旧桶 users/<u>/share_records.json）
    # ------------------------------------------------------------------
    def share_records_add(self, room_key: str, channel: str, summary: str,
                          operator: str) -> dict[str, Any]:
        with self._lock:
            cur = self._conn.execute(
                "INSERT INTO share_records (room_key,ts,channel,summary,operator) "
                "VALUES (?,?,?,?,?)",
                (room_key, iso(now_local()), channel, summary, operator))
            self._conn.commit()
            rec = {"id": cur.lastrowid, "roomKey": room_key,
                   "ts": iso(now_local()), "channel": channel,
                   "summary": summary, "operator": operator}
        return rec

    def share_records_list(self, limit: int = 200) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT id,room_key,ts,channel,summary,operator FROM share_records "
                "ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        return [{"id": r["id"], "roomKey": r["room_key"], "ts": r["ts"],
                 "channel": r["channel"], "summary": r["summary"],
                 "operator": r["operator"]} for r in rows]

    # ------------------------------------------------------------------
    # 公开选房（脱敏，免鉴权；H5 / 公开链接用）
    # ------------------------------------------------------------------
    def public_rooms(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT room_key,room_no,tower,layout,price,status FROM houses "
                "WHERE is_deleted=0 AND status='available' "
                "ORDER BY tower, room_no").fetchall()
            out = []
            for r in rows:
                media = self._media(self._conn, r["room_key"])
                out.append({
                    "roomKey": r["room_key"], "roomNo": r["room_no"],
                    "tower": r["tower"], "layout": r["layout"],
                    "price": r["price"], "status": r["status"],
                    "media": [{"objectKey": m["objectKey"], "fileName": m["fileName"],
                               "kind": m["kind"], "sortOrder": m["sortOrder"]}
                              for m in media],
                })
        return out

    def public_single(self, room_key: str) -> dict[str, Any] | None:
        """公开只读单房（脱敏，免鉴权；单房分享 H5 用）。仅待租、未删。"""
        with self._lock:
            row = self._conn.execute(
                "SELECT room_key,room_no,tower,layout,price,status FROM houses "
                "WHERE room_key=? AND is_deleted=0 AND status='available'",
                (room_key,)).fetchone()
            if row is None:
                return None
            media = self._media(self._conn, row["room_key"])
            return {
                "roomKey": row["room_key"], "roomNo": row["room_no"],
                "tower": row["tower"], "layout": row["layout"],
                "price": row["price"], "status": row["status"],
                "media": [{"objectKey": m["objectKey"], "fileName": m["fileName"],
                           "kind": m["kind"], "sortOrder": m["sortOrder"]}
                          for m in media],
            }
