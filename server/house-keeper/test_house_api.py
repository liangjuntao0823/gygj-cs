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
                  exclude_device_id="", data=None):
        self.calls.append({"module": module, "action": action,
                           "exclude": exclude_device_id})
        return dict(self._result)


def _item(i):
    return {"id": i, "action": "编辑保存", "title": "t", "body": "b",
            "data": {}, "originDeviceId": "dev_x"}


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
