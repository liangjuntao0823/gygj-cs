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


if __name__ == "__main__":
    unittest.main()
