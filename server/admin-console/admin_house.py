#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 管理后台 —— 房源数据 / 媒体 / 账本 / 导出（admin_house）
==================================================================
复用 house-keeper HouseStore（SQLite 权威库），不另建表：
- 房源列表（检索/座别/状态过滤，含回收站）、详情、字段修改、删除/恢复。
- 媒体清单与调阅候选链接；账本事件查看（追加式审计流，历史事件不改写）。
- 全量导出 JSON / CSV。

口径说明：
- 字段修改走 upsert_house，自动写账本事件与 outbox；后台 operator 固定 "admin"。
- 历史账本事件为审计记录，不提供改写；如需追加管理员备注，后续在存储层补 append_ledger。
- 媒体对象存服务器本地磁盘（media_v2）；后台返回媒体清单与 objectKey，调阅走公开媒体接口。
"""

from __future__ import annotations

import csv
import io
import json
import time
from typing import Any


def _matches(house: dict[str, Any], q: str, tower: str, status: str) -> bool:
    if q:
        ql = q.lower()
        hay = " ".join(str(house.get(k, "")) for k in
                       ("roomNo", "landlord", "layout", "remark", "roomKey")).lower()
        if ql not in hay:
            return False
    if tower:
        if str(house.get("tower")) != str(tower):
            return False
    if status:
        if str(house.get("status")) != str(status):
            return False
    return True


class HouseConsole:
    def __init__(self, store: Any, hub: Any = None) -> None:
        self.store = store
        self.hub = hub

    def deliver_pending(self) -> None:
        """后台写完房源后立即尝试投递 outbox；真正的发送只走 house_api 一条路。"""
        if self.hub is None:
            return
        try:
            import house_api as ha
        except ImportError:
            import sys
            from pathlib import Path as _P
            sys.path.insert(0, str(_P(__file__).resolve().parent.parent / "house-keeper"))
            import house_api as ha
        ha.deliver_pending(self.store, self.hub)

    def list(self, q: str = "", tower: str = "", status: str = "",
             include_deleted: bool = True) -> dict[str, Any]:
        doc = self.store.list_houses(include_deleted=include_deleted)
        houses = [h for h in doc.get("houses", []) if _matches(h, q, tower, status)]
        stats = self.store.stats()
        return {"ok": True, "count": len(houses), "stats": stats, "houses": houses}

    def detail(self, room_key: str) -> dict[str, Any] | None:
        house = self.store.get_house(room_key)
        if house is None:
            return None
        house["ledger"] = self.store.ledger(room_key)
        return house

    def update(self, room_key: str, fields: dict[str, Any], notify_scope: str = "all",
               notify_user_token: str = "") -> dict[str, Any]:
        existing = self.store.get_house(room_key, with_media=False)
        if existing is None:
            return {"ok": False, "error": "not_found"}
        payload = {
            "roomKey": room_key,
            "roomNo": fields.get("roomNo", existing.get("roomNo")),
            "tower": fields.get("tower", existing.get("tower")),
            "landlord": fields.get("landlord", existing.get("landlord")),
            "layout": fields.get("layout", existing.get("layout")),
            "price": fields.get("price", existing.get("price")),
            "password": fields.get("password", existing.get("password")),
            "remark": fields.get("remark", existing.get("remark")),
            "status": fields.get("status", existing.get("status")),
            "media": existing.get("media", []),
        }
        try:
            doc = self.store.upsert_house(
                payload, operator="admin", origin_device_id="admin-web",
                notify_scope=notify_scope, notify_user_token=notify_user_token)
            return {"ok": True, "house": doc}
        except Exception as e:
            return {"ok": False, "error": type(e).__name__, "detail": str(e)[:200]}

    def set_deleted(self, room_key: str, deleted: bool, notify_scope: str = "all",
                    notify_user_token: str = "") -> dict[str, Any]:
        try:
            doc = self.store.set_deleted(
                room_key, deleted, "admin", "admin-web",
                notify_scope=notify_scope, notify_user_token=notify_user_token)
            return {"ok": True, **doc}
        except Exception as e:
            return {"ok": False, "error": type(e).__name__, "detail": str(e)[:200]}

    def ledger(self, room_key: str) -> list[dict[str, Any]]:
        return self.store.ledger(room_key)

    # ---- 导出 ----
    def export_json(self) -> tuple[bytes, str]:
        doc = self.store.list_houses(include_deleted=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        return (json.dumps(doc, ensure_ascii=False, indent=2).encode("utf-8"),
                f"houses-{stamp}.json")

    def export_csv(self) -> tuple[bytes, str]:
        doc = self.store.list_houses(include_deleted=True)
        cols = ["roomKey", "roomNo", "tower", "landlord", "layout", "price",
                "status", "remark", "password", "revision", "isDeleted",
                "createdAt", "updatedAt", "updatedBy", "mediaCount"]
        buf = io.StringIO()
        buf.write("\ufeff")  # BOM，Excel 打开中文不乱码
        writer = csv.writer(buf)
        writer.writerow(cols)
        for h in doc.get("houses", []):
            writer.writerow([
                h.get("roomKey", ""), h.get("roomNo", ""), h.get("tower", ""),
                h.get("landlord", ""), h.get("layout", ""), h.get("price", ""),
                h.get("status", ""), h.get("remark", ""), h.get("password", ""),
                h.get("revision", ""), h.get("isDeleted", False),
                h.get("createdAt", ""), h.get("updatedAt", ""), h.get("updatedBy", ""),
                len(h.get("media", [])),
            ])
        stamp = time.strftime("%Y%m%d-%H%M%S")
        return buf.getvalue().encode("utf-8-sig"), f"houses-{stamp}.csv"
