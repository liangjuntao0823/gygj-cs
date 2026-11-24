#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""meter-watch 离线单元测试：python3 -m unittest -v test_meter_watch"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import meter_watch as mw  # noqa: E402
from meter_api import CloudHandler  # noqa: E402


class FakeResp:
    def __init__(self, payload: dict):
        self._raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    def read(self) -> bytes:
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakePusher:
    def __init__(self):
        self.calls: list[tuple[list[str], str, str]] = []

    def push_many(self, keys, title, body, opts=None, interval=0.0):
        keys = list(keys or [])
        self.calls.append((keys, title, body))
        return len(keys), len(keys)

    def titles(self) -> list[str]:
        return [t for _, t, _ in self.calls]


class TestPlatformClient(unittest.TestCase):
    def test_parse_index_bind_query(self):
        client = mw.MeterPlatformClient(request_interval=0, sleeper=lambda _s: None)
        seen = {}

        def fake_open(req, timeout):
            seen["url"] = req.full_url
            seen["data"] = req.data.decode("utf-8")
            seen["ua"] = req.headers.get("User-agent", "")
            if req.full_url.endswith(mw.PATH_INDEX):
                return FakeResp({"code": 0, "data": {"wechatId": 123456}})
            if req.full_url.endswith(mw.PATH_BIND_LIST):
                return FakeResp({"code": 0, "data": [{"bindMeterId": "1001"}, {"bindMeterId": "1002"}]})
            return FakeResp({"code": 0, "data": {
                "shengyu": "20.5", "leiji": "123.4", "zhuangtai": "合闸",
                "shijian": "2026-11-24 13:00:00"}})

        client._open = fake_open  # type: ignore[method-assign]

        self.assertEqual(client.index_open_id("ox-secret"), "123456")
        self.assertIn("openId=ox-secret", seen["data"])
        self.assertIn("MicroMessenger", seen["ua"])

        self.assertEqual(client.fetch_bindings("123456"), ["1001", "1002"])
        q = client.query_meter("123456", "1001")
        self.assertEqual(q["shengyu"], "20.5")
        self.assertEqual(q["zhuangtai"], "合闸")

    def test_business_error_raises(self):
        client = mw.MeterPlatformClient(timeout=2)
        client._open = lambda req, timeout: FakeResp({"code": 500, "msg": "获取用户失败请重新打开!"})  # type: ignore
        with self.assertRaises(mw.PlatformError):
            client.index_open_id("bad")

    def test_query_business_failure_raises(self):
        client = mw.MeterPlatformClient(request_interval=0, sleeper=lambda _s: None)
        # 平台对离线/弱信号表在 code=0、data 内回中文“查询失败”，必须识别为该表失败而非数值 0
        client._open = lambda req, timeout: FakeResp({
            "code": 0,
            "data": {"shengyu": "查询失败", "leiji": "查询失败",
                     "zhuangtai": "查询失败", "shijian": "查询失败"}})
        with self.assertRaises(mw.PlatformMeterError):
            client.query_meter("123456", "011714")

        # 正常数字字符串仍原样返回（保持既有字段类型约定，Engine 层再 to_float）
        client._open = lambda req, timeout: FakeResp({
            "code": 0,
            "data": {"shengyu": "20.5", "leiji": "123.4", "zhuangtai": "合闸",
                     "shijian": "2026-11-24 13:00:00"}})
        q = client.query_meter("123456", "012334")
        self.assertEqual(q["shengyu"], "20.5")
        self.assertEqual(q["zhuangtai"], "合闸")


