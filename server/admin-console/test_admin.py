#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""管理后台（admin-console）单测：鉴权会话、电表聚合/控制、房源管理、通知范围、路由。"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "house-keeper"))
sys.path.insert(0, str(HERE.parent / "meter-watch"))
sys.path.insert(0, str(HERE.parent / "notify-hub"))

import admin_auth as aauth          # noqa: E402
import admin_sys as asym            # noqa: E402
import admin_meter as amet          # noqa: E402
import admin_house as ahou          # noqa: E402
import admin_web as aw              # noqa: E402
import house_store as hs            # noqa: E402


# ---------------------------------------------------------------------------
# 假数据源
# ---------------------------------------------------------------------------

class FakeMeterStore:
    def __init__(self, tenants: dict[str, Any], state: dict[str, Any], svc: dict[str, Any]):
        self._tenants = tenants
        self._state = state
        self.svc = svc

    def load_tenants(self) -> dict[str, Any]:
        return self._tenants

    def save_tenants(self, tenants: dict[str, Any]) -> None:
        self._tenants = tenants

    def load_state_doc(self) -> dict[str, Any]:
        return self._state

    def save_service(self, svc: dict[str, Any]) -> None:
        self.svc = svc

    def upsert_config(self, token: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        t = self._tenants.get(token)
        if t is None:
            return None
        if "enabled" in payload:
            t["enabled"] = bool(payload["enabled"])
        s = payload.get("settings")
        if isinstance(s, dict):
            cur = t.setdefault("settings", {})
            cur.update({k: v for k, v in s.items() if v is not None})
        if "meters" in payload:
            t["meters"] = payload["meters"]
        if "notify_user_token" in payload:
            t["notify_user_token"] = payload["notify_user_token"]
        return t


class FakeHubStore:
    def __init__(self, users: dict[str, Any]):
        self._users = users
        self.lock = None

    def doc(self) -> dict[str, Any]:
        return {"users": self._users}

    def get_user(self, token: str) -> dict[str, Any] | None:
        return self._users.get(token)


class FakeHub:
    def __init__(self, users: dict[str, Any]):
        self.store = FakeHubStore(users)
        self.dispatch_calls: list[dict[str, Any]] = []
        self.broadcast_calls: list[dict[str, Any]] = []

    def dispatch(self, user_token, module, event_type, title, body, data=None, **kw):
        self.dispatch_calls.append({"user": user_token, "module": module,
                                    "title": title, "body": body, "data": data})
        return {"ok": True, "sent": 1, "total": 1}

    def broadcast(self, module, event_type, title, body, **kw):
        self.broadcast_calls.append({"module": module, "title": title, "body": body})
        return {"ok": True, "sent": 2, "total": 2, "users": 1}


# ---------------------------------------------------------------------------
# 鉴权
# ---------------------------------------------------------------------------

class AuthTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.auth = aauth.AdminAuth(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_initial_admin_must_change(self) -> None:
        res = self.auth.login("admin", "admin")
        self.assertTrue(res["ok"])
        self.assertTrue(res["mustChange"])
        self.assertEqual(res["username"], "admin")

    def test_wrong_password_rejected(self) -> None:
        self.assertFalse(self.auth.login("admin", "nope")["ok"])

    def test_change_password_clears_flag_and_old_fails(self) -> None:
        login = self.auth.login("admin", "admin")
        token = login["token"]
        res = self.auth.change_password(token, "newpass123")
        self.assertTrue(res["ok"])
        self.assertFalse(self.auth.must_change("admin"))
        self.assertFalse(self.auth.login("admin", "admin")["ok"])
        self.assertTrue(self.auth.login("admin", "newpass123")["ok"])

    def test_empty_password_rejected(self) -> None:
        token = self.auth.login("admin", "admin")["token"]
        res = self.auth.change_password(token, "   ")
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"], "password_required")

    def test_session_verify_and_logout(self) -> None:
        token = self.auth.login("admin", "admin")["token"]
        self.assertEqual(self.auth.verify(token), "admin")
        self.auth.logout(token)
        self.assertIsNone(self.auth.verify(token))


# ---------------------------------------------------------------------------
# 电表值守后台
# ---------------------------------------------------------------------------

class MeterConsoleTests(unittest.TestCase):
    def _build(self) -> tuple[FakeMeterStore, FakeHub, amet.MeterConsole]:
        tenants = {
            "tok_aaaa1111": {
                "enabled": True, "device": "iPhone-甲",
                "created_at": "2026-11-25T01:00:00", "updated_at": "2026-11-25T02:00:00",
                "settings": {"openId": "oid-1", "lowThreshold": 30.0,
                             "lowAlertEnabled": True, "pollIntervalSeconds": 3600},
                "meters": [{"uid": "m1", "room": "2-1006"}, {"uid": "m2", "room": "1-1761"}],
                "bark_keys": ["k1"], "notify_user_token": "hub-u1",
            },
            "tok_bbbb2222": {
                "enabled": False, "device": "iPhone-乙",
                "created_at": "2026-11-25T01:10:00", "updated_at": "2026-11-25T01:10:00",
                "settings": {"openId": "oid-2", "lowThreshold": 25.0,
                             "lowAlertEnabled": False, "pollIntervalSeconds": 1800},
                "meters": [{"uid": "m3", "room": "1-2219"}],
                "bark_keys": [], "notify_user_token": "hub-u2",
            },
        }
        state = {"tenants": {
            "tok_aaaa1111": {"last_round_at": 1000.0, "last_ok_at": 1000.0,
                             "consecutive_failures": 0, "last_error": "",
                             "meters": {"m1": {"shengyu": 15.8, "leiji": 100, "zhuangtai": "正常", "shijian": "02:40"}}},
            "tok_bbbb2222": {"meters": {}},
        }}
        svc = {"enroll_code": "code-init", "enroll_code_rotated_at": 0.0}
        store = FakeMeterStore(tenants, state, svc)
        hub = FakeHub({"hub-u1": {"username": "涛", "devices": [{"bark_key": "k1"}],
                                  "prefs": {"enabled": True, "modules": {"meter": True}}},
                        "hub-u2": {"username": "乙", "devices": [],
                                   "prefs": {"enabled": True, "modules": {"meter": False}}}})
        return store, hub, amet.MeterConsole(store, hub)

    def test_summary_counts(self) -> None:
        _, _, mc = self._build()
        d = mc.tenants()
        s = d["summary"]
        self.assertEqual(s["tenants"], 2)
        self.assertEqual(s["active"], 1)
        self.assertEqual(s["paused"], 1)
        self.assertEqual(s["meters"], 3)
        self.assertEqual(s["pushOk"], 1)
        self.assertEqual(s["pushBad"], 1)

    def test_detail_fields_and_low_flag(self) -> None:
        _, _, mc = self._build()
        t0 = mc.tenants()["tenants"][0]
        self.assertEqual(t0["settings"]["lowThreshold"], 30.0)
        self.assertEqual(t0["settings"]["pollIntervalSeconds"], 3600)
        self.assertEqual(t0["hub"]["username"], "涛")
        self.assertTrue(t0["meters"][0]["low"])  # 15.8 <= 30

    def test_set_enabled(self) -> None:
        store, _, mc = self._build()
        res = mc.set_enabled("tok_bbbb2222", True)
        self.assertTrue(res["ok"])
        self.assertTrue(store.load_tenants()["tok_bbbb2222"]["enabled"])

    def test_update_settings(self) -> None:
        store, _, mc = self._build()
        res = mc.update_settings("tok_aaaa1111", {"lowThreshold": 20.0, "pollIntervalSeconds": 7200})
        self.assertTrue(res["ok"])
        self.assertEqual(store.load_tenants()["tok_aaaa1111"]["settings"]["lowThreshold"], 20.0)

    def test_resolve_token_masked(self) -> None:
        _, _, mc = self._build()
        masked = mc.tenants()["tenants"][0]["token"]
        self.assertEqual(mc.resolve_token(masked), "tok_aaaa1111")

    def test_code_rotate_and_expiry(self) -> None:
        store, _, mc = self._build()
        info = mc.code_info()
        self.assertEqual(info["enrollCode"], "code-init")
        # 把轮换时间置为 25 小时前 -> 惰性自动换新
        store.svc["enroll_code_rotated_at"] = __import__("time").time() - 25 * 3600
        info2 = mc.code_info()
        self.assertNotEqual(info2["enrollCode"], "code-init")
        self.assertGreater(info2["remainingSec"], 0)
        self.assertRegex(info2["enrollCode"], r"^\d{8}$")
        # 手动轮换再次换新
        before = info2["enrollCode"]
        res = mc.rotate_code()
        self.assertTrue(res["ok"])
        self.assertNotEqual(res["enrollCode"], before)
        self.assertRegex(res["enrollCode"], r"^\d{8}$")

    def test_snapshot_export(self) -> None:
        _, _, mc = self._build()
        data, fname = mc.snapshot_export()
        self.assertTrue(fname.startswith("meter-snapshot-"))
        doc = json.loads(data.decode("utf-8"))
        self.assertEqual(doc["summary"]["tenants"], 2)


# ---------------------------------------------------------------------------
# 房源后台
# ---------------------------------------------------------------------------

class HouseConsoleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.store = hs.HouseStore(Path(self.tmp.name) / "house.db")
        self.console = ahou.HouseConsole(self.store)
        self.store.upsert_house({"roomKey": "1-2059", "roomNo": "2059", "tower": 1,
                                  "landlord": "康", "layout": "单间", "price": 1000,
                                  "status": "available"}, operator="t")
        self.store.upsert_house({"roomKey": "2-1006", "roomNo": "1006", "tower": 2,
                                  "landlord": "业主", "layout": "复式", "price": 1300,
                                  "status": "rented"}, operator="t")

    def tearDown(self) -> None:
        self.store.close()
        self.tmp.cleanup()

    def test_list_filters(self) -> None:
        all_h = self.console.list()["houses"]
        self.assertEqual(len(all_h), 2)
        self.assertEqual(len(self.console.list(tower="1")["houses"]), 1)
        self.assertEqual(len(self.console.list(status="rented")["houses"]), 1)
        self.assertEqual(len(self.console.list(q="2059")["houses"]), 1)

    def test_detail_has_ledger(self) -> None:
        doc = self.console.detail("1-2059")
        self.assertIsNotNone(doc)
        self.assertTrue(len(doc["ledger"]) >= 1)

    def test_update_fields(self) -> None:
        res = self.console.update("1-2059", {"price": 1100, "landlord": "康师傅"})
        self.assertTrue(res["ok"])
        doc = self.console.detail("1-2059")
        self.assertEqual(doc["price"], 1100)
        self.assertEqual(doc["landlord"], "康师傅")

    def test_not_found_update(self) -> None:
        res = self.console.update("9-9999", {"price": 1})
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"], "not_found")

    def test_delete_and_restore(self) -> None:
        res = self.console.set_deleted("2-1006", True)
        self.assertTrue(res["ok"])
        self.assertTrue(self.console.detail("2-1006")["isDeleted"])
        res2 = self.console.set_deleted("2-1006", False)
        self.assertTrue(res2["ok"])
        self.assertFalse(self.console.detail("2-1006")["isDeleted"])

    def test_export_json_and_csv(self) -> None:
        jdata, jname = self.console.export_json()
        self.assertTrue(jname.endswith(".json"))
        self.assertIn(b"2059", jdata)
        cdata, cname = self.console.export_csv()
        self.assertTrue(cname.endswith(".csv"))
        self.assertIn("2059", cdata.decode("utf-8-sig"))


# ---------------------------------------------------------------------------
# 通知范围
# ---------------------------------------------------------------------------

class NotifyScopeTests(unittest.TestCase):
    def _admin(self, hub: FakeHub) -> Any:
        return type("A", (), {"hub": hub, "meter": None, "house": None, "auth": None,
                              "sys": None})()

    def test_none_does_not_call(self) -> None:
        hub = FakeHub({})
        res = aw._notify(self._admin(hub), "none", "house", "t", "b")
        self.assertEqual(res["reason"], "not_requested")
        self.assertEqual(hub.dispatch_calls, [])
        self.assertEqual(hub.broadcast_calls, [])

    def test_self_dispatches_to_user(self) -> None:
        hub = FakeHub({"hub-u1": {"username": "涛", "devices": []}})
        res = aw._notify(self._admin(hub), "self", "meter", "t", "b", "hub-u1")
        self.assertEqual(res["reason"], "dispatched")
        self.assertEqual(len(hub.dispatch_calls), 1)
        self.assertEqual(hub.dispatch_calls[0]["user"], "hub-u1")
        self.assertEqual(hub.broadcast_calls, [])

    def test_all_broadcasts(self) -> None:
        hub = FakeHub({})
        res = aw._notify(self._admin(hub), "all", "house", "t", "b")
        self.assertEqual(res["reason"], "broadcast")
        self.assertEqual(len(hub.broadcast_calls), 1)


# ---------------------------------------------------------------------------
# 路由（轻量 fake handler）
# ---------------------------------------------------------------------------

class FakeHandler:
    def __init__(self, path: str, body: dict[str, Any] | None = None, cookie: str = ""):
        import io
        self.path = path
        self._body = body
        raw = json.dumps(body or {}).encode("utf-8")
        self.headers = {"Cookie": cookie, "Content-Type": "application/json",
                        "Content-Length": str(len(raw))}
        self.status = 0
        self.sent: dict[str, Any] = {}
        self.cookies: dict[str, str] = {}
        self._raw = raw
        self._buf = io.BytesIO()

    def send_response(self, code: int) -> None:
        self.status = code

    def send_header(self, k: str, v: str) -> None:
        if k == "Set-Cookie":
            kk, vv = v.split("=", 1)
            self.cookies[kk] = vv.split(";")[0]
        self.sent[k] = v

    def end_headers(self) -> None:
        pass

    @property
    def rfile(self) -> Any:
        import io
        return io.BytesIO(self._raw)

    @property
    def wfile(self) -> Any:
        return self._buf

    def json_body(self) -> dict[str, Any]:
        return json.loads(self._buf.getvalue().decode("utf-8"))


class RouteTests(unittest.TestCase):
    def _admin(self) -> Any:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        auth = aauth.AdminAuth(tmp.name)
        store = hs.HouseStore(Path(tmp.name) / "house.db")
        meter = amet.MeterConsole(FakeMeterStore({}, {"tenants": {}}, {"enroll_code": "x"}),
                                   FakeHub({}))
        house = ahou.HouseConsole(store)
        return type("A", (), {"auth": auth, "sys": asym.SystemBoard(),
                              "meter": meter, "house": house, "hub": FakeHub({})})()

    def test_static_page(self) -> None:
        h = FakeHandler("/admin/")
        self.assertTrue(aw.route_request(h, "GET", "/admin/", self._admin()))
        self.assertEqual(h.status, 200)

    def test_meta_public_when_unauthenticated(self) -> None:
        h = FakeHandler("/admin/api/meta")
        done = aw.route_request(h, "GET", "/admin/api/meta", self._admin())
        self.assertTrue(done)
        self.assertEqual(h.status, 200)
        doc = h.json_body()
        self.assertFalse(doc["authenticated"])
        self.assertIsNone(doc["username"])
        self.assertFalse(doc["mustChange"])

    def test_login_then_meta(self) -> None:
        admin = self._admin()
        h = FakeHandler("/admin/api/login", {"username": "admin", "password": "admin"})
        aw.route_request(h, "POST", "/admin/api/login", admin)
        self.assertEqual(h.status, 200)
        cookie = f"admin_session={h.cookies['admin_session']}"
        h2 = FakeHandler("/admin/api/meta", cookie=cookie)
        aw.route_request(h2, "GET", "/admin/api/meta", admin)
        self.assertEqual(h2.status, 200)
        doc = h2.json_body()
        self.assertTrue(doc["authenticated"])
        self.assertEqual(doc["username"], "admin")
        self.assertTrue(doc["mustChange"])

    def test_non_admin_path_returns_false(self) -> None:
        self.assertFalse(aw.route_request(FakeHandler("/api/meter/health"), "GET",
                                          "/api/meter/health", self._admin()))


if __name__ == "__main__":
    unittest.main()
