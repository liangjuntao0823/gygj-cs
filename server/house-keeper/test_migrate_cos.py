import unittest

import migrate_cos


class TestRecordToPayload(unittest.TestCase):
    def test_basic_fields_and_image_ref(self):
        rec = {
            "roomKey": "1-2334", "roomNo": "2334", "tower": 1,
            "landlord": "康", "layout": "单间", "price": 1100,
            "password": "", "remark": "", "status": "available",
            "mediaNames": ["photo1.jpg"],
        }
        p = migrate_cos.record_to_payload(rec)
        self.assertEqual(p["roomKey"], "1-2334")
        self.assertEqual(p["price"], 1100)
        self.assertEqual(len(p["media"]), 1)
        self.assertEqual(p["media"][0]["objectKey"],
                         "h/1-2334/photo1.jpg")
        self.assertEqual(p["media"][0]["kind"], "image")

    def test_video_mov_to_mp4_object_key(self):
        rec = {"roomKey": "2-1418", "tower": 2,
               "mediaNames": ["clip.mov"]}
        p = migrate_cos.record_to_payload(rec)
        m = p["media"][0]
        self.assertEqual(m["kind"], "video")
        self.assertEqual(m["objectKey"], "h/2-1418/clip.mp4")
        self.assertEqual(m["fileName"], "clip.mov")

    def test_empty_media(self):
        p = migrate_cos.record_to_payload(
            {"roomKey": "1-1001", "tower": 1})
        self.assertEqual(p["media"], [])

    def test_infer_kind(self):
        self.assertEqual(migrate_cos._infer_kind("a.mp4"), "video")
        self.assertEqual(migrate_cos._infer_kind("a.mov"), "video")
        self.assertEqual(migrate_cos._infer_kind("a.jpg"), "image")


class TestRunMigration(unittest.TestCase):
    def test_migration_with_fake_client_and_store(self):
        class FakeClient:
            def list_info_keys(self):
                return ["h/1-2334/info.json"]

            def get_object(self, key):
                import json
                return json.dumps({
                    "roomKey": "1-2334", "tower": 1, "price": 1100,
                    "mediaNames": []}).encode()

        class FakeStore:
            def __init__(self):
                self.upserts = []

            def upsert_house(self, payload, operator, origin_device_id):
                self.upserts.append(payload)

        store = FakeStore()
        res = migrate_cos.run_migration(
            store, FakeClient(), logger=lambda _m: None)
        self.assertEqual(res["imported"], 1)
        self.assertEqual(len(store.upserts), 1)


if __name__ == "__main__":
    unittest.main()
