#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""notify-hub 离线单元测试：python3 -m unittest -v test_notify_hub"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import notify_hub as nh  # noqa: E402

KEY_A = "aaaaaaaaaaaaaaaaaaaaaa"   # 22 位 base62，模拟 Bark device key
KEY_B = "bbbbbbbbbbbbbbbbbbbbbb"
KEY_C = "cccccccccccccccccccccc"


class FakeSender:
    """记录所有投递但不发真实网络。"""
    def __init__(self):
        self.calls: list[tuple[str, str, dict]] = []

    def __call__(self, base: str, key: str, payload: dict, timeout: float = 8.0):
        self.calls.append((base, key, payload))
        return True, 200, {"code": 200}

    def keys(self) -> list[str]:
        return [k for _, k, _ in self.calls]


def make_hub(sender: FakeSender | None = None, config: dict | None = None):
    tmp = tempfile.TemporaryDirectory()
    sender = sender or FakeSender()
    cfg = {"enroll_code": "123456", "bark_base": "http://bark.local",
           "device_interval_seconds": 0}
    if config:
        cfg.update(config)
    hub = nh.HubRuntime(os.path.join(tmp.name, "notify.json"), config=cfg, sender=sender)
    return tmp, hub, sender


class TestParseBarkKey(unittest.TestCase):
    def test_plain_key(self):
        self.assertEqual(nh.parse_bark_key(KEY_A), KEY_A)

    def test_full_push_url(self):
        url = f"http://114.132.93.85:8081/{KEY_A}/%E6%A0%87%E9%A2%98/%E6%AD%A3%E6%96%87"
        self.assertEqual(nh.parse_bark_key(url), KEY_A)

    def test_host_key_title_without_scheme(self):
        self.assertEqual(nh.parse_bark_key(f"114.132.93.85:8081/{KEY_B}/标题/正文"), KEY_B)

    def test_url_inside_text(self):
        self.assertEqual(nh.parse_bark_key(f"复制 Bark 链接 https://api.day.app/{KEY_C} 查看"), KEY_C)

    def test_invalid(self):
        self.assertEqual(nh.parse_bark_key("push"), "")
        self.assertEqual(nh.parse_bark_key("abc"), "")
        self.assertEqual(nh.parse_bark_key(""), "")


class TestRegisterAndProfile(unittest.TestCase):
    def setUp(self):
        self.tmp, self.hub, self.sender = make_hub()

    def tearDown(self):
        self.tmp.cleanup()

    def test_code_and_key_validation(self):
        view, err = self.hub.register(code="000000", username="涛", bark_key=KEY_A)
        self.assertIsNone(view)
        self.assertEqual(err, "invalid_code")

        view, err = self.hub.register(code="123456", username="涛", bark_key="不是key")
        self.assertIsNone(view)
        self.assertEqual(err, "invalid_bark_key")

    def test_register_ok_and_masked(self):
        view, err = self.hub.register(code="123456", username="涛", bark_key=KEY_A,
                                      device_name="我的 iPhone")
        self.assertIsNone(err)
        self.assertTrue(view["token"].startswith("nt_"))
        self.assertEqual(view["username"], "涛")
        self.assertEqual(view["devicesCount"], 1)
        dev = view["devices"][0]
        self.assertIn("…", dev["keyMasked"])
        self.assertNotIn(KEY_A, str(view))   # 出参不得含完整 key

        me = self.hub.public_view(self.hub.store.get_user(view["token"]))
        self.assertEqual(me["devices"][0]["name"], "我的 iPhone")

    def test_username_conflict_then_token_update(self):
        v1, _ = self.hub.register(code="123456", username="涛", bark_key=KEY_A)
        t1 = v1["token"]
        # 无原 token：同名再次注册（新手机/冒名）必须拒绝，防止把设备绑到别人账号
        v2, err = self.hub.register(code="123456", username="涛", bark_key=KEY_B)
        self.assertIsNone(v2)
        self.assertEqual(err, "username_exists")
        # 持原 token 可以加绑第二台设备
        v3, err = self.hub.register(token=t1, username="涛", bark_key=KEY_B)
        self.assertIsNone(err)
        self.assertEqual(v3["devicesCount"], 2)
        # 同一 key 再同步只更新，不新增
        v4, err = self.hub.register(token=t1, username="涛", bark_key=KEY_B, device_name="备用机")
        self.assertIsNone(err)
        self.assertEqual(v4["devicesCount"], 2)
        self.assertEqual(v4["devices"][1]["name"], "备用机")


