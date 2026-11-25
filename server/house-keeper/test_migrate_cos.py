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

    def test_media_dedup_mov_mp4_same_key(self):
        rec = {"roomKey": "1-2023上",
               "mediaNames": ["clip.mov", "clip.mp4"]}
        p = migrate_cos.record_to_payload(rec)
        self.assertEqual(len(p["media"]), 1)
        self.assertEqual(p["media"][0]["fileName"], "clip.mp4")
        self.assertEqual(p["media"][0]["objectKey"], "h/1-2023上/clip.mp4")

    def test_infer_kind(self):
        self.assertEqual(migrate_cos._infer_kind("a.mp4"), "video")
        self.assertEqual(migrate_cos._infer_kind("a.mov"), "video")
        self.assertEqual(migrate_cos._infer_kind("a.jpg"), "image")

    def test_tower_fallback_by_prefix(self):
        p2 = migrate_cos.record_to_payload({"roomKey": "2-1418", "mediaNames": []})
        self.assertEqual(p2["tower"], 2)
        p1 = migrate_cos.record_to_payload({"roomKey": "1-1001", "mediaNames": []})
        self.assertEqual(p1["tower"], 1)

    def test_preserve_operator_and_epoch_time(self):
        rec = {"roomKey": "1-1004", "tower": 1, "updatedBy": "pc端",
               "updatedAt": 1795000000.0, "mediaNames": []}
        p = migrate_cos.record_to_payload(rec)
        self.assertEqual(p["updatedBy"], "pc端")
        self.assertTrue(p["updatedAt"].startswith("2026-"))
        self.assertIn("+08:00", p["updatedAt"])

    def test_ledger_events_parse(self):
        led = {"roomKey": "1-1004", "revision": 1, "events": [{
            "id": "EV-1", "date": 1795000000.0, "operatorName": "pc端",
            "action": "新增房源", "detail": "新建房源，图片 8 个、视频 1 个",
            "fieldChanges": [{"field": "price", "oldValue": "0",
                               "newValue": "1500"}]}]}
        evs = migrate_cos.ledger_events(led)
        self.assertEqual(len(evs), 1)
        ev = evs[0]
        self.assertEqual(ev["id"], "EV-1")
        self.assertEqual(ev["operator"], "pc端")
        self.assertEqual(ev["action"], "新增房源")
        self.assertTrue(ev["ts"].startswith("2026-"))
        self.assertEqual(ev["fieldChanges"][0]["newValue"], "1500")


class TestRunMigration(unittest.TestCase):
    def test_migration_with_fake_client_and_store(self):
        class FakeClient:
            def list_info_keys(self):
                return ["h/1-2334/info.json"]

            def get_object(self, key):
                import json
                if key.endswith("/ledger.json"):
                    return json.dumps({"events": [{
                        "id": "EV-1", "date": 1795000000.0,
                        "operatorName": "涛", "action": "新增房源",
                        "detail": "", "fieldChanges": []}]}).encode()
                return json.dumps({
                    "roomKey": "1-2334", "tower": 1, "price": 1100,
                    "updatedBy": "涛", "mediaNames": ["a.jpg"]}).encode()

        class FakeStore:
            def __init__(self):
                self.imports = []

            def import_house(self, payload, ledger_events=None, operator="迁移"):
                self.imports.append((payload, ledger_events))
                return {"media": payload["media"]}

        store = FakeStore()
        res = migrate_cos.run_migration(
            store, FakeClient(), logger=lambda _m: None)
        self.assertEqual(res["imported"], 1)
        self.assertEqual(res["ledgerEvents"], 1)
        self.assertEqual(res["mediaRefs"], 1)
        self.assertEqual(len(store.imports), 1)
        payload, events = store.imports[0]
        self.assertEqual(payload["roomKey"], "1-2334")
        self.assertEqual(events[0]["id"], "EV-1")

    def test_migration_ledger_missing_does_not_block(self):
        class FakeClient:
            def list_info_keys(self):
                return ["h/1-1001上/info.json"]

            def get_object(self, key):
                import json
                if key.endswith("/ledger.json"):
                    raise OSError("403")
                return json.dumps({"roomKey": "1-1001上", "tower": 1,
                                   "mediaNames": []}).encode()

        class FakeStore:
            def __init__(self):
                self.imports = []

            def import_house(self, payload, ledger_events=None, operator="迁移"):
                self.imports.append(payload)
                return {"media": []}

        store = FakeStore()
        res = migrate_cos.run_migration(
            store, FakeClient(), logger=lambda _m: None)
        self.assertEqual(res["imported"], 1)
        self.assertEqual(res["failed"], 0)


class TestCosXmlList(unittest.TestCase):
    def test_parse_real_cos_list_xml(self):
        xml = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<ListBucketResult>'
            '<Contents><Key>h/1-2334/info.json</Key></Contents>'
            '<Contents><Key>h/1-2334/photo.jpg</Key></Contents>'
            '<Contents><Key>h/2-1418/info.json</Key></Contents>'
            '<IsTruncated>false</IsTruncated>'
            '</ListBucketResult>'
        ).encode("utf-8")
        client = migrate_cos.CosXMLClient(
            secret_id="sid", secret_key="skey", bucket="b", region="ap-guangzhou")
        client._request = lambda method, path, query="": xml  # type: ignore[assignment]
        keys = client.list_info_keys()
        self.assertEqual(
            sorted(keys),
            ["h/1-2334/info.json", "h/2-1418/info.json"])

    def test_parse_xml_with_s3_namespace(self):
        xml = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            '<Contents><Key>h/2-1418/info.json</Key></Contents>'
            '<IsTruncated>false</IsTruncated>'
            '</ListBucketResult>'
        ).encode("utf-8")
        client = migrate_cos.CosXMLClient(
            secret_id="sid", secret_key="skey", bucket="b", region="ap-guangzhou")
        client._request = lambda method, path, query="": xml  # type: ignore[assignment]
        self.assertEqual(client.list_info_keys(),
                         ["h/2-1418/info.json"])


class TestGetObjectSigning(unittest.TestCase):
    def test_chinese_key_transport_encoded_sign_raw(self):
        captured: dict[str, str] = {}
        client = migrate_cos.CosXMLClient(
            secret_id="sid", secret_key="skey", bucket="b",
            region="ap-guangzhou")

        def fake(method, url_path, query="", sign_path=None):
            captured.update(url_path=url_path, sign_path=sign_path)
            return b"{}"

        client._request = fake  # type: ignore[assignment]
        client.get_object("h/1-1001上/info.json")
        self.assertEqual(captured["url_path"], "/h/1-1001%E4%B8%8A/info.json")
        self.assertEqual(captured["sign_path"], "/h/1-1001上/info.json")


if __name__ == "__main__":
    unittest.main()
