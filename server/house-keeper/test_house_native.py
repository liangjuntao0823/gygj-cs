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


def make_house(room_key="1-2059", price=1100, status="available", layout="单间"):
    return {"roomKey": room_key, "roomNo": room_key, "tower": 1, "landlord": "康",
            "layout": layout, "price": price, "password": "", "remark": "",
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

    def _render_single(self, mode):
        import h5_page
        self.store.upsert_house(make_house("1-2059", price=1100), operator="t")
        self.store.media.save_share_asset("1-2059", "cover.jpg", b"cover")
        self.store.media.save_house_media("1-2059", "1-2059-a.jpg", b"img")
        self.store.upsert_house({"roomKey":"1-2059","roomNo":"1-2059","tower":1,
                                 "landlord":"康","layout":"单间","price":1100,
                                 "password":"1234","remark":"全屋定制",
                                 "status":"available",
                                 "media":[{"fileName":"1-2059-a.jpg","kind":"image"}]}, operator="t")
        class H:
            headers = {"Host": "114.132.93.85:8082", "X-Forwarded-Proto": "http"}
        return h5_page.render_single(self.store, H(), "tok", "1-2059", mode)

    def test_h5_masked_hides_internal(self):
        html = self._render_single("masked")
        self.assertIn("米兰公馆", html)
        self.assertIn("单间", html)
        self.assertNotIn("1100", html)
        self.assertNotIn("1234", html)
        self.assertNotIn("全屋定制", html)

    def test_h5_full_shows_details(self):
        html = self._render_single("full")
        self.assertIn("1-2059", html)
        self.assertIn("1100", html)
        self.assertIn("1234", html)

    def test_h5_og_and_token_media(self):
        html = self._render_single("masked")
        self.assertIn('property="og:title"', html)
        self.assertIn('property="og:image"', html)
        self.assertIn("/api/public/media/share/1-2059/cover.jpg?t=tok", html)

    def test_h5_collection_and_list(self):
        import h5_page
        for key, price, layout in (("1-101", 900, "单间"), ("1-102", 1300, "一房一厅")):
            self.store.upsert_house(make_house(key, price=price, layout=layout), operator="t")
        class H:
            headers = {"Host": "114.132.93.85:8082", "X-Forwarded-Proto": "http"}
        col = h5_page.render_collection(self.store, H(), "tok", ["1-101", "1-102"], "masked")
        self.assertIn("单间", col)
        self.assertIn("一房一厅", col)
        self.assertNotIn("900", col)
        rooms = h5_page.render_list(self.store, H(), "tok")
        self.assertIn("米兰公馆 · 在租房源", rooms)
        self.assertIn("单间", rooms)
        self.assertNotIn("康", rooms)

    def test_share_token_roundtrip(self):
        from share_auth import ShareSigner
        signer = ShareSigner(Path(self.tmp.name) / "secret")
        exp = signer.expires(2)
        token = signer.sign(1, exp)
        self.assertEqual(signer.verify(token)["sid"], 1)
        self.assertEqual(signer.verify(token + "x"), None)
        expired = signer.sign(1, int(__import__("time").time()) - 1)
        self.assertEqual(signer.verify(expired), None)

    def test_media_stream_same_name_does_not_overwrite(self):
        import io
        rel1 = self.store.media.save_house_media_stream(
            "1-2222", "1-2222", io.BytesIO(b"first"), 5, allow_unknown_ext=True)
        rel2 = self.store.media.save_house_media_stream(
            "1-2222", "1-2222", io.BytesIO(b"second"), 6, allow_unknown_ext=True)
        self.assertNotEqual(rel1, rel2)
        self.assertEqual(self.store.media.read_house_media("1-2222", "1-2222.jpg"), b"first")
        second_name = rel2.rsplit("/", 1)[-1]
        self.assertEqual(self.store.media.read_house_media("1-2222", second_name), b"second")

    def test_ops_append_list_delete(self):
        self.store.append_op("房源", "修改租金", "成功", "租金 600→700", "1-2222", "涛")
        recs = self.store.list_ops()
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["op"], "房源·修改租金·成功")
        self.assertEqual(recs[0]["room"], "1-2222")
        self.assertTrue(self.store.delete_op(op_id=recs[0]["id"]))
        self.assertEqual(self.store.list_ops(), [])

    def test_hard_delete_removes_disk_media(self):
        self.store.media.save_house_media("1-2059", "1-2059-JPG-abcd-1.jpg", b"img")
        self.store.upsert_house(make_house("1-2059"), operator="t")
        self.store.hard_delete("1-2059", operator="t")
        self.assertIsNone(self.store.media.read_house_media("1-2059", "1-2059-JPG-abcd-1.jpg"))
        self.assertIsNone(self.store.get_house("1-2059"))


if __name__ == "__main__":
    unittest.main()