class TestDispatchIsolation(unittest.TestCase):
    def setUp(self):
        self.tmp, self.hub, self.sender = make_hub()
        self.u1, _ = self.hub.register(code="123456", username="房东甲", bark_key=KEY_A)
        self.u2, _ = self.hub.register(code="123456", username="房东乙", bark_key=KEY_B)
        self.t1, self.t2 = self.u1["token"], self.u2["token"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_each_user_only_gets_own_device(self):
        r1 = self.hub.dispatch(self.t1, "meter", "low", "甲的低电量", "只给甲")
        self.assertEqual((r1["sent"], r1["total"]), (1, 1))
        self.assertEqual(self.sender.keys()[-1], KEY_A)
        self.assertNotIn(KEY_B, self.sender.keys())

        r2 = self.hub.dispatch(self.t2, "meter", "off", "乙的拉闸", "只给乙")
        self.assertEqual((r2["sent"], r2["total"]), (1, 1))
        self.assertEqual(self.sender.keys()[-1], KEY_B)
        self.assertEqual(self.sender.keys().count(KEY_A), 1)  # 甲只收到自己那一条

        r3 = self.hub.dispatch("nt_not_exist", "meter", "low", "x", "y")
        self.assertEqual(r3["reason"], "unknown_user")
        self.assertEqual(len(self.sender.calls), 2)

    def test_user_and_module_switch_suppress(self):
        self.hub.set_prefs(self.t1, enabled=False)
        r = self.hub.dispatch(self.t1, "meter", "low", "标题", "正文")
        self.assertEqual(r["reason"], "user_disabled")
        self.assertEqual(self.sender.calls, [])

        self.hub.set_prefs(self.t1, enabled=True, modules={"meter": False})
        r = self.hub.dispatch(self.t1, "meter", "low", "电表事件", "应被模块开关拦截")
        self.assertEqual(r["reason"], "module_disabled")
        self.assertEqual(self.sender.calls, [])

        # 关掉 meter 模块不影响 system 通道测试
        rt = self.hub.send_test(self.t1)
        self.assertEqual((rt["sent"], rt["total"]), (1, 1))
        self.assertIn("通道", self.sender.calls[-1][2]["group"])

    def test_fingerprint_dedup_window(self):
        a = self.hub.dispatch(self.t1, "meter", "low", "同标题", "同正文")
        b = self.hub.dispatch(self.t1, "meter", "low", "同标题", "同正文")
        self.assertFalse(a.get("dedup"))
        self.assertTrue(b.get("dedup"))
        self.assertEqual(len(self.sender.calls), 1)
        self.hub.dispatch(self.t1, "meter", "low", "同标题", "不同正文")
        self.assertEqual(len(self.sender.calls), 2)

    def test_remove_device_then_no_device(self):
        dev_id = self.u1["devices"][0]["deviceId"]
        view = self.hub.remove_device(self.t1, device_id=dev_id)
        self.assertEqual(view["devicesCount"], 0)
        r = self.hub.dispatch(self.t1, "meter", "low", "t", "b")
        self.assertEqual(r["reason"], "no_device")

    def test_device_module_switch_filters(self):
        d1 = self.u1["devices"][0]["deviceId"]
        view, err = self.hub.set_device_prefs(self.t1, d1, modules={"house": False})
        self.assertIsNone(err)
        self.assertFalse(view["devices"][0]["modules"]["house"])
        r = self.hub.broadcast("house", "house_add", "房源新增", "只应发给乙")
        self.assertEqual((r["sent"], r["total"]), (1, 1))
        self.assertEqual(self.sender.keys(), [KEY_B])

    def test_house_access_checker_overrides_push_switch(self):
        hub = self.hub
        hub.access_checker = lambda token, module: token != self.t2
        r = hub.dispatch(self.t2, "house", "house_add", "标题", "正文")
        self.assertEqual(r["reason"], "module_access_denied")
        self.assertEqual(self.sender.calls, [])
        r2 = hub.broadcast("house", "house_add", "广播", "只发甲")
        self.assertEqual(r2["sent"], 1)
        self.assertEqual(self.sender.keys(), [KEY_A])

    def test_event_history_masked(self):
        self.hub.dispatch(self.t1, "meter", "low", "历史事件", "正文")
        me = self.hub.public_view(self.hub.store.get_user(self.t1))
        self.assertTrue(me["events"])
        ev = me["events"][0]
        self.assertEqual(ev["module"], "meter")
        self.assertNotIn(KEY_A, str(ev))
        self.assertTrue(ev["results"][0]["ok"])


class TestTodoReminders(unittest.TestCase):
    def setUp(self):
        self.tmp, self.hub, self.sender = make_hub()
        self.u, _ = self.hub.register(code="123456", username="待办用户", bark_key=KEY_A)
        self.token = self.u["token"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_replace_by_source_keeps_other_device(self):
        now = nh.now_ts()
        v, err = self.hub.replace_reminders(self.token, "dev_a", [
            {"id": "a1", "dueAt": now + 10, "body": "交房租"},
        ])
        self.assertIsNone(err)
        self.assertEqual(v["count"], 1)
        v2, err = self.hub.replace_reminders(self.token, "dev_b", [
            {"id": "b1", "dueAt": now + 20, "body": "抄水表"},
        ])
        self.assertIsNone(err)
        u = self.hub.store.get_user(self.token)
        self.assertEqual(set(u["reminders"].keys()), {"dev_a", "dev_b"})
        self.assertEqual(u["reminders"]["dev_a"][0]["body"], "交房租")

    def test_run_due_sends_once_and_preserves_sent(self):
        now = nh.now_ts()
        self.hub.replace_reminders(self.token, "dev_a", [
            {"id": "due1", "dueAt": now - 5, "body": "今天收租"},
            {"id": "future1", "dueAt": now + 60, "body": "明天抄表"},
        ])
        sent = self.hub.run_due_reminders(now=now)
        self.assertEqual(sent, 1)
        self.assertEqual(len(self.sender.calls), 1)
        self.assertEqual(self.sender.calls[0][2]["body"], "今天收租")
        self.assertIn("待办", self.sender.calls[0][2]["group"])
        # 第二次扫描不重复发送
        self.assertEqual(self.hub.run_due_reminders(now=now + 1), 0)
        # 客户端再次同步同一 dueAt，保留 sent_at
        self.hub.replace_reminders(self.token, "dev_a", [
            {"id": "due1", "dueAt": now - 5, "body": "今天收租"},
            {"id": "future1", "dueAt": now + 60, "body": "明天抄表"},
        ])
        self.assertEqual(self.hub.run_due_reminders(now=now + 2), 0)
        u = self.hub.store.get_user(self.token)
        self.assertTrue(u["reminders"]["dev_a"][0]["sent_at"])

    def test_module_switch_and_expired(self):
        now = nh.now_ts()
        self.hub.replace_reminders(self.token, "dev_a", [
            {"id": "old", "dueAt": now - nh.REMINDER_EXPIRE_SEC - 60, "body": "很旧的待办"},
            {"id": "soon", "dueAt": now + 5, "body": "快到了"},
        ])
        self.hub.set_prefs(self.token, modules={"todo": False})
        self.assertEqual(self.hub.run_due_reminders(now=now), 0)
        self.assertEqual(self.sender.calls, [])
        self.hub.set_prefs(self.token, modules={"todo": True})
        # 关闭待办时服务端已清空待发提醒；重新打开后需要 App 重新上报才会再推
        self.assertEqual(self.hub.run_due_reminders(now=now + 6), 0)
        self.hub.replace_reminders(self.token, "dev_a", [
            {"id": "soon", "dueAt": now + 5, "body": "快到了"},
        ])
        self.assertEqual(self.hub.run_due_reminders(now=now + 6), 1)
        u = self.hub.store.get_user(self.token)
        ids = {r["id"]: r for r in u["reminders"]["dev_a"]}
        self.assertNotIn("old", ids)   # 超过过期窗口的提醒在上报时就被丢弃
        self.assertEqual(ids["soon"]["status"], "sent")


class FakeHandler:
    def __init__(self, body=None, headers=None, ip="127.0.0.1"):
        self._body = body if body is not None else {}
        self.headers = headers or {}
        self.client_address = (ip, 9999)
        self.sent: list[tuple[int, dict]] = []

    def _send(self, obj: dict, code: int = 200, extra=None):
        self.sent.append((code, obj))

    def _read_json(self):
        return self._body


class TestHttpRoute(unittest.TestCase):
    def setUp(self):
        nh._fails.clear()
        self.tmp, self.hub, self.sender = make_hub()

    def tearDown(self):
        self.tmp.cleanup()

    def _call(self, method, sub, handler):
        return nh.route_request(handler, method, f"{nh.PREFIX}/{sub}", self.hub)

    def test_prefix_not_owned(self):
        h = FakeHandler()
        self.assertFalse(nh.route_request(h, "GET", "/api/meter/health", self.hub))
        self.assertEqual(h.sent, [])

    def test_health_open(self):
        h = FakeHandler()
        self.assertTrue(self._call("GET", "health", h))
        code, obj = h.sent[-1]
        self.assertEqual(code, 200)
        self.assertEqual(obj["service"], "notify-hub")

    def test_register_flow_and_auth(self):
        # 错误接入码 403
        h = FakeHandler(body={"code": "x", "username": "涛", "barkKey": KEY_A})
        self._call("POST", "register", h)
        self.assertEqual(h.sent[-1][0], 403)

        # 正确注册 200
        h = FakeHandler(body={"code": "123456", "username": "涛", "barkKey": KEY_A})
        self._call("POST", "register", h)
        code, obj = h.sent[-1]
        self.assertEqual(code, 200)
        token = obj["token"]
        self.assertTrue(token.startswith("nt_"))

        # 无 token 访问 me → 401
        h = FakeHandler()
        self._call("GET", "me", h)
        self.assertEqual(h.sent[-1][0], 401)

        # 带 token me → 200
        h = FakeHandler(headers={"Authorization": f"Bearer {token}"})
        self._call("GET", "me", h)
        self.assertEqual(h.sent[-1][0], 200)
        self.assertEqual(h.sent[-1][1]["username"], "涛")

        # test → 真实走 fake sender，sent=1
        h = FakeHandler(body={}, headers={"Authorization": f"Bearer {token}"})
        self._call("POST", "test", h)
        code, obj = h.sent[-1]
        self.assertEqual(code, 200)
        self.assertEqual(obj["sent"], 1)

    def test_prefs_requires_auth(self):
        h = FakeHandler(body={"enabled": False})
        self._call("POST", "prefs", h)
        self.assertEqual(h.sent[-1][0], 401)


class TestMeterTemplates(unittest.TestCase):
    def setUp(self):
        self.tmp, self.hub, self.sender = make_hub()
        view, _ = self.hub.register(code="123456", username="涛", bark_key=KEY_A)
        self.token = view["token"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_render_text_placeholder_and_cleanup(self):
        self.assertEqual(
            nh.render_text("{label} 剩余 {remain} 度", {"label": "101", "remain": "12.5"}),
            "101 剩余 12.5 度")
        # 时间隐藏后遗留的空括号 / 悬空空格与标点要清理干净
        self.assertEqual(nh.render_text("（{x}）", {"x": ""}), "")
        self.assertEqual(nh.render_text("充值。 {time}", {"time": ""}), "充值。")
        # 正文换行要保留：占位符替换后按行渲染，不把换行压成空格
        self.assertEqual(
            nh.render_text("{label}\n剩余 {remain} 度", {"label": "101", "remain": "12.5"}),
            "101\n剩余 12.5 度")
        # 占位符清空后整行剔除，不留下空行
        self.assertEqual(
            nh.render_text("{label}\n{time}", {"label": "101", "time": ""}), "101")

    def test_normalize_template_fallback_and_trim(self):
        dflt = nh.DEFAULT_TEMPLATES["meter"]["low"]
        tpl = nh.normalize_template({}, dflt)
        self.assertEqual(tpl["title"], dflt["title"])
        self.assertEqual(tpl["subtitle"], "")
        self.assertTrue(tpl["showTime"])
        custom = nh.normalize_template({"title": "  自定义标题  ", "subtitle": "快处理"}, dflt)
        self.assertEqual(custom["title"], "自定义标题")
        self.assertEqual(custom["subtitle"], "快处理")

    def test_get_default_templates(self):
        tpls = self.hub.get_templates(self.token)
        self.assertEqual(set(tpls.keys()), {"low", "off"})
        self.assertEqual(tpls["low"]["title"], "【电表低电量】")

    def test_set_and_render_custom_template(self):
        res = self.hub.set_templates(self.token, "meter", {
            "low": {"title": "自定义低电", "body": "{label} 剩 {remain} 度", "showTime": False}})
        self.assertEqual(res["low"]["title"], "自定义低电")
        # 未改动的 off 仍回默认
        self.assertEqual(res["off"]["title"], "【电表拉闸】")
        title, subtitle, body = self.hub.render_meter(
            self.token, "low", {"label": "201", "remain": "8", "threshold": "30"})
        self.assertEqual(title, "自定义低电")
        self.assertEqual(subtitle, "")
        self.assertEqual(body, "201 剩 8 度")

    def test_render_unknown_user_returns_none(self):
        self.assertIsNone(self.hub.render_meter("nt_nope", "low", {}))
        self.assertIsNone(self.hub.get_templates("nt_nope"))
        self.assertIsNone(self.hub.set_templates("nt_nope", "meter", {}))

    def test_preview_dispatches_one_event(self):
        before = len(self.sender.calls)
        res = self.hub.preview_template(self.token, "meter", "low")
        self.assertTrue(res.get("ok"))
        self.assertEqual(len(self.sender.calls), before + 1)
        base, key, payload = self.sender.calls[-1]
        self.assertEqual(payload["title"], "【电表低电量】")
        self.assertIn("示例房号", payload["body"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