class TestRoomRule(unittest.TestCase):
    def test_format_uid_room(self):
        self.assertEqual(mw.format_uid_room("012334"), "1座2334")
        self.assertEqual(mw.format_uid_room("021418"), "2座1418")
        self.assertEqual(mw.format_uid_room("032334"), "")   # 座号仅 01/02
        self.assertEqual(mw.format_uid_room("12345"), "")    # 非 6 位
        self.assertEqual(mw.format_uid_room("01233a"), "")   # 含非数字
        self.assertEqual(mw.format_uid_room(""), "")

    def test_meter_label_priority(self):
        self.assertEqual(mw.meter_label("012334", "2334上层"), "2334上层")  # App 备注权威优先
        self.assertEqual(mw.meter_label("012334", ""), "1座2334")
        self.assertEqual(mw.meter_label("021006"), "2座1006")
        self.assertEqual(mw.meter_label("abc1234", ""), "电表1234")
        self.assertEqual(mw.meter_label("999", ""), "999")


class TestEvaluator(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = mw.Store(self.tmp.name)
        self.fake = FakePusher()
        self.engine = mw.Engine(self.store, pusher=self.fake)  # type: ignore[arg-type]
        self.svc = dict(self.store.svc)
        self.svc.update({"low_remind_hours": 24, "off_remind_hours": 24, "notify_recovery": True})
        self.tenant = {"bark_keys": ["k-iphone"]}

    def tearDown(self):
        self.tmp.cleanup()

    def test_low_edge_dedup_remind_recover(self):
        now = 1_000_000.0
        period = 3600.0
        m = mw._new_meter_state("1-2334上")
        m["zhuangtai"] = "合闸"
        m["shengyu"] = 20.0

        titles = self.engine.evaluate_meter(self.svc, self.tenant, "u1", m, 30.0, now, period_seconds=period)
        self.assertEqual(len(titles), 1)
        self.assertIn("低电量", titles[0])
        self.assertIn("1-2334上", self.fake.calls[-1][2])
        self.assertIn("20 度", self.fake.calls[-1][2])
        self.assertTrue(m["low_active"])
        self.assertEqual(m["last_low_push"], now)

        # 同一轮询期内不重复
        self.assertEqual(self.engine.evaluate_meter(self.svc, self.tenant, "u1", m, 30.0, now + 60, period_seconds=period), [])

        # 超过一个轮询期持续低电量复提醒
        titles = self.engine.evaluate_meter(self.svc, self.tenant, "u1", m, 30.0, now + 2 * period, period_seconds=period)
        self.assertEqual(len(titles), 1)
        self.assertIn("提醒", titles[0])

        # 电量回升推恢复并复位
        m["shengyu"] = 60.0
        titles = self.engine.evaluate_meter(self.svc, self.tenant, "u1", m, 30.0, now + 2 * period + 60, period_seconds=period)
        self.assertEqual(len(titles), 1)
        self.assertIn("恢复", titles[0])
        self.assertFalse(m["low_active"])

    def test_off_edge_and_recover(self):
        now = 2_000_000.0
        period = 3600.0
        m = mw._new_meter_state("2-1418下")
        m["zhuangtai"] = "拉闸"
        titles = self.engine.evaluate_meter(self.svc, self.tenant, "u2", m, 30.0, now, period_seconds=period)
        self.assertEqual(titles, ["【电表拉闸】"])
        self.assertEqual(self.engine.evaluate_meter(self.svc, self.tenant, "u2", m, 30.0, now + 30, period_seconds=period), [])
        m["zhuangtai"] = "合闸"
        titles = self.engine.evaluate_meter(self.svc, self.tenant, "u2", m, 30.0, now + 60, period_seconds=period)
        self.assertEqual(titles, ["【电表恢复】"])
        self.assertFalse(m["off_active"])

    def test_no_keys_no_raise(self):
        svc = {**self.svc, "default_bark_keys": []}
        m = mw._new_meter_state()
        m["zhuangtai"] = "合闸"
        m["shengyu"] = 1.0
        titles = self.engine.evaluate_meter(svc, {"bark_keys": []}, "u3", m, 30.0, 3_000_000.0)
        self.assertEqual(titles, [])

    def test_zero_reading_protected(self):
        m = mw._new_meter_state()
        m["zhuangtai"] = "合闸"
        m["shengyu"] = 0.0
        titles = self.engine.evaluate_meter(self.svc, self.tenant, "u4", m, 30.0, 4_000_000.0)
        self.assertEqual(titles, [])
        self.assertFalse(m["low_active"])


class _FakePlatform:
    def __init__(self):
        self.fail = True
        self.index_calls = 0

    def index_open_id(self, open_id):
        self.index_calls += 1
        return "w1"

    def query_with_retry(self, wechat_id, uid, retries=1):
        if self.fail:
            raise mw.PlatformError("模拟平台故障")
        return {"shengyu": "50", "leiji": "9.0", "zhuangtai": "合闸", "shijian": "2026-11-24 13:10:00"}


class TestFailureRound(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = mw.Store(self.tmp.name)
        self.fake = FakePusher()
        self.engine = mw.Engine(self.store, pusher=self.fake)  # type: ignore[arg-type]
        self.platform = _FakePlatform()
        self.engine.make_client = lambda svc: self.platform  # type: ignore[method-assign]
        self.store.svc["failure_alert_rounds"] = 3
        self.tenant = {
            "enabled": True,
            "settings": {"openId": "ox", "lowThreshold": 30.0, "lowAlertEnabled": True},
            "meters": [{"uid": "u1", "room": "1-2423"}],
            "bark_keys": ["k1"],
        }

    def tearDown(self):
        self.tmp.cleanup()

    def test_alert_after_three_rounds_then_recovery(self):
        ts = mw._new_tenant_state()
        for _ in range(2):
            self.engine.run_tenant("tok", self.store.svc, self.tenant, ts, False)
        self.assertFalse(any("监控异常" in t for t in self.fake.titles()))
        self.engine.run_tenant("tok", self.store.svc, self.tenant, ts, False)
        self.assertTrue(any("监控异常" in t for t in self.fake.titles()))
        self.assertEqual(ts["consecutive_failures"], 3)

        self.platform.fail = False
        self.engine.run_tenant("tok", self.store.svc, self.tenant, ts, False)
        self.assertEqual(ts["consecutive_failures"], 0)
        self.assertTrue(any("监控恢复" in t for t in self.fake.titles()))


class TestStore(unittest.TestCase):
    def test_enroll_upsert_clean(self):
        with tempfile.TemporaryDirectory() as d:
            store = mw.Store(d)
            token = store.enroll(str(store.svc["enroll_code"]), "iphone-test")
            self.assertTrue(token and len(token) >= 32)
            tenant = store.load_tenants()[token]
            self.assertFalse(tenant["enabled"])

            updated = store.upsert_config(token, {
                "enabled": True,
                "settings": {"openId": "ox2", "lowThreshold": 0, "lowAlertEnabled": False},
                "meters": [{"uid": "a", "room": "r"}, {"uid": "a"}, {"uid": "b"}],
            })
            self.assertTrue(updated["enabled"])
            self.assertEqual(updated["settings"]["lowThreshold"], 1.0)  # 下限保护
            self.assertEqual(len(updated["meters"]), 2)               # 同 uid 去重
            self.assertFalse(updated["settings"]["lowAlertEnabled"])

            self.assertIsNone(store.tenant_for_token(None)[0])
            self.assertIsNone(store.tenant_for_token("Bearer nope")[0])

    def test_parse_open_id(self):
        link = "http://wy.mlh-china.com/electricmeter/?openId=abc123&from=wx"
        self.assertEqual(mw.parse_open_id(link), "abc123")
        self.assertEqual(mw.parse_open_id("not a link"), "")


class TestTenantPollSchedule(unittest.TestCase):
    """租户级云端轮询间隔：App 下发入库校验 + worker only_due 到期过滤。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = mw.Store(self.tmp.name)
        self.engine = mw.Engine(self.store, dry_run=True)

    def tearDown(self):
        self.tmp.cleanup()

    def _enroll_enabled(self, poll=None):
        token = self.store.enroll(str(self.store.svc["enroll_code"]), "iphone-test")
        settings = {"openId": "ox-" + token[:6], "lowThreshold": 30}
        if poll is not None:
            settings["pollIntervalSeconds"] = poll
        tenant = self.store.upsert_config(
            token, {"enabled": True, "settings": settings, "meters": []})
        return token, tenant

    def test_upsert_poll_interval_default_clamp_keep_alias_bad(self):
        _, tenant = self._enroll_enabled()
        self.assertEqual(tenant["settings"]["pollIntervalSeconds"], 3600)  # 缺省 1 小时

        token, _ = self._enroll_enabled(poll=3600)
        self.assertEqual(self.store.load_tenants()[token]["settings"]["pollIntervalSeconds"], 3600)

        tenant = self.store.upsert_config(token, {"settings": {"pollIntervalSeconds": 1}})
        self.assertEqual(tenant["settings"]["pollIntervalSeconds"], mw.MIN_TENANT_POLL_SECONDS)

        tenant = self.store.upsert_config(token, {"settings": {"pollIntervalSeconds": 999999}})
        self.assertEqual(tenant["settings"]["pollIntervalSeconds"], mw.MAX_TENANT_POLL_SECONDS)

        # 旧版 App 报文不带该字段：保留服务端已存值，不被默认覆盖，其余字段正常合并
        tenant = self.store.upsert_config(token, {"settings": {"openId": "ox-keep"}})
        self.assertEqual(tenant["settings"]["pollIntervalSeconds"], mw.MAX_TENANT_POLL_SECONDS)
        self.assertEqual(tenant["settings"]["openId"], "ox-keep")

        # 兼容下划线命名
        tenant = self.store.upsert_config(token, {"settings": {"poll_interval_seconds": 7200}})
        self.assertEqual(tenant["settings"]["pollIntervalSeconds"], 7200)

        # 脏值回退内置默认
        tenant = self.store.upsert_config(token, {"settings": {"pollIntervalSeconds": "abc"}})
        self.assertEqual(tenant["settings"]["pollIntervalSeconds"], 3600)

    def test_tenant_poll_interval_priority_and_global_fallback(self):
        tenant = {"settings": {"pollIntervalSeconds": 7200}}
        self.assertEqual(mw.Engine.tenant_poll_interval({"poll_interval_seconds": 1800}, tenant), 7200)
        # 租户未设置 → 服务器全局
        self.assertEqual(
            mw.Engine.tenant_poll_interval({"poll_interval_seconds": 7200}, {"settings": {}}), 7200)
        self.assertEqual(mw.Engine.tenant_poll_interval({"poll_interval_seconds": 7200}, {}), 7200)
        # 全局也没有 → 内置默认
        self.assertEqual(mw.Engine.tenant_poll_interval({}, {}), 3600)
        # 读取时同样 clamp
        self.assertEqual(
            mw.Engine.tenant_poll_interval({}, {"settings": {"pollIntervalSeconds": 10}}), 3600)

    def test_run_all_only_due_filters_by_tenant_interval(self):
        now = mw.now_ts()
        token_a, _ = self._enroll_enabled(poll=3600)   # A：1 小时
        token_b, _ = self._enroll_enabled(poll=300)    # B：5 分钟（下限档）

        doc = self.store.load_state_doc()
        doc["tenants"][token_a] = mw._new_tenant_state()
        doc["tenants"][token_a]["last_round_at"] = now - 7200   # A 上轮在 2 小时前 → 到期
        doc["tenants"][token_b] = mw._new_tenant_state()
        doc["tenants"][token_b]["last_round_at"] = now          # B 刚跑完 → 未到期
        self.store.save_state_doc(doc)

        ran = []

        def fake_run_tenant(tok, svc, tenant, ts, startup):
            ran.append(tok)
            ts["last_round_at"] = mw.now_ts()

        self.engine.run_tenant = fake_run_tenant  # type: ignore[method-assign]

        self.engine.run_all(startup=False, only_due=True)
        self.assertEqual(ran, [token_a])  # 定时 tick 只跑到期的 A，B 被跳过且不刷新其 last_round

        # 非 only_due（启动首轮 / App 保存唤醒）保持全量逐租户执行
        ran.clear()
        self.engine.run_all(startup=False)
        self.assertEqual(set(ran), {token_a, token_b})

    def test_run_all_only_due_runs_never_ran_tenant(self):
        # 从未成功轮询（last_round_at=0）的启用租户，首个 tick 就应执行，不能被间隔挡住
        token, _ = self._enroll_enabled(poll=3600)
        ran = []
        self.engine.run_tenant = lambda tok, *a, **k: ran.append(tok)  # type: ignore[method-assign]
        self.engine.run_all(startup=False, only_due=True)
        self.assertEqual(ran, [token])

    def test_run_all_only_due_skips_disabled(self):
        token, _ = self._enroll_enabled(poll=3600)
        self.store.upsert_config(token, {"enabled": False})
        ran = []
        self.engine.run_tenant = lambda tok, *a, **k: ran.append(tok)  # type: ignore[method-assign]
        self.engine.run_all(startup=False, only_due=True)
        self.assertEqual(ran, [])


class TestApiFlow(unittest.TestCase):
    def setUp(self):
        CloudHandler._enroll_fails.clear()
        CloudHandler._run_now_last.clear()
        self.tmp = tempfile.TemporaryDirectory()
        atomic = Path(self.tmp.name) / "service.json"
        mw.atomic_write_json(atomic, {**mw.DEFAULT_SERVICE, "enroll_code": "code-123",
                                      "default_bark_keys": []})
        self.store = mw.Store(self.tmp.name)
        self.engine = mw.Engine(self.store, dry_run=True)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), CloudHandler)
        self.port = self.httpd.server_address[1]
        self.httpd.ctx = types.SimpleNamespace(  # type: ignore[attr-defined]
            store=self.store, engine=self.engine, wake=threading.Event(),
            kick_lock=threading.Lock(), kick_tokens=set())
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.port}"

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()
        CloudHandler._enroll_fails.clear()
        CloudHandler._run_now_last.clear()

    def _req(self, method, path, body=None, token=None, raw=None):
        data = None
        headers = {}
        if raw is not None:
            data = raw.encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))

    def test_health_auth_enroll_sync_snapshot(self):
        code, obj = self._req("GET", "/api/meter/health")
        self.assertEqual(code, 200)
        self.assertTrue(obj["ok"])

        code, _ = self._req("GET", "/api/meter/config")
        self.assertEqual(code, 401)

        code, obj = self._req("POST", "/api/meter/enroll", {"code": "wrong"})
        self.assertEqual(code, 403)
        code, obj = self._req("POST", "/api/meter/enroll", {"code": "code-123", "device": "iphone"})
        self.assertEqual(code, 200)
        token = obj["token"]

        code, obj = self._req("GET", "/api/meter/config", token=token)
        self.assertEqual(code, 200)
        self.assertFalse(obj["enabled"])

        code, obj = self._req("PUT", "/api/meter/config", token=token, body={
            "enabled": True,
            "settings": {"openId": "ox-api", "lowThreshold": 50, "lowAlertEnabled": True,
                         "pollIntervalSeconds": 3600},
            "meters": [{"uid": "u1", "room": "1-2334上"}, {"uid": "u2", "room": ""}],
        })
        self.assertEqual(code, 200)
        self.assertEqual(obj["meters"], 2)
        self.assertTrue(self.httpd.ctx.wake.is_set())  # type: ignore[attr-defined]

        saved = self.store.load_tenants()[token]
        self.assertEqual(saved["settings"]["lowThreshold"], 50.0)
        self.assertEqual(saved["settings"]["openId"], "ox-api")
        self.assertEqual(saved["settings"]["pollIntervalSeconds"], 3600)
        self.assertEqual([m["uid"] for m in saved["meters"]], ["u1", "u2"])

        code, obj = self._req("GET", "/api/meter/state", token=token)
        self.assertEqual(code, 200)
        self.assertEqual(len(obj["meters"]), 2)
        self.assertEqual(obj["meters"][0]["room"], "1-2334上")

        code, _ = self._req("GET", "/api/meter/state", token="bad-token")
        self.assertEqual(code, 401)

        code, obj = self._req("PUT", "/api/meter/config", token=token, raw="{not-json")
        self.assertEqual(code, 400)

    def test_run_now_auth_gate_enable_gate_queue_and_throttle(self):
        # 无令牌 401
        code, _ = self._req("POST", "/api/meter/run-now", body={})
        self.assertEqual(code, 401)

        code, obj = self._req("POST", "/api/meter/enroll", {"code": "code-123", "device": "iphone"})
        token = obj["token"]

        # 租户默认未开启云端轮询 → 409，且不唤醒调度
        code, obj = self._req("POST", "/api/meter/run-now", token=token, body={})
        self.assertEqual(code, 409)
        self.assertEqual(obj["error"], "poll_disabled")
        self.assertFalse(self.httpd.ctx.wake.is_set())  # type: ignore[attr-defined]

        # 开启并同步（PUT 本身会 wake，先清掉以便断言 run-now 重新唤醒与定向入队）
        code, _ = self._req("PUT", "/api/meter/config", token=token, body={
            "enabled": True,
            "settings": {"openId": "ox-run-now", "pollIntervalSeconds": 1800},
            "meters": [{"uid": "012334", "room": ""}],
        })
        self.assertEqual(code, 200)
        self.httpd.ctx.wake.clear()  # type: ignore[attr-defined]

        code, obj = self._req("POST", "/api/meter/run-now", token=token, body={})
        self.assertEqual(code, 200)
        self.assertTrue(obj["queued"])
        self.assertTrue(obj["scoped"])
        self.assertTrue(self.httpd.ctx.wake.is_set())  # type: ignore[attr-defined]
        self.assertIn(token, self.httpd.ctx.kick_tokens)  # type: ignore[attr-defined]

        # 10 秒内连点被节流
        code, obj = self._req("POST", "/api/meter/run-now", token=token, body={})
        self.assertEqual(code, 429)
        self.assertEqual(obj["error"], "too_frequent")

    def test_nonstandard_methods_return_json_not_html_501(self):
        # DELETE 非 notify 路径：JSON 405 + Allow，而不是 text/html 501
        try:
            urllib.request.urlopen(
                urllib.request.Request(self.base + "/api/meter/config", method="DELETE"), timeout=5)
            self.fail("DELETE /api/meter/config 应返回 405")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 405)
            obj = json.loads(e.read().decode("utf-8"))
            self.assertEqual(obj["error"], "method_not_allowed")
            self.assertIn("GET", e.headers.get("Allow", ""))

        # PATCH 同样兜底为 JSON 405
        code, obj = self._req("PATCH", "/api/meter/state", body={})
        self.assertEqual(code, 405)
        self.assertEqual(obj["error"], "method_not_allowed")

        # OPTIONS 兜底 204 + Allow（空响应体，单独发原始请求）
        with urllib.request.urlopen(
                urllib.request.Request(self.base + "/api/meter/health", method="OPTIONS"),
                timeout=5) as resp:
            self.assertEqual(resp.status, 204)
            self.assertIn("OPTIONS", resp.headers.get("Allow", ""))

        # notify 前缀：测试 ctx 未装配 hub 时给 JSON 503，而不是裸 HTML 501（生产装配 hub 后正常转发）
        code, obj = self._req("DELETE", "/api/notify/devices/dv_x")
        self.assertEqual(code, 503)
        self.assertEqual(obj["error"], "hub_unavailable")


class _FakeHub:
    """模拟 notify_hub.HubRuntime，记录 dispatch 入参并返回预设结果。"""
    def __init__(self, result):
        self.result = result
        self.calls = []

    def dispatch(self, user_token, module, event_type, title, body,
                 data=None, idem_key=None, level=None, subtitle=""):
        self.calls.append({"user_token": user_token, "module": module, "type": event_type,
                           "title": title, "body": body, "data": data, "subtitle": subtitle})
        return self.result


class TestNotifyHubIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = mw.Store(self.tmp.name)
        self.fake = FakePusher()
        self.engine = mw.Engine(self.store, pusher=self.fake)  # type: ignore[arg-type]
        self.svc = dict(self.store.svc)
        self.store.svc["enroll_code"] = "123456"   # enroll 只读内存 svc，无需落盘

    def tearDown(self):
        self.tmp.cleanup()

    def test_upsert_persists_user_token_and_keeps_on_legacy_payload(self):
        token = self.store.enroll("123456", "iphone")
        self.assertTrue(token)
        self.assertIsNotNone(self.store.upsert_config(token, {"userToken": "nt_abc123"}))
        self.assertEqual(self.store.load_tenants()[token]["notify_user_token"], "nt_abc123")
        # 旧版 App 报文不带 userToken，不能把已建立的推送中心绑定误清
        self.store.upsert_config(token, {"enabled": True})
        self.assertEqual(self.store.load_tenants()[token]["notify_user_token"], "nt_abc123")

    def test_push_uses_hub_without_legacy_fallback(self):
        hub = _FakeHub({"ok": True, "sent": 1, "total": 1})
        self.engine.hub = hub
        tenant = {"notify_user_token": "nt_1", "bark_keys": ["k-legacy"]}
        sent = self.engine._push_tenant(self.svc, tenant, "T", "B",
                                        keys=["k-legacy"], event_type="low")
        self.assertEqual(sent, 1)
        self.assertEqual(len(hub.calls), 1)
        self.assertEqual(hub.calls[0]["user_token"], "nt_1")
        self.assertEqual(hub.calls[0]["module"], "meter")
        self.assertEqual(hub.calls[0]["type"], "low")
        self.assertEqual(self.fake.calls, [])      # hub 已受理，不再直推，避免重复

    def test_push_fallback_when_hub_has_no_device(self):
        hub = _FakeHub({"ok": False, "sent": 0, "total": 0, "reason": "no_device"})
        self.engine.hub = hub
        tenant = {"notify_user_token": "nt_2", "bark_keys": ["k-legacy"]}
        sent = self.engine._push_tenant(self.svc, tenant, "T", "B", keys=["k-legacy"])
        self.assertEqual(sent, 1)                  # FakePusher.push_many 返回 (1,1)
        self.assertEqual(len(self.fake.calls), 1)  # 无设备可投时平滑降级旧直推

    def test_push_user_disabled_does_not_fallback(self):
        hub = _FakeHub({"ok": False, "sent": 0, "total": 0, "reason": "user_disabled"})
        self.engine.hub = hub
        tenant = {"notify_user_token": "nt_3", "bark_keys": ["k-legacy"]}
        sent = self.engine._push_tenant(self.svc, tenant, "T", "B", keys=["k-legacy"])
        self.assertEqual(sent, 0)
        self.assertEqual(self.fake.calls, [])      # 用户主动关通道，禁止全局 key 再打扰

    def test_push_without_hub_keeps_legacy_path(self):
        tenant = {"bark_keys": ["k-legacy"]}
        sent = self.engine._push_tenant(self.svc, tenant, "T", "B", keys=["k-legacy"])
        self.assertEqual(sent, 1)
        self.assertEqual(len(self.fake.calls), 1)


class TestPeriodDedupAndEnrollIdempotent(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = mw.Store(self.tmp.name)
        self.fake = FakePusher()
        self.engine = mw.Engine(self.store, pusher=self.fake)  # type: ignore[arg-type]
        self.store.svc["enroll_code"] = "123456"

    def tearDown(self):
        self.tmp.cleanup()

    def test_within_period_guard(self):
        within = mw.Engine._within_period
        self.assertFalse(within({}, "last_low_push", 1000, 3600))
        self.assertFalse(within({"last_low_push": 500}, "last_low_push", 1000, 0))
        self.assertTrue(within({"last_low_push": 500}, "last_low_push", 1000, 3600))
        self.assertFalse(within({"last_low_push": 500}, "last_low_push", 4200, 3600))

    def _low_meter(self):
        return {"shengyu": 10, "zhuangtai": "合闸"}

    def test_low_alert_only_once_within_period(self):
        svc, tenant = {}, {"bark_keys": ["k1"]}
        m = self._low_meter()
        first = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 1000, period_seconds=3600)
        self.assertEqual(len(first), 1)
        self.assertEqual(m["last_low_push"], 1000)
        # 状态被重置后同一轮询期内再次轮询：周期 guard 抑制，不重复推
        m["low_active"] = False
        second = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 1500, period_seconds=3600)
        self.assertEqual(second, [])
        self.assertEqual(len(self.fake.calls), 1)

    def test_low_alert_again_after_period(self):
        svc, tenant = {}, {"bark_keys": ["k1"]}
        m = self._low_meter()
        self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 1000, period_seconds=3600)
        m["low_active"] = False
        again = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 5000, period_seconds=3600)
        self.assertEqual(len(again), 1)
        self.assertEqual(len(self.fake.calls), 2)

    def test_low_alert_disabled_setting_suppresses_alert_and_recovery(self):
        svc = {"notify_recovery": True}
        tenant = {"bark_keys": ["k1"], "settings": {"lowAlertEnabled": False}}
        m = self._low_meter()
        # 开关关闭：低电量不推告警
        sent = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 1000, period_seconds=3600)
        self.assertEqual(sent, [])
        self.assertEqual(self.fake.calls, [])
        # 开关关闭：已记账低电量回升也不发恢复通知
        m["low_active"] = True
        m["shengyu"] = 40
        sent2 = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 2000, period_seconds=3600)
        self.assertEqual(sent2, [])
        self.assertEqual(self.fake.calls, [])
        self.assertFalse(m["low_active"])  # 状态仍正常翻转，只是不打扰

    def test_low_alert_enabled_by_default(self):
        svc, tenant = {}, {"bark_keys": ["k1"]}
        m = self._low_meter()
        sent = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 1000, period_seconds=3600)
        self.assertEqual(len(sent), 1)
        self.assertEqual(len(self.fake.calls), 1)

    def test_low_active_state_repeats_each_period(self):
        # 持续低电量（low_active 保持 True）：同一轮询期内抑制，超过一个轮询期复提醒一次
        svc, tenant = {}, {"bark_keys": ["k1"]}
        m = self._low_meter()
        self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 1000, period_seconds=3600)
        self.assertTrue(m["low_active"])
        # 未超期：抑制
        self.assertEqual(self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 2000, period_seconds=3600), [])
        self.assertEqual(len(self.fake.calls), 1)
        # 超期：复推
        again = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 5000, period_seconds=3600)
        self.assertEqual(len(again), 1)
        self.assertEqual(len(self.fake.calls), 2)

    def test_off_active_state_repeats_each_period(self):
        # 持续拉闸（off_active 保持 True）：同一轮询期内抑制，超过一个轮询期复提醒一次（与低电量口径一致）
        svc, tenant = {}, {"bark_keys": ["k1"]}
        m = {"shengyu": 10, "zhuangtai": "拉闸"}
        self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 1000, period_seconds=3600)
        self.assertTrue(m["off_active"])
        # 未超期：抑制
        self.assertEqual(self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 2000, period_seconds=3600), [])
        self.assertEqual(len(self.fake.calls), 1)
        # 超期：复推
        again = self.engine.evaluate_meter(svc, tenant, "0123", m, 30, 5000, period_seconds=3600)
        self.assertEqual(len(again), 1)
        self.assertEqual(len(self.fake.calls), 2)

    def test_enroll_idempotent_same_user_and_device(self):
        t1 = self.store.enroll("123456", "iphone", user_token="nt_x")
        t2 = self.store.enroll("123456", "iphone", user_token="nt_x")
        self.assertEqual(t1, t2)
        self.assertEqual(len(self.store.load_tenants()), 1)
        # 同用户不同设备 → 独立租户
        t3 = self.store.enroll("123456", "ipad", user_token="nt_x")
        self.assertNotEqual(t1, t3)
        # 不带 user_token 的旧链路 → 每次新建
        t4 = self.store.enroll("123456", "iphone")
        self.assertNotEqual(t1, t4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
