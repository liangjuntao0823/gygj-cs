#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""房源板块服务端单测：HouseStore(SQLite) + notify_hub.broadcast + house_api 路由。"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "notify-hub"))
sys.path.insert(0, str(HERE.parent / "meter-watch"))

import house_store as hs_mod  # noqa: E402
import notify_hub as nh  # noqa: E402


def make_house(room_key="1-2059", price=1100, landlord="康", status="available",
               media=None, tower=1):
    return {
        "roomKey": room_key, "roomNo": room_key, "tower": tower, "landlord": landlord,
        "layout": "单间", "price": price, "password": "", "remark": "",
        "status": status, "media": media or [],
    }


class FakeSender:
    def __init__(self):
        self.calls = []

    def __call__(self, base, key, payload, timeout=8):
        self.calls.append((key, payload))
        return True, 200, {"code": 200}


class HouseStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "house.db"
        self.store = hs_mod.HouseStore(self.db)

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_insert(self):
        doc = self.store.upsert_house(make_house(), operator="涛(iPhone)",
                                     origin_device_id="dev_origin")
        self.assertEqual(doc["revision"], 1)
        self.assertFalse(doc["isDeleted"])
        pending = self.store.pending_outbox()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["originDeviceId"], "dev_origin")

    def test_update_diff_and_revision(self):
        self.store.upsert_house(make_house(price=1100), operator="涛(iPhone)")
        doc = self.store.upsert_house(make_house(price=1200), operator="涛(iPhone)")
        self.assertEqual(doc["revision"], 2)
        led = self.store.ledger("1-2059")
        self.assertEqual(len(led), 2)
        changes = led[0]["fieldChanges"]
        self.assertTrue(any(c["field"] == "price" and c["newValue"] == "1200"
                            for c in changes))
        self.assertEqual(len(self.store.pending_outbox()), 2)

    def test_no_change_no_event(self):
        self.store.upsert_house(make_house(), operator="涛(iPhone)")
        before = len(self.store.pending_outbox())
        self.store.upsert_house(make_house(), operator="涛(iPhone)")
        self.assertEqual(len(self.store.pending_outbox()), before)

    def test_revision_conflict(self):
        self.store.upsert_house(make_house(), operator="涛(iPhone)")
        with self.assertRaises(hs_mod.RevisionConflict):
            self.store.upsert_house(make_house(price=999), operator="涛(iPhone)",
                                   expected_revision=99)

    def test_soft_delete_and_restore(self):
        self.store.upsert_house(make_house(), operator="涛(iPhone)")
        d = self.store.set_deleted("1-2059", True, "涛(iPhone)")
        self.assertTrue(d["isDeleted"])
        # 默认列表不含已删
        self.assertEqual(self.store.list_houses()["count"], 0)
        self.assertEqual(self.store.list_houses(include_deleted=True)["count"], 1)
        r = self.store.set_deleted("1-2059", False, "涛(iPhone)")
        self.assertFalse(r["isDeleted"])
        self.assertEqual(self.store.list_houses()["count"], 1)

    def test_incremental_since(self):
        self.store.upsert_house(make_house("1-2059"), operator="涛(iPhone)")
        self.store.upsert_house(make_house("2-1418", tower=2, media=[{"objectKey": "h/2-1418/a.jpg",
                                                              "fileName": "a.jpg",
                                                              "kind": "image"}]),
                               operator="涛(iPhone)")
        r = self.store.list_houses(since=1)
        self.assertEqual(r["count"], 1)
        self.assertEqual(r["houses"][0]["roomKey"], "2-1418")
        self.assertEqual(r["houses"][0]["media"][0]["objectKey"], "h/2-1418/a.jpg")

    def test_stats(self):
        self.store.upsert_house(make_house("1-2059"), operator="涛(iPhone)")
        self.store.upsert_house(make_house("2-1418", tower=2), operator="涛(iPhone)")
        s = self.store.stats()
        self.assertEqual(s["total"], 2)
        self.assertEqual(s["tower1"], 1)
        self.assertEqual(s["tower2"], 1)

    def test_import_house_preserves_fields_no_outbox(self):
        payload = {
            "roomKey": "1-1004", "roomNo": "1004", "tower": 1,
            "landlord": "业主", "layout": "复式", "price": 1500,
            "password": "", "remark": "全屋定制", "status": "rented",
            "updatedBy": "pc端", "updatedAt": "2026-11-01T10:00:00+08:00",
            "media": [{"objectKey": "h/1-1004/a.jpg", "fileName": "a.jpg",
                       "kind": "image"}]}
        events = [{"id": "EV-1", "ts": "2026-11-01T10:00:00+08:00",
                   "operator": "pc端", "action": "新增房源", "detail": "",
                   "fieldChanges": [{"field": "price", "oldValue": "0",
                                      "newValue": "1500"}]}]
        doc = self.store.import_house(payload, ledger_events=events)
        self.assertEqual(doc["updatedBy"], "pc端")
        self.assertTrue(doc["updatedAt"].startswith("2026-11-01"))
        self.assertEqual(doc["media"][0]["fileName"], "a.jpg")
        led = self.store.ledger("1-1004")
        self.assertEqual(len(led), 1)
        self.assertTrue(led[0]["migrated"])
        self.assertEqual(led[0]["fieldChanges"][0]["newValue"], "1500")
        # 存量迁移不产生待投递广播
        self.assertEqual(len(self.store.pending_outbox()), 0)

    def test_import_house_idempotent(self):
        payload = {"roomKey": "1-1004", "roomNo": "1004", "tower": 1,
                   "price": 1500, "status": "available", "media": []}
        events = [{"id": "EV-1", "ts": "2026-11-01T10:00:00+08:00",
                   "operator": "pc端", "action": "新增房源", "detail": "",
                   "fieldChanges": [{"field": "price", "oldValue": "0",
                                      "newValue": "1500"}]}]
        first = self.store.import_house(payload, ledger_events=events)
        self.store.import_house(payload, ledger_events=events)
        led = self.store.ledger("1-1004")
        self.assertEqual(len(led), 1)  # 账本事件不重复
        self.assertEqual(len(led[0]["fieldChanges"]), 1)  # 字段变更不重复
        again = self.store.get_house("1-1004")
        self.assertEqual(again["revision"], first["revision"])  # 修订号不推进

    def test_import_house_dedupes_media_refs(self):
        dup = {"objectKey": "h/1-1004/a.jpg", "fileName": "a.jpg", "kind": "image"}
        payload = {"roomKey": "1-1004", "tower": 1, "price": 1500,
                   "status": "available", "media": [dup, dict(dup)]}
        doc = self.store.import_house(payload)
        self.assertEqual(len(doc["media"]), 1)


class BroadcastTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.hub = nh.HubRuntime(
            str(Path(self.tmp.name) / "notify.json"),
            config={"bark_base": "http://x", "enroll_code": "secret"},
            sender=FakeSender())
        # 两个用户、各两台设备
        self.v1, _ = self.hub.register(code="secret", token="", username="涛",
                                       bark_key="https://x/keykeykey0001",
                                       device_name="iPhone")
        self.t1 = self.v1["token"]
        self.hub.register(code="", token=self.t1, username="涛",
                          bark_key="https://x/keykeykey0002", device_name="iPad")
        self.v2, _ = self.hub.register(code="secret", token="", username="明",
                                       bark_key="https://x/keykeykey0003")
        self.t2 = self.v2["token"]
        self.hub.register(code="", token=self.t2, username="明",
                          bark_key="https://x/keykeykey0004")

    def tearDown(self):
        self.tmp.cleanup()

    def test_broadcast_all_devices(self):
        res = self.hub.broadcast("house", "编辑保存", "房源变更 · 1-2059",
                                 "涛(iPhone) 租金 1100→1200")
        self.assertEqual(res["total"], 4)
        self.assertEqual(res["sent"], 4)
        self.assertEqual(res["users"], 2)

    def test_broadcast_excludes_origin_device(self):
        origin = self.v1["devices"][0]["deviceId"]
        res = self.hub.broadcast("house", "编辑保存", "t", "b",
                                 exclude_device_id=origin)
        # 发起设备被跳过，其余 3 台收到
        self.assertEqual(res["total"], 3)
        pushed = {c[0] for c in self.hub._sender.calls}
        self.assertNotIn(self.v1["devices"][0]["keyMasked"], pushed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
