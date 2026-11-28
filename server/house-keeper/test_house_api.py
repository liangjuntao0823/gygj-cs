import threading
import unittest

import house_api


class FakeStore:
    def __init__(self, items):
        self._items = items
        self.marked = []

    def pending_outbox(self, limit=50):
        return list(self._items)

    def mark_outbox(self, outbox_id, status="sent"):
        self.marked.append((outbox_id, status))


class FakeHub:
    def __init__(self, result):
        self._result = result
        self.calls = []

    def broadcast(self, module, action, title, body,
                  exclude_device_id="", data=None, exclude_source_device_id=""):
        self.calls.append({"kind": "broadcast", "module": module, "action": action,
                           "exclude": exclude_device_id,
                           "exclude_source": exclude_source_device_id, "data": data})
        return dict(self._result)

    def dispatch(self, user_token, module, event_type, title, body,
                 data=None, idem_key=None, level=None, subtitle="",
                 exclude_device_id="", exclude_source_device_id=""):
        self.calls.append({"kind": "dispatch", "user": user_token, "module": module,
                           "type": event_type, "data": data,
                           "exclude": exclude_device_id,
                           "exclude_source": exclude_source_device_id})
        return dict(self._result)


def _item(i, scope="all", token=""):
    return {"id": i, "action": "编辑保存", "title": "t", "body": "b",
            "data": {"notifyScope": scope, "notifyUserToken": token},
            "originDeviceId": "dev_x"}


class DeliverPendingTests(unittest.TestCase):
    def test_success_marks_sent(self):
        store = FakeStore([_item(1)])
        hub = FakeHub({"ok": True, "sent": 2, "total": 2})
        house_api.deliver_pending(store, hub)
        self.assertEqual(store.marked, [(1, "sent")])

    def test_no_device_marks_sent(self):
        store = FakeStore([_item(2)])
        hub = FakeHub({"ok": False, "sent": 0, "total": 0})
        house_api.deliver_pending(store, hub)
        self.assertEqual(store.marked, [(2, "sent")])

    def test_all_failure_keeps_pending(self):
        store = FakeStore([_item(3)])
        hub = FakeHub({"ok": False, "sent": 0, "total": 2})
        house_api.deliver_pending(store, hub)
        self.assertEqual(store.marked, [])  # 不标记，等下轮重试

    def test_none_hub_is_noop(self):
        store = FakeStore([_item(4)])
        house_api.deliver_pending(store, None)
        self.assertEqual(store.marked, [])

    def test_none_scope_skips(self):
        store = FakeStore([_item(5, scope="none")])
        hub = FakeHub({"ok": True, "sent": 1, "total": 1})
        house_api.deliver_pending(store, hub)
        self.assertEqual(store.marked, [(5, "skipped")])
        self.assertEqual(hub.calls, [])

    def test_self_scope_dispatches_only_target(self):
        store = FakeStore([_item(6, scope="self", token="nt_target")])
        hub = FakeHub({"ok": True, "sent": 1, "total": 1})
        house_api.deliver_pending(store, hub)
        self.assertEqual(store.marked, [(6, "sent")])
        self.assertEqual(len(hub.calls), 1)
        self.assertEqual(hub.calls[0]["kind"], "dispatch")
        self.assertEqual(hub.calls[0]["user"], "nt_target")
        self.assertEqual(hub.calls[0]["exclude_source"], "dev_x")
        self.assertNotIn("notifyScope", hub.calls[0]["data"])
        self.assertNotIn("notifyUserToken", hub.calls[0]["data"])

    def test_self_scope_without_target_fails(self):
        store = FakeStore([_item(7, scope="self")])
        hub = FakeHub({"ok": True, "sent": 1, "total": 1})
        house_api.deliver_pending(store, hub)
        self.assertEqual(store.marked, [(7, "failed")])
        self.assertEqual(hub.calls, [])


class SlowStore(FakeStore):
    def __init__(self, items):
        super().__init__(items)
        self.started = threading.Event()
        self.release = threading.Event()

    def pending_outbox(self, limit=50):
        self.started.set()
        self.release.wait(timeout=1.0)
        return super().pending_outbox(limit)


class SingleFlightTests(unittest.TestCase):
    def test_two_callers_do_not_duplicate_same_outbox(self):
        store = SlowStore([_item(8)])
        hub = FakeHub({"ok": True, "sent": 1, "total": 1})
        t = threading.Thread(target=house_api.deliver_pending, args=(store, hub))
        t.start()
        self.assertTrue(store.started.wait(timeout=1.0))
        # 第一个投递者卡在 pending_outbox 查询里，第二个调用应直接返回
        house_api.deliver_pending(store, hub)
        store.release.set()
        t.join(timeout=2.0)
        self.assertEqual(store.marked, [(8, "sent")])
        self.assertEqual(len(hub.calls), 1)


class FakeAuthHandler:
    def __init__(self, tenant):
        self._tenant = tenant
        self.sent = []
        self.headers = {}

    def _require_auth(self):
        if self._tenant is None:
            self.sent.append((401, {"ok": False, "error": "unauthorized"}))
            return None
        return ("tok", self._tenant)

    def _send(self, obj, code):
        self.sent.append((code, obj))


class StatsStore:
    def stats(self):
        return {"total": 1}


class HouseAuthTests(unittest.TestCase):
    def test_forbidden_when_no_house_access(self):
        h = FakeAuthHandler({"house_access": False})
        done = house_api.route_request(h, "GET", "/api/house/stats", StatsStore(), None)
        self.assertTrue(done)
        self.assertEqual(h.sent[0][0], 403)
        self.assertEqual(h.sent[0][1]["error"], "forbidden")

    def test_allowed_when_default_authorized(self):
        h = FakeAuthHandler({"enabled": True})
        done = house_api.route_request(h, "GET", "/api/house/stats", StatsStore(), None)
        self.assertTrue(done)
        self.assertEqual(h.sent[0][0], 200)

    def test_unauthorized_returns_401(self):
        h = FakeAuthHandler(None)
        done = house_api.route_request(h, "GET", "/api/house/stats", StatsStore(), None)
        self.assertTrue(done)
        self.assertEqual(h.sent[0][0], 401)


if __name__ == "__main__":
    unittest.main()
