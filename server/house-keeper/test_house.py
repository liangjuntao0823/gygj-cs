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

    def test_create_only_rejects_duplicate_room(self):
        """新增房源必须同座同房号唯一；服务器已有该房时不能被新设备覆盖。"""
        self.store.upsert_house(make_house("1-2334上"), operator="A(iPhone)")
        with self.assertRaises(hs_mod.DuplicateHouse) as ctx:
            self.store.upsert_house(make_house("1-2334上", price=999),
                                    operator="B(iPhone)", create_only=True)
        self.assertEqual(ctx.exception.room_key, "1-2334上")
        doc = self.store.get_house("1-2334上")
        self.assertEqual(doc["price"], 1100)

    def test_revision_conflict(self):
        self.store.upsert_house(make_house(), operator="涛(iPhone)")
        with self.assertRaises(hs_mod.RevisionConflict):
            self.store.upsert_house(make_house(price=999), operator="涛(iPhone)",
                                   expected_revision=99)

    def test_field_level_merge_non_overlap(self):
        """两边改不同字段：自动合并；只改一边的字段不被旧快照回滚。"""
        first = self.store.upsert_house(make_house(price=1100), operator="A(iPhone)")
        base = {"roomNo": first["roomNo"], "tower": first["tower"],
                "landlord": first["landlord"], "layout": first["layout"],
                "price": first["price"], "password": first["password"],
                "remark": first["remark"], "status": first["status"]}
        # 服务器另一台设备改了备注
        server = make_house(price=1100, landlord="康")
        server["remark"] = "服务器备注"
        self.store.upsert_house(server, operator="B(iPhone)",
                                expected_revision=first["revision"])
        # 本机基于旧快照改租金
        client = make_house(price=1250, landlord="康")
        client["base"] = base
        doc = self.store.upsert_house(client, operator="A(iPhone)")
        self.assertEqual(doc["price"], 1250)
        self.assertEqual(doc["remark"], "服务器备注")

    def test_field_level_conflict_same_field(self):
        """同字段两边都改：拒绝覆盖并返回明细。"""
        first = self.store.upsert_house(make_house(price=1100), operator="A(iPhone)")
        base = {"roomNo": first["roomNo"], "tower": first["tower"],
                "landlord": first["landlord"], "layout": first["layout"],
                "price": first["price"], "password": first["password"],
                "remark": first["remark"], "status": first["status"]}
        self.store.upsert_house(make_house(price=1300), operator="B(iPhone)",
                                expected_revision=first["revision"])
        client = make_house(price=1200)
        client["base"] = base
        with self.assertRaises(hs_mod.FieldConflict) as ctx:
            self.store.upsert_house(client, operator="A(iPhone)")
        self.assertEqual(ctx.exception.conflicts[0]["field"], "price")
        self.assertEqual(self.store.get_house("1-2059")["price"], 1300)

    def test_media_union_keeps_server_media(self):
        """只带本次新媒体：服务器原有媒体不能被覆盖掉。"""
        a = {"objectKey": "h/1-2059/a.jpg", "fileName": "a.jpg", "kind": "image"}
        b = {"objectKey": "houses/1-2059/b.jpg", "fileName": "b.jpg", "kind": "image"}
        first = self.store.upsert_house(make_house(media=[a]), operator="A(iPhone)")
        # b 必须真实存在磁盘（houses/ 前缀会做存在性校验）
        self.store.media.house_path("1-2059", "b.jpg").parent.mkdir(parents=True, exist_ok=True)
        self.store.media.house_path("1-2059", "b.jpg").write_bytes(b"x")
        payload = make_house(media=[a, b])
        payload["baseMedia"] = [a["objectKey"]]
        doc = self.store.upsert_house(payload, operator="B(iPhone)",
                                      expected_revision=first["revision"])
        keys = [m["objectKey"] for m in doc["media"]]
        self.assertIn(a["objectKey"], keys)
        self.assertIn(b["objectKey"], keys)

    def test_validation_rejects_bad_values(self):
        for bad in (make_house(price=-100), make_house(status="whatever"),
                    make_house(tower=99)):
            with self.assertRaises(ValueError):
                self.store.upsert_house(bad, operator="A(iPhone)")

    def test_orphan_scan_and_delete_skips_referenced(self):
        a = {"objectKey": "houses/1-2059/a.jpg", "fileName": "a.jpg", "kind": "image"}
        ref = self.store.media.house_path("1-2059", "a.jpg")
        ref.parent.mkdir(parents=True, exist_ok=True)
        ref.write_bytes(b"ref")
        self.store.upsert_house(make_house(media=[a]), operator="A(iPhone)")
        orphan = self.store.media.house_path("1-2059", "orphan.jpg")
        orphan.write_bytes(b"orphan")
        res = self.store.list_orphan_media(min_age_seconds=0)
        keys = [f["objectKey"] for f in res["files"]]
        self.assertIn("houses/1-2059/orphan.jpg", keys)
        deleted = self.store.delete_orphan_media(
            ["houses/1-2059/orphan.jpg", "houses/1-2059/a.jpg"], min_age_seconds=0)
        self.assertIn("houses/1-2059/orphan.jpg", deleted["deleted"])
        # 被 media_refs 引用的 a.jpg 必须跳过
        skipped = [x["objectKey"] for x in deleted["skipped"]]
        self.assertIn("houses/1-2059/a.jpg", skipped)
        self.assertTrue(ref.exists())

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

    def test_hard_delete_cascades(self):
        media = [{"objectKey": "h/1-2059/a.jpg", "fileName": "a.jpg", "kind": "image"}]
        self.store.upsert_house(make_house(media=media), operator="涛(iPhone)")
        # 改一次价产生账本事件与字段变更
        self.store.upsert_house(make_house(price=1200), operator="涛(iPhone)",
                                expected_revision=1)
        self.assertIsNotNone(self.store.get_house("1-2059"))
        before_outbox = len(self.store.pending_outbox())
        result = self.store.hard_delete("1-2059", "涛(iPhone)")
        self.assertTrue(result["hardDelete"])
        # 房源、媒体引用、账本事件与字段变更全部物理移除
        self.assertIsNone(self.store.get_house("1-2059"))
        self.assertEqual(self.store.list_houses()["count"], 0)
        self.assertEqual(self.store.ledger("1-2059"), [])
        self.assertEqual(self.store._conn.execute(
            "SELECT COUNT(*) FROM media_refs WHERE room_key=?",
            ("1-2059",)).fetchone()[0], 0)
        self.assertEqual(self.store._conn.execute(
            "SELECT COUNT(*) FROM field_changes WHERE event_id IN "
            "(SELECT id FROM ledger_events WHERE room_key=?)",
            ("1-2059",)).fetchone()[0], 0)
        # outbox 仍写一条删除事件，供其他接入设备同步本地删除
        self.assertEqual(len(self.store.pending_outbox()), before_outbox + 1)

    def test_edit_after_hard_delete_does_not_resurrect(self):
        self.store.upsert_house(make_house(), operator="A")
        self.store.hard_delete("1-2059", "B")
        # 另一台离线设备仍拿旧修订号提交编辑：必须报冲突，不能插回新房源
        with self.assertRaises(hs_mod.RevisionConflict):
            self.store.upsert_house(make_house(price=999), operator="A",
                                   expected_revision=1)
        self.assertIsNone(self.store.get_house("1-2059"))

    def test_hard_delete_is_idempotent(self):
        self.store.upsert_house(make_house(), operator="A")
        self.assertTrue(self.store.hard_delete("1-2059", "A")["hardDelete"])
        second = self.store.hard_delete("1-2059", "B")
        self.assertTrue(second["hardDelete"])
        self.assertTrue(second.get("alreadyDeleted"))

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

    def test_append_ledger_event_writes_and_dedupes(self):
        self.store.upsert_house(make_house(), operator="涛(iPhone)")
        before_outbox = len(self.store.pending_outbox())
        ev = {"id": "LED-1", "ts": "2026-11-26T12:00:00+08:00",
              "action": "编辑保存", "detail": "租金调整",
              "fieldChanges": [{"field": "price", "oldValue": "1000",
                                "newValue": "1100"}]}
        res = self.store.append_ledger_event("1-2059", ev, operator="涛(iPhone)")
        self.assertFalse(res["deduplicated"])
        led = self.store.ledger("1-2059")
        self.assertEqual(len(led), 2)
        self.assertFalse(led[0]["migrated"])
        self.assertEqual(led[0]["action"], "编辑保存")
        self.assertEqual(led[0]["operator"], "涛(iPhone)")
        self.assertEqual(led[0]["fieldChanges"][0]["newValue"], "1100")
        # 同 id 重复追加：幂等去重，不进 outbox
        again = self.store.append_ledger_event("1-2059", ev, operator="涛(iPhone)")
        self.assertTrue(again["deduplicated"])
        self.assertEqual(len(self.store.ledger("1-2059")), 2)
        self.assertEqual(len(self.store.pending_outbox()), before_outbox)

    def test_append_ledger_event_auto_id(self):
        self.store.upsert_house(make_house(), operator="涛(iPhone)")
        res = self.store.append_ledger_event("1-2059", {"action": "补齐媒体"},
                                             operator="明")
        self.assertTrue(res["id"])
        led = self.store.ledger("1-2059")
        self.assertEqual(len(led), 2)
        self.assertEqual(led[0]["detail"], "")


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
