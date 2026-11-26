#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""备份磁盘存储单测：BackupStore 存取 / 清单 / 隔离 / 清洗 / 扩展名白名单。"""

import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import backup_store as bs_mod  # noqa: E402
import house_store as hs_mod  # noqa: E402


class BackupStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = bs_mod.BackupStore(Path(self.tmp.name) / "backups")

    def tearDown(self):
        self.tmp.cleanup()

    def test_save_list_read_delete(self):
        rec = self.store.save("default", "快速_a_自动.zip", b"zip-bytes", is_auto=True)
        self.assertEqual(rec["name"], "快速_a_自动.zip")
        self.assertEqual(rec["size"], 9)
        self.assertTrue(rec["isAuto"])

        records = self.store.list_backups("default")
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["name"], "快速_a_自动.zip")
        self.assertTrue(records[0]["isAuto"])

        self.assertEqual(self.store.read("default", "快速_a_自动.zip"), b"zip-bytes")
        self.assertTrue(self.store.delete("default", "快速_a_自动.zip"))
        self.assertIsNone(self.store.read("default", "快速_a_自动.zip"))
        self.assertEqual(self.store.list_backups("default"), [])

    def test_manual_backup_not_auto(self):
        self.store.save("default", "全量_b.zip", b"manual", is_auto=False)
        rec = self.store.list_backups("default")[0]
        self.assertFalse(rec["isAuto"])

    def test_owner_isolation(self):
        self.store.save("default", "a.zip", b"a", is_auto=False)
        self.store.save("other", "b.zip", b"b", is_auto=False)
        self.assertEqual([r["name"] for r in self.store.list_backups("default")], ["a.zip"])
        self.assertEqual([r["name"] for r in self.store.list_backups("other")], ["b.zip"])
        self.assertIsNone(self.store.read("other", "a.zip"))

    def test_reject_traversal_and_bad_ext(self):
        # 穿越片段被清洗为安全单段文件名，不会落到 root 之外（与 MediaStore 口径一致）
        rec = self.store.save("default", "../evil.zip", b"x", is_auto=False)
        self.assertNotIn("..", rec["name"])
        path = self.store._zip_path("default", rec["name"])
        self.assertTrue(path.resolve().is_relative_to(self.store.root.resolve()))
        # 非 zip 扩展名拒绝落盘
        with self.assertRaises(ValueError):
            self.store.save("default", "evil.exe", b"x", is_auto=False)
        self.assertEqual([r["name"] for r in self.store.list_backups("default")],
                         [rec["name"]])

    def test_missing_meta_falls_back_to_file_stat(self):
        d = self.store._owner_dir("default")
        d.mkdir(parents=True, exist_ok=True)
        (d / "快速_c_自动.zip").write_bytes(b"cc")
        records = self.store.list_backups("default")
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["size"], 2)
        self.assertTrue(records[0]["isAuto"])  # 文件名含 _自动 兜底判定

    def test_delete_missing_returns_false(self):
        self.assertFalse(self.store.delete("default", "nope.zip"))


class HouseStoreBackupMountTests(unittest.TestCase):
    def test_backups_attached_to_house_store(self):
        tmp = tempfile.TemporaryDirectory()
        try:
            db = Path(tmp.name) / "house.db"
            store = hs_mod.HouseStore(db, backup_root=Path(tmp.name) / "backups")
            store.backups.save("default", "x.zip", b"xx", is_auto=False)
            self.assertEqual(store.backups.read("default", "x.zip"), b"xx")
            store.close()
        finally:
            tmp.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
