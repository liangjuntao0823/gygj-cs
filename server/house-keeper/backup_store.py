#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 备份 zip 本地磁盘存储（backup_store）
==============================================
全新架构（2026-11-26）：放弃 COS 桶，备份 zip 实体全部落服务器本地磁盘，
HTTP 直传 / 直出下载 / 删除。替代旧桶 backups/<用户>/ 目录与 ListObjects 清单。

目录约定（相对 root）：
  owners/<owner>/<name>.zip        备份 zip 本体
  owners/<owner>/<name>.zip.meta.json  备份元数据（size / date / isAuto）

功能口径对齐旧 CloudBackupService（只换存储，不丢功能）：
  · 按 owner 隔离目录（当前单库固定 default；阶段 D 可按令牌隔离）
  · 清单条目保留 name / size / date / isAuto 字段
  · 文件名清洗，拒绝路径穿越；仅接受 .zip 落盘
  · 自动备份保留最近 10 份的裁剪仍由客户端执行（与旧设计一致），本模块只存取。
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any


def _clean_segment(value: str) -> str:
    if value is None:
        return ""
    s = str(value).strip().replace("\\", "/")
    parts = [p for p in s.split("/") if p not in ("", ".", "..")]
    s = "-".join(parts)
    return re.sub(r'[\x00-\x1f<>:"|?*]', "", s)


def _clean_file_name(name: str) -> str:
    n = str(name).replace("\\", "/").rsplit("/", 1)[-1].strip()
    return re.sub(r'[\x00-\x1f<>:"|?*/]', "", n)


class BackupStore:
    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    # ---- 路径解析 ----
    def _owner_dir(self, owner: str) -> Path:
        seg = _clean_segment(owner) or "default"
        return self.root / "owners" / seg

    def _zip_path(self, owner: str, name: str) -> Path | None:
        fn = _clean_file_name(name)
        if not fn.lower().endswith(".zip"):
            return None
        target = (self._owner_dir(owner) / fn).resolve()
        try:
            target.relative_to(self._owner_dir(owner).resolve())
        except ValueError:
            return None
        return target

    @staticmethod
    def _meta_path(zip_path: Path) -> Path:
        return zip_path.with_name(zip_path.name + ".meta.json")

    # ---- 存取 ----
    def save(self, owner: str, name: str, data: bytes, is_auto: bool) -> dict[str, Any]:
        fn = _clean_file_name(name)
        if not fn.lower().endswith(".zip"):
            raise ValueError("unsupported backup extension")
        path = self._zip_path(owner, fn)
        if path is None:
            raise ValueError("invalid backup path")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        record = {
            "name": fn,
            "size": len(data),
            "date": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
            "isAuto": bool(is_auto),
        }
        self._meta_path(path).write_text(
            json.dumps(record, ensure_ascii=False), encoding="utf-8")
        return record

    def list_backups(self, owner: str) -> list[dict[str, Any]]:
        d = self._owner_dir(owner)
        if not d.is_dir():
            return []
        records: list[dict[str, Any]] = []
        for path in d.glob("*.zip"):
            meta = self._meta_path(path)
            record: dict[str, Any]
            if meta.is_file():
                try:
                    record = json.loads(meta.read_text(encoding="utf-8"))
                except Exception:
                    record = {}
            else:
                record = {}
            record.setdefault("name", path.name)
            record.setdefault("size", path.stat().st_size if path.exists() else 0)
            record.setdefault("date", time.strftime(
                "%Y-%m-%dT%H:%M:%S%z", time.localtime(path.stat().st_mtime)))
            record.setdefault("isAuto", path.name.count("_自动") > 0)
            records.append(record)
        records.sort(key=lambda r: str(r.get("date", "")), reverse=True)
        return records

    def read(self, owner: str, name: str) -> bytes | None:
        path = self._zip_path(owner, name)
        if path is None or not path.is_file():
            return None
        return path.read_bytes()

    def delete(self, owner: str, name: str) -> bool:
        path = self._zip_path(owner, name)
        if path is None or not path.is_file():
            return False
        try:
            path.unlink()
            meta = self._meta_path(path)
            if meta.is_file():
                meta.unlink()
            return True
        except FileNotFoundError:
            return False
