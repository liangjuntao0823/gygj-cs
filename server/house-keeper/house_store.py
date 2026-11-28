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
import shutil
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
  operator TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT 'single',
  mode TEXT NOT NULL DEFAULT 'masked',
  room_keys TEXT NOT NULL DEFAULT '[]',
  token TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL DEFAULT '',
  phone TEXT NOT NULL DEFAULT '',
  expires_at INTEGER NOT NULL DEFAULT 0,
  revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS share_visits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  share_id INTEGER NOT NULL DEFAULT 0,
  room_key TEXT NOT NULL DEFAULT '',
  mode TEXT NOT NULL DEFAULT '',
  ref TEXT NOT NULL DEFAULT '',
  visitor TEXT NOT NULL DEFAULT '',
  ip_hash TEXT NOT NULL DEFAULT '',
  ua TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS share_assets (
  asset TEXT PRIMARY KEY,
  share_id INTEGER NOT NULL DEFAULT 0,
  rel TEXT NOT NULL DEFAULT '',
  ts TEXT NOT NULL,
  UNIQUE(share_id, rel)
);
CREATE TABLE IF NOT EXISTS ops (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '',
  action TEXT NOT NULL DEFAULT '',
  result TEXT NOT NULL DEFAULT '',
  detail TEXT NOT NULL DEFAULT '',
  room TEXT NOT NULL DEFAULT '',
  operator TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_houses_rev ON houses(revision);
CREATE INDEX IF NOT EXISTS idx_media_room ON media_refs(room_key);
CREATE INDEX IF NOT EXISTS idx_ledger_room ON ledger_events(room_key);
CREATE INDEX IF NOT EXISTS idx_outbox_status ON outbox(status);
CREATE INDEX IF NOT EXISTS idx_ops_id ON ops(id);
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


class DuplicateHouse(Exception):
    """新增房源时房号已存在（同一座同一房号唯一）。"""
    def __init__(self, room_key: str, existing: dict[str, Any]):
        super().__init__(f"duplicate room: {room_key}")
        self.room_key = room_key
        self.existing = existing


class FieldConflict(Exception):
    """字段级合并失败：同一字段客户端与服务器都基于同一 base 改成了不同值。"""

    def __init__(self, room_key: str, conflicts: list[dict[str, Any]]):
        super().__init__(f"field conflict {room_key}: "
                         + ",".join(c["field"] for c in conflicts))
        self.room_key = room_key
        self.conflicts = conflicts


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
        from share_auth import ShareSigner
        self.share_signer = ShareSigner(self.path.parent / "share_secret")
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL;")
        self._conn.execute("PRAGMA foreign_keys=ON;")
        with self._lock:
            self._conn.executescript(_SCHEMA)
            self._migrate_share_schema()
            self._conn.commit()
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def _migrate_share_schema(self) -> None:
        """老库平滑升级：share_records 补字段，不改已有记录。"""
        columns = {
            "kind": "TEXT NOT NULL DEFAULT 'single'",
            "mode": "TEXT NOT NULL DEFAULT 'masked'",
            "room_keys": "TEXT NOT NULL DEFAULT '[]'",
            "token": "TEXT NOT NULL DEFAULT ''",
            "url": "TEXT NOT NULL DEFAULT ''",
            "name": "TEXT NOT NULL DEFAULT ''",
            "phone": "TEXT NOT NULL DEFAULT ''",
            "expires_at": "INTEGER NOT NULL DEFAULT 0",
            "revoked": "INTEGER NOT NULL DEFAULT 0",
        }
        existing = {r["name"] for r in self._conn.execute(
            "PRAGMA table_info(share_records)").fetchall()}
        for name, ddl in columns.items():
            if name not in existing:
                self._conn.execute(f"ALTER TABLE share_records ADD COLUMN {name} {ddl}")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_share_token ON share_records(token)")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_share_visit_ts ON share_visits(ts)")
        # b30：脱敏分享的媒体资产别名表；老库启动时补建，不改历史记录。
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS share_assets ("
            "asset TEXT PRIMARY KEY, share_id INTEGER NOT NULL DEFAULT 0,"
            "rel TEXT NOT NULL DEFAULT '', ts TEXT NOT NULL, UNIQUE(share_id, rel))")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_share_asset_sid ON share_assets(share_id)")

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

    def _media_map(self, conn: sqlite3.Connection,
                   room_keys: list[str]) -> dict[str, list[dict[str, Any]]]:
        """一次批量查媒体引用，避免 list_houses / public_rooms 的 N+1。"""
        out: dict[str, list[dict[str, Any]]] = {k: [] for k in room_keys}
        if not room_keys:
            return out
        # SQLite 参数上限保守按 500 分批，200+ 套房源也不会退化回逐套查询。
        for i in range(0, len(room_keys), 500):
            chunk = room_keys[i:i + 500]
            placeholders = ",".join("?" for _ in chunk)
            rows = conn.execute(
                "SELECT room_key, object_key, file_name, kind, sort_order "
                f"FROM media_refs WHERE room_key IN ({placeholders}) "
                "ORDER BY sort_order, id", chunk).fetchall()
            for r in rows:
                out.setdefault(r["room_key"], []).append({
                    "objectKey": r["object_key"], "fileName": r["file_name"],
                    "kind": r["kind"], "sortOrder": r["sort_order"]})
        return out

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
            media_map = self._media_map(self._conn, [r["room_key"] for r in rows])
            houses = []
            for row in rows:
                d = self._row_to_dict(row)
                d["media"] = media_map.get(row["room_key"], [])
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
            if conn.execute("SELECT 1 FROM houses WHERE room_key=?",
                            (room_key,)).fetchone() is None:
                raise HouseNotFound(room_key)
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
                     expected_revision: int | None = None,
                     notify_scope: str = "all",
                     notify_user_token: str = "",
                     create_only: bool = False) -> dict[str, Any]:
        """新增或更新一套房源。payload 字段用客户端命名（roomNo/tower/...）。

        2026-11-27 字段级合并：
        * 客户端可带 `base`（编辑前服务器快照字段）与 `baseMedia`（编辑前媒体 objectKey）。
        * 服务器按三路比较：客户端改且服务器没改 → 接受；客户端没改 → 保留服务器；
          两边都改同一字段且值不同 → 抛 FieldConflict（返回明细，不覆盖）。
        * 媒体按「服务器现有 ∪ 本次新增 − 显式删除」合并，避免分享扩展/多设备
          只带自己的媒体清单时把别人的照片合并掉。
        * 不带 base 的旧客户端仍走 expectedRevision 全量 CAS，行为不变。
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
        self._validate_fields(room_key, fields)
        media = payload.get("media") or []
        base = payload.get("base") if isinstance(payload.get("base"), dict) else None
        # b31：字段级写入协议。客户端只提交本次真正改动的字段名，
        # 服务器只把这些字段覆盖到现有行；未提交字段一律保留服务器当前值。
        # 这解决了“编辑页持有旧快照，保存备注时把别人刚改的租金回滚”的问题。
        changed_fields = payload.get("changed")
        changed_set: set[str] | None = None
        if isinstance(changed_fields, list):
            allowed = {"roomNo", "tower", "landlord", "layout", "price",
                       "password", "remark", "status"}
            changed_set = {str(x) for x in changed_fields if str(x) in allowed}
        base_media = payload.get("baseMedia") if isinstance(payload.get("baseMedia"), list) else None
        removed_media = {
            str(x) for x in (payload.get("removedMedia") or []) if str(x or "")
        }
        with self._lock:
            conn = self._conn
            existing = conn.execute(
                "SELECT * FROM houses WHERE room_key=?", (room_key,)).fetchone()
            now = now_local()
            if existing is not None and create_only:
                doc = self._row_to_dict(existing)
                raise DuplicateHouse(room_key, doc)
            if existing is None:
                # 另一台设备已把这套房“双端删除”后，本机仍拿着旧修订号提交编辑：
                # 不能当新房价插回去（否则就是用户最怕的“删了又复活”）。
                # expectedRevision 只在编辑既有房源时携带；真新建不会带。
                if expected_revision is not None:
                    raise RevisionConflict(room_key, expected_revision, 0)
                return self._insert(conn, room_key, fields, media, operator,
                                    origin_device_id, now, notify_scope, notify_user_token)
            if base is not None:
                if changed_set is not None:
                    # b31 字段级：只覆盖本次改动字段，其余保留服务器当前值。
                    # 同字段两边都改时按“后写入者优先”，不再抛字段冲突。
                    fields = self._apply_changed_fields(existing, fields, changed_set)
                else:
                    # 兼容 b30 及更早客户端：没有 changed 清单，继续三路合并。
                    fields = self._merge_fields(room_key, existing, fields, base)
                merged_media = self._merge_media(
                    conn, room_key, media, base_media, removed_media)
                return self._update(conn, existing, room_key, fields, merged_media,
                                    operator, origin_device_id, now, None,
                                    notify_scope, notify_user_token)
            if removed_media:
                media = [m for m in media
                         if str(m.get("objectKey") or "") not in removed_media]
            return self._update(conn, existing, room_key, fields, media, operator,
                                origin_device_id, now, expected_revision,
                                notify_scope, notify_user_token)

    @staticmethod
    def _validate_fields(room_key: str, fields: dict[str, Any]) -> None:
        """入库前字段校验；越界/脏值直接拒绝，避免后台与 H5 展示脏数据。"""
        room_no = str(fields.get("roomNo") or "").strip()
        if not room_no:
            raise ValueError("roomNo required")
        if len(room_no) > 40:
            raise ValueError("roomNo too long")
        tower = int(fields.get("tower") or 0)
        if tower not in (1, 2):
            raise ValueError("tower must be 1 or 2")
        # 房号前缀与座号一致性：2- 开头必须是 2 座，1- 开头必须是 1 座；
        # 不带前缀的历史 key 保留原样，不强行改写。
        if room_key.startswith("2-") and tower != 2:
            raise ValueError("roomKey prefix 2- but tower != 2")
        if room_key.startswith("1-") and tower != 1:
            raise ValueError("roomKey prefix 1- but tower != 1")
        price = int(fields.get("price") or 0)
        if price < 0 or price > 200000:
            raise ValueError("price out of range")
        status = str(fields.get("status") or "")
        if status not in ("available", "rented"):
            raise ValueError("status must be available or rented")
        for key in ("landlord", "layout", "password", "remark"):
            if len(str(fields.get(key) or "")) > 500:
                raise ValueError(f"{key} too long")

    @staticmethod
    def _apply_changed_fields(existing: sqlite3.Row,
                              client: dict[str, Any],
                              changed: set[str]) -> dict[str, Any]:
        """b31 字段级写入：只覆盖 changed 中的字段，其余保留服务器当前值。

        同一字段被两台设备先后修改时，后到的一次覆盖先前值（last write wins）。
        """
        merged: dict[str, Any] = {}
        for key in ("roomNo", "tower", "landlord", "layout", "price",
                    "password", "remark", "status"):
            merged[key] = client[key] if key in changed else existing[HouseStore._column(key)]
        return merged

    @staticmethod
    def _merge_fields(room_key: str, existing: sqlite3.Row,
                      client: dict[str, Any], base: dict[str, Any]) -> dict[str, Any]:
        """三路字段级合并；同字段两边都改且不同时抛 FieldConflict。"""
        merged: dict[str, Any] = {}
        conflicts: list[dict[str, Any]] = []
        for key, client_val in client.items():
            server_val = existing[HouseStore._column(key)]
            base_val = base.get(key, server_val)
            # 客户端没改（新值等于 base）→ 保留服务器当前值，避免旧快照回滚
            if client_val == base_val:
                merged[key] = server_val
            # 服务器没改（当前等于 base）→ 接受客户端新值
            elif server_val == base_val or client_val == server_val:
                merged[key] = client_val
            else:
                conflicts.append({
                    "field": key, "label": FIELD_LABELS.get(key, key),
                    "base": _display(key, base_val),
                    "client": _display(key, client_val),
                    "server": _display(key, server_val),
                })
                merged[key] = server_val
        if conflicts:
            raise FieldConflict(room_key, conflicts)
        return merged

    def _merge_media(self, conn, room_key: str, client_media: list[dict[str, Any]],
                     base_media: list[str] | None,
                     explicit_removed: set[str]) -> list[dict[str, Any]]:
        """媒体并集合并：服务器现有 ∪ 本次清单 − 显式删除。

        baseMedia 缺失时按「客户端清单就是全部」处理（旧行为，不误删服务器媒体）；
        有 baseMedia 时，base 有、本次没有 = 客户端删除，即使没显式 removedMedia 也删。
        """
        current = self._media(conn, room_key)
        desired = [m for m in client_media if isinstance(m, dict)]
        base_keys = {str(x) for x in (base_media or []) if str(x or "")}
        desired_keys = {str(m.get("objectKey") or "") for m in desired if m.get("objectKey")}
        removed = set(explicit_removed)
        if base_media is not None:
            removed |= (base_keys - desired_keys)
        merged: list[dict[str, Any]] = []
        seen: set[str] = set()
        # 保留服务器顺序；客户端新增追加在后，避免两端顺序抖动导致 revision 空转
        for m in current:
            key = str(m.get("objectKey") or "")
            if key and key not in removed and key not in seen:
                merged.append({"objectKey": key, "fileName": m.get("fileName") or "",
                               "kind": m.get("kind") or "image",
                               "sortOrder": len(merged)})
                seen.add(key)
        for m in desired:
            key = str(m.get("objectKey") or "")
            if not key or key in removed or key in seen:
                continue
            merged.append({"objectKey": key, "fileName": str(m.get("fileName") or ""),
                           "kind": str(m.get("kind") or "image"),
                           "sortOrder": len(merged)})
            seen.add(key)
        return merged

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
                origin_device_id, now, notify_scope="all",
                notify_user_token="") -> dict[str, Any]:
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
                           title, body, {"fields": fields,
                                         "notifyScope": notify_scope,
                                         "notifyUserToken": notify_user_token},
                           origin_device_id, now)
        conn.commit()
        return self.get_house(room_key)  # type: ignore[return-value]

    def _update(self, conn, existing, room_key, fields, media, operator,
                origin_device_id, now, expected_revision, notify_scope="all",
                notify_user_token="") -> dict[str, Any]:
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
                "mediaChanged": media_changed,
                "notifyScope": notify_scope,
                "notifyUserToken": notify_user_token}
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
                    origin_device_id: str = "", notify_scope: str = "all",
                    notify_user_token: str = "") -> dict[str, Any]:
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
                               {"deleted": deleted,
                                "notifyScope": notify_scope,
                                "notifyUserToken": notify_user_token},
                               origin_device_id, now)
            conn.commit()
            return self.get_house(room_key)  # type: ignore[return-value]

    # ------------------------------------------------------------------
    # 物理删除（硬删，不进回收站）
    # ------------------------------------------------------------------
    def hard_delete(self, room_key: str, operator: str,
                    origin_device_id: str = "", notify_scope: str = "all",
                    notify_user_token: str = "") -> dict[str, Any]:
        """彻底删除房源：级联清掉账本事件、字段变更、媒体引用与房源行；
        outbox 仍写一条删除事件，供其他接入设备同步本地删除。"""
        with self._lock:
            conn = self._conn
            existing = conn.execute(
                "SELECT * FROM houses WHERE room_key=?", (room_key,)).fetchone()
            if existing is None:
                # 删除幂等：另一台设备已经删掉时，本次删除按成功处理，
                # 客户端照常清本地，不会因 500 留在“删不掉”的状态。
                return {"ok": True, "roomKey": room_key, "hardDelete": True,
                        "alreadyDeleted": True}
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
                               {"deleted": True, "hardDelete": True,
                                "notifyScope": notify_scope,
                                "notifyUserToken": notify_user_token},
                               origin_device_id, now)
            conn.commit()
            return {"ok": True, "roomKey": room_key, "hardDelete": True}

    # ------------------------------------------------------------------
    # 媒体
    # ------------------------------------------------------------------
    def _replace_media(self, conn, room_key: str, media: list[dict[str, Any]]) -> None:
        # 落库前校验新目录引用：houses/<roomKey>/<file> 必须真实存在。
        # 历史迁移数据里的 h/ 前缀（旧 COS 对象键）不在此列，保留兼容。
        prefix = f"houses/{ms.safe_room_key(room_key)}/"
        for m in media:
            key = str(m.get("objectKey") or "")
            if key.startswith("houses/"):
                if not key.startswith(prefix) or not self.media.read_house_media(
                        room_key, key[len(prefix):]):
                    raise ValueError(f"media file not found: {key}")
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
    # 孤儿媒体扫描 / 清理（设置页「清理服务器孤儿媒体」）
    # ------------------------------------------------------------------
    def list_orphan_media(self, min_age_seconds: int = 3600) -> dict[str, Any]:
        """列出 media_refs 未引用的 houses/ 文件。

        - 只扫 houses/，不碰 profile/ share/ releases；
        - 默认跳过 1 小时内新文件，避免刚上传、事务还没提交的媒体被误删；
        - `.part` 临时文件不计入（上传中断残留由后续上传覆盖或单独清理）。
        """
        min_age = max(0, int(min_age_seconds))
        with self._lock:
            refs = {r["object_key"] for r in self._conn.execute(
                "SELECT object_key FROM media_refs").fetchall()}
            now = time.time()
            files = []
            total = 0
            for rel, size, mtime in self.media.iter_house_files():
                if rel in refs:
                    continue
                if min_age and (now - mtime) < min_age:
                    continue
                files.append({"objectKey": rel, "size": int(size),
                              "modifiedAt": datetime.fromtimestamp(
                                  mtime, timezone(timedelta(hours=8))
                              ).strftime("%Y-%m-%dT%H:%M:%S+08:00")})
                total += int(size)
            files.sort(key=lambda x: x["modifiedAt"])
        return {"files": files, "count": len(files), "totalBytes": total,
                "minAgeSeconds": min_age}

    def delete_orphan_media(self, object_keys: list[str],
                            min_age_seconds: int = 3600) -> dict[str, Any]:
        """删除指定孤儿文件；删除前二次核对 media_refs，已引用的文件一律跳过。"""
        min_age = max(0, int(min_age_seconds))
        keys = [str(k).strip() for k in (object_keys or []) if str(k).strip()]
        deleted, skipped = [], []
        with self._lock:
            refs = {r["object_key"] for r in self._conn.execute(
                "SELECT object_key FROM media_refs").fetchall()}
            now = time.time()
            for key in keys:
                if key in refs or not key.startswith("houses/"):
                    skipped.append({"objectKey": key, "reason": "referenced_or_invalid"})
                    continue
                path = self.media._resolve(key)
                if path is None or not path.is_file():
                    skipped.append({"objectKey": key, "reason": "not_found"})
                    continue
                if min_age and (now - path.stat().st_mtime) < min_age:
                    skipped.append({"objectKey": key, "reason": "too_new"})
                    continue
                if self.media.delete_rel(key):
                    deleted.append(key)
                else:
                    skipped.append({"objectKey": key, "reason": "delete_failed"})
        return {"ok": True, "deleted": deleted, "skipped": skipped}

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
    def storage_stats(self) -> dict[str, Any]:
        """磁盘与房源媒体占用；设置页直接读这个口径。
        磁盘总量取根分区，媒体体积只统计 media/houses（不含备份/二维码）。
        """
        try:
            usage = shutil.disk_usage("/")
            total, used, free = usage.total, usage.used, usage.free
            percent = round(used / total * 100, 1) if total else 0.0
        except OSError:
            total = used = free = 0
            percent = 0.0
        media_bytes = 0
        media_files = 0
        houses_root = self.media.root / "houses"
        try:
            for item in houses_root.rglob("*"):
                if item.is_file():
                    media_files += 1
                    try:
                        media_bytes += item.stat().st_size
                    except OSError:
                        pass
        except OSError:
            pass
        with self._lock:
            house_count = self._conn.execute(
                "SELECT COUNT(*) c FROM houses WHERE is_deleted=0").fetchone()["c"]
        return {
            "diskTotal": total,
            "diskUsed": used,
            "diskFree": free,
            "diskPercent": percent,
            "mediaBytes": media_bytes,
            "mediaFiles": media_files,
            "mediaRoot": str(self.media.root),
            "houseCount": house_count,
        }

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
    # ------------------------------------------------------------------
    # 操作日志（云端日志区；服务器权威记录，App/后台共用）
    # ------------------------------------------------------------------
    def append_op(self, category: str, action: str, result: str,
                  detail: str = "", room: str = "", operator: str = "") -> dict[str, Any]:
        """写一条操作日志；只追加，不进入房源账本/outbox。"""
        now = now_local()
        with self._lock:
            cur = self._conn.execute(
                "INSERT INTO ops (ts,category,action,result,detail,room,operator) "
                "VALUES (?,?,?,?,?,?,?)",
                (human_time(now), str(category)[:80], str(action)[:120],
                 str(result)[:40], str(detail)[:2000], str(room)[:120],
                 str(operator)[:80]))
            self._conn.commit()
            return {"ok": True, "id": cur.lastrowid}

    def list_ops(self, limit: int = 200) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 200), 500))
        with self._lock:
            rows = self._conn.execute(
                "SELECT id,ts,category,action,result,detail,room,operator "
                "FROM ops ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        return [{
            "id": str(r["id"]),
            "t": r["ts"],
            "op": f"{r['category']}·{r['action']}·{r['result']}",
            "room": r["room"],
            "user": r["operator"],
            "detail": r["detail"],
        } for r in rows]

    def delete_op(self, op_id: str = "", t: str = "", op: str = "",
                  room: str = "", user: str = "", detail: str = "") -> bool:
        with self._lock:
            conn = self._conn
            if str(op_id or "").strip().isdigit():
                conn.execute("DELETE FROM ops WHERE id=?", (int(op_id),))
            else:
                # 兼容旧云端复合键删除：字段全等才删，避免误删同分钟其他记录
                conn.execute(
                    "DELETE FROM ops WHERE ts=? AND (?='' OR category||'·'||action||'·'||result=?) "
                    "AND room=? AND operator=? AND detail=?",
                    (t, op, op, room, user, detail))
            conn.commit()
            return True

    def share_records_add(self, room_key: str, channel: str, summary: str,
                          operator: str, *, kind: str = "single",
                          mode: str = "masked", room_keys: list[str] | None = None,
                          token: str = "", url: str = "", name: str = "",
                          phone: str = "", expires_at: int = 0,
                          revoke_list: bool = False) -> dict[str, Any]:
        if revoke_list and kind == "list":
            with self._lock:
                self._conn.execute(
                    "UPDATE share_records SET revoked=1 WHERE kind='list' AND revoked=0")
                self._conn.commit()
        rk_json = json.dumps(room_keys or [], ensure_ascii=False)
        with self._lock:
            cur = self._conn.execute(
                "INSERT INTO share_records "
                "(room_key,ts,channel,summary,operator,kind,mode,room_keys,token,url,name,phone,expires_at,revoked) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)",
                (room_key, iso(now_local()), channel, summary, operator,
                 kind, mode, rk_json, token, url, name, phone, int(expires_at)))
            self._conn.commit()
            rec = {"id": cur.lastrowid, "roomKey": room_key,
                   "ts": iso(now_local()), "channel": channel,
                   "summary": summary, "operator": operator,
                   "kind": kind, "mode": mode, "roomKeys": room_keys or [],
                   "token": token, "url": url, "name": name, "phone": phone,
                   "expiresAt": int(expires_at), "revoked": False}
        return rec

    def share_record_finalize(self, share_id: int, token: str, url: str,
                              expires_at: int) -> dict[str, Any] | None:
        with self._lock:
            self._conn.execute(
                "UPDATE share_records SET token=?,url=?,expires_at=? WHERE id=?",
                (token, url, int(expires_at), int(share_id)))
            self._conn.commit()
        return self.share_record_get(share_id)

    def share_record_get(self, share_id: int) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM share_records WHERE id=?", (int(share_id),)).fetchone()
        return self._share_row(row) if row else None

    def share_record_by_token(self, token: str) -> dict[str, Any] | None:
        if not token:
            return None
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM share_records WHERE token=?", (token,)).fetchone()
        return self._share_row(row) if row else None

    def share_records_list(self, limit: int = 200) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 200), 500))
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM share_records ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        return [self._share_row(r) for r in rows]

    def share_records_revoke_all(self, kind: str = "list") -> int:
        with self._lock:
            cur = self._conn.execute(
                "UPDATE share_records SET revoked=1 WHERE kind=? AND revoked=0", (kind,))
            self._conn.commit()
            return int(cur.rowcount or 0)

    def register_share_asset(self, share_id: int, rel: str) -> str:
        """给脱敏页的媒体文件分配不透明资产别名，URL 不出现房号/文件名。"""
        sid, rel = int(share_id or 0), str(rel or "")
        if not sid or not rel:
            return ""
        with self._lock:
            row = self._conn.execute(
                "SELECT asset FROM share_assets WHERE share_id=? AND rel=?",
                (sid, rel)).fetchone()
            if row:
                return str(row["asset"])
            asset = secrets.token_urlsafe(16)
            self._conn.execute(
                "INSERT INTO share_assets (asset,share_id,rel,ts) VALUES (?,?,?,?)",
                (asset, sid, rel, iso(now_local())))
            self._conn.commit()
            return asset

    def resolve_share_asset(self, share_id: int, asset: str) -> str:
        with self._lock:
            row = self._conn.execute(
                "SELECT rel FROM share_assets WHERE share_id=? AND asset=?",
                (int(share_id or 0), str(asset or ""))).fetchone()
            return str(row["rel"]) if row else ""

    def share_visit_add(self, share_id: int, room_key: str, mode: str,
                        ref: str, visitor: str, ip_hash: str, ua: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO share_visits (ts,share_id,room_key,mode,ref,visitor,ip_hash,ua) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (iso(now_local()), int(share_id or 0), room_key[:120], mode[:20],
                 ref[:160], visitor[:60], ip_hash[:64], ua[:160]))
            self._conn.commit()

    def share_stats(self, days: int = 30) -> dict[str, Any]:
        """获客分析：按天、分享方式、来源、房源汇总；不含原始 IP。"""
        days = max(1, min(int(days or 30), 365))
        since = (now_local() - timedelta(days=days)).strftime("%Y-%m-%dT00:00:00+08:00")
        with self._lock:
            rows = self._conn.execute(
                "SELECT ts,share_id,room_key,mode,ref,visitor FROM share_visits "
                "WHERE ts>=? ORDER BY id DESC", (since,)).fetchall()
            share_count = self._conn.execute(
                "SELECT COUNT(*) c FROM share_records WHERE ts>=?", (since,)).fetchone()["c"]
        daily: dict[str, int] = {}
        modes: dict[str, int] = {}
        rooms: dict[str, int] = {}
        refs: dict[str, int] = {}
        visitors: set[str] = set()
        for r in rows:
            day = str(r["ts"])[:10]
            daily[day] = daily.get(day, 0) + 1
            modes[r["mode"] or "unknown"] = modes.get(r["mode"] or "unknown", 0) + 1
            if r["room_key"]:
                rooms[r["room_key"]] = rooms.get(r["room_key"], 0) + 1
            ref = (r["ref"] or "").split("?")[0][:80] or "直接打开/无来源"
            refs[ref] = refs.get(ref, 0) + 1
            if r["visitor"]:
                visitors.add(str(r["visitor"]))
        return {
            "days": days,
            "visits": len(rows),
            "visitors": len(visitors),
            "shares": int(share_count),
            "daily": [{"date": k, "visits": v} for k, v in sorted(daily.items())],
            "modes": [{"mode": k, "visits": v} for k, v in sorted(modes.items(), key=lambda x: -x[1])],
            "rooms": [{"roomKey": k, "visits": v} for k, v in sorted(rooms.items(), key=lambda x: -x[1])][:30],
            "refs": [{"ref": k, "visits": v} for k, v in sorted(refs.items(), key=lambda x: -x[1])][:30],
        }

    def _share_row(self, row: sqlite3.Row) -> dict[str, Any]:
        try:
            room_keys = json.loads(row["room_keys"] or "[]")
        except Exception:
            room_keys = []
        return {
            "id": row["id"], "roomKey": row["room_key"], "ts": row["ts"],
            "channel": row["channel"], "summary": row["summary"],
            "operator": row["operator"], "kind": row["kind"],
            "mode": row["mode"], "roomKeys": room_keys,
            "token": row["token"], "url": row["url"],
            "name": row["name"], "phone": row["phone"],
            "expiresAt": row["expires_at"], "revoked": bool(row["revoked"]),
        }

    # ------------------------------------------------------------------
    # 公开选房（脱敏，免鉴权；H5 / 公开链接用）
    # ------------------------------------------------------------------
    def public_rooms(self, mode: str = "masked") -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT room_key,room_no,tower,layout,price,status FROM houses "
                "WHERE is_deleted=0 AND status='available' "
                "ORDER BY tower, room_no").fetchall()
            media_map = self._media_map(self._conn, [r["room_key"] for r in rows])
            out = []
            for r in rows:
                media = media_map.get(r["room_key"], [])
                item = {
                    "roomKey": r["room_key"], "layout": r["layout"],
                    "status": r["status"],
                    "media": [{"objectKey": m["objectKey"], "fileName": m["fileName"],
                               "kind": m["kind"], "sortOrder": m["sortOrder"]}
                              for m in media],
                }
                if mode == "full":
                    item.update({"roomNo": r["room_no"], "tower": r["tower"],
                                 "price": r["price"]})
                out.append(item)
        return out

    def public_single(self, room_key: str, mode: str = "masked") -> dict[str, Any] | None:
        """公开只读单房；masked 不含房号/租金/房东/密码/备注，full 全量。仅待租、未删。"""
        with self._lock:
            row = self._conn.execute(
                "SELECT room_key,room_no,tower,layout,price,password,remark,landlord,status FROM houses "
                "WHERE room_key=? AND is_deleted=0 AND status='available'",
                (room_key,)).fetchone()
            if row is None:
                return None
            media = self._media(self._conn, row["room_key"])
            item = {
                "roomKey": row["room_key"], "layout": row["layout"],
                "status": row["status"],
                "media": [{"objectKey": m["objectKey"], "fileName": m["fileName"],
                           "kind": m["kind"], "sortOrder": m["sortOrder"]}
                          for m in media],
            }
            if mode == "full":
                item.update({
                    "roomNo": row["room_no"], "tower": row["tower"],
                    "price": row["price"], "password": row["password"],
                    "remark": row["remark"], "landlord": row["landlord"],
                })
            return item
