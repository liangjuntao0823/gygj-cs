#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全新架构服务端单测：本地磁盘媒体 + 配置/名片/分享记录 + 公开选房。"""

import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import house_store as hs_mod  # noqa: E402


def make_house(room_key="1-2059", price=1100, status="available"):
    return {"roomKey": room_key, "roomNo": room_key, "tower": 1, "landlord": "康",
            "layout": "单间", "price": price, "password": "", "remark": "",
            "status": status, "media": []}


class NativeStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "house_v2.db"
        self.media = Path(self.tmp.name) / "media"
        self.store = hs_mod.HouseStore(self.db, media_root=self.media)

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_media_save_read_delete(self):
        rel = self.store.media.save_house_media("1-2059", "1-2059-JPG-abcd-1.jpg", b"img")
        self.assertTrue(rel.startswith("houses/1-2059/"))
        self.assertEqual(self.store.media.read_house_media("1-2059", "1-2059-JPG-abcd-1.jpg"), b"img")
        self.store.media.delete_house_media("1-2059", "1-2059-JPG-abcd-1.jpg")
        self.assertIsNone(self.store.media.read_house_media("1-2059", "1-2059-JPG-abcd-1.jpg"))

    def test_media_reject_traversal_and_bad_ext(self):
        # 穿越片段被清洗为安全目录段，不会落到 root 之外
        rel = self.store.media.save_house_media("../etc", "x.jpg", b"x")
        self.assertNotIn("..", rel)
        with self.assertRaises(ValueError):
            self.store.media.save_house_media("1-2059", "evil.exe", b"x")

    def test_profile_roundtrip(self):
        prof = self.store.profile_set(name="梁涛", phone="13288251132", qr_path="profile/qrcode.jpg")
        self.assertEqual(prof["name"], "梁涛")
        self.assertEqual(prof["phone"], "13288251132")
        again = self.store.profile_get()
        self.assertEqual(again["name"], "梁涛")

    def test_config_roundtrip(self):
        self.store.config_set("app", {"compressUpload": True, "version": "1.0"})
        cfg = self.store.config_get("app")
        self.assertEqual(cfg["compressUpload"], True)
        self.assertEqual(cfg["version"], "1.0")

    def test_share_records(self):
        self.store.share_records_add("1-2059", "wechat", "脱敏卡片", "涛")
        recs = self.store.share_records_list()
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["roomKey"], "1-2059")

    def test_public_rooms_only_available(self):
        self.store.upsert_house(make_house("1-101", status="available"), operator="t")
        self.store.upsert_house(make_house("1-102", status="rented"), operator="t")
        rooms = self.store.public_rooms()
        keys = [r["roomKey"] for r in rooms]
        self.assertIn("1-101", keys)
        self.assertNotIn("1-102", keys)

    def test_public_single_only_available(self):
        self.store.upsert_house(make_house("1-201", status="available"), operator="t")
        self.store.upsert_house(make_house("1-202", status="rented"), operator="t")
        one = self.store.public_single("1-201")
        self.assertIsNotNone(one)
        self.assertEqual(one["roomKey"], "1-201")
        self.assertNotIn("landlord", one)  # 脱敏不返回房东
        self.assertIsNone(self.store.public_single("1-202"))
        self.assertIsNone(self.store.public_single("1-404"))

    def test_h5_page_renders(self):
        import h5_page
        html = h5_page.page_html()
        self.assertIn("/api/public/rooms", html)
        self.assertIn("roomKey", html)
        self.assertIn("拨打电话", html)

    def test_hard_delete_removes_disk_media(self):
        self.store.media.save_house_media("1-2059", "1-2059-JPG-abcd-1.jpg", b"img")
        self.store.upsert_house(make_house("1-2059"), operator="t")
        self.store.hard_delete("1-2059", operator="t")
        self.assertIsNone(self.store.media.read_house_media("1-2059", "1-2059-JPG-abcd-1.jpg"))
        self.assertIsNone(self.store.get_house("1-2059"))


if __name__ == "__main__":
    unittest.main()
