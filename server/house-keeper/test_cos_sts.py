import unittest

import cos_sts


FAKE_CONF = {
    "secretId": "AKIDfakefakefakefake",
    "secretKey": "skfakefakefakefake",
    "appId": "1250000000",
    "bucket": "house-1250000000",
    "region": "ap-hongkong",
}


class TestCosSts(unittest.TestCase):
    def test_policy_scoped_to_prefix(self):
        p = cos_sts._build_policy(FAKE_CONF, "h/")
        stmt = p["statement"][0]
        self.assertEqual(stmt["effect"], "allow")
        self.assertEqual(
            stmt["resource"],
            "qcs::cos:1250000000:house-1250000000/h/*")
        self.assertIn("name/cos:PutObject", stmt["action"])
        self.assertIn("name/cos:GetObject", stmt["action"])
        # 不应包含高权限动作
        self.assertNotIn("name/cos:*", stmt["action"])

    def test_policy_different_prefix(self):
        p = cos_sts._build_policy(FAKE_CONF, "h/2-1006/")
        self.assertEqual(
            p["statement"][0]["resource"],
            "qcs::cos:1250000000:house-1250000000/h/2-1006/*")

    def test_authorization_header_format_and_deterministic(self):
        payload = '{"a":1}'
        ts = 1_800_000_000
        a1 = cos_sts._authorization(FAKE_CONF, payload, ts, cos_sts.STS_HOST)
        a2 = cos_sts._authorization(FAKE_CONF, payload, ts, cos_sts.STS_HOST)
        self.assertTrue(a1.startswith("TC3-HMAC-SHA256 Credential=AKIDfake"))
        self.assertIn("SignedHeaders=content-type;host;x-tc-action", a1)
        self.assertIn("Signature=", a1)
        # 同输入确定
        self.assertEqual(a1, a2)

    def test_signature_changes_with_payload(self):
        ts = 1_800_000_000
        a1 = cos_sts._authorization(FAKE_CONF, '{"a":1}', ts, cos_sts.STS_HOST)
        a2 = cos_sts._authorization(FAKE_CONF, '{"a":2}', ts, cos_sts.STS_HOST)
        self.assertNotEqual(a1, a2)

    def test_missing_config_raises(self):
        with self.assertRaises(cos_sts.CosConfigError):
            cos_sts.load_cos_config()


if __name__ == "__main__":
    unittest.main()
