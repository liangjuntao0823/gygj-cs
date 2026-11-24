#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 管理后台鉴权（admin-console）
=========================================
- 管理员账号存 admin.json（600，与租户/通知文件同目录），密码用 PBKDF2-HMAC-SHA256
  加盐哈希落盘，绝不存明文；会话 token 仅存内存，不落文件。
- 初始账号 admin / admin，首次登录后强制改密（mustChange=true）。
- 密码规则不设复杂度限制：新密码只需非空字符串（按需求口径）。
- 纯 Python 标准库，无第三方依赖。

会话：内存 dict，Cookie `admin_session`；默认有效期 12 小时，登录/改密后刷新。
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from pathlib import Path
from typing import Any

SESSION_TTL_SEC = 12 * 3600
PBKDF2_ROUNDS = 100_000
INITIAL_USERNAME = "admin"
INITIAL_PASSWORD = "admin"


def _atomic_write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _read_json(path: Path, default: Any) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except Exception:
        return default


def _hash_password(password: str, salt: str) -> str:
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                              salt.encode("utf-8"), PBKDF2_ROUNDS)
    return dk.hex()


class AdminAuth:
    def __init__(self, home: str | Path):
        self.home = Path(home)
        self.home.mkdir(parents=True, exist_ok=True)
        self.path = self.home / "admin.json"
        self._lock = threading.RLock()
        # 会话仅内存：token -> {"username": str, "expires": float}
        self._sessions: dict[str, dict[str, Any]] = {}
        self._ensure_default()

    # ---- 账号落盘 ----
    def _doc(self) -> dict[str, Any]:
        d = _read_json(self.path, None)
        if not isinstance(d, dict) or not isinstance(d.get("users"), dict):
            d = {"version": 1, "users": {}}
        return d

    def _save(self, d: dict[str, Any]) -> None:
        _atomic_write_json(self.path, d)

    def _ensure_default(self) -> None:
        with self._lock:
            d = self._doc()
            users = d["users"]
            if INITIAL_USERNAME not in users:
                salt = secrets.token_hex(16)
                users[INITIAL_USERNAME] = {
                    "salt": salt,
                    "hash": _hash_password(INITIAL_PASSWORD, salt),
                    "mustChange": True,
                    "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "lastLogin": "",
                    "loginCount": 0,
                }
                self._save(d)

    def _user(self, username: str) -> dict[str, Any] | None:
        d = self._doc()
        rec = d["users"].get(username)
        return rec if isinstance(rec, dict) else None

    # ---- 会话 ----
    def login(self, username: str, password: str) -> dict[str, Any]:
        username = str(username or "").strip()
        password = str(password or "")
        with self._lock:
            rec = self._user(username)
            if rec is None:
                return {"ok": False, "error": "invalid_credentials"}
            expect = str(rec.get("hash") or "")
            actual = _hash_password(password, str(rec.get("salt") or ""))
            if not hmac.compare_digest(expect, actual):
                return {"ok": False, "error": "invalid_credentials"}
            token = secrets.token_urlsafe(32)
            now = time.time()
            self._sessions[token] = {"username": username, "expires": now + SESSION_TTL_SEC}
            rec["lastLogin"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            rec["loginCount"] = int(rec.get("loginCount") or 0) + 1
            self._save(self._doc())
            return {"ok": True, "token": token,
                    "mustChange": bool(rec.get("mustChange")), "username": username}

    def verify(self, session_token: str | None) -> str | None:
        if not session_token:
            return None
        with self._lock:
            sess = self._sessions.get(session_token)
            if not sess:
                return None
            if sess["expires"] < time.time():
                self._sessions.pop(session_token, None)
                return None
            return sess["username"]

    def must_change(self, username: str) -> bool:
        rec = self._user(username)
        return bool(rec and rec.get("mustChange"))

    def change_password(self, session_token: str, new_password: str) -> dict[str, Any]:
        username = self.verify(session_token)
        if not username:
            return {"ok": False, "error": "unauthorized"}
        new_password = str(new_password or "").strip()
        if not new_password:
            return {"ok": False, "error": "password_required"}
        with self._lock:
            d = self._doc()
            rec = d["users"].get(username)
            if not isinstance(rec, dict):
                return {"ok": False, "error": "unauthorized"}
            salt = secrets.token_hex(16)
            rec["salt"] = salt
            rec["hash"] = _hash_password(new_password, salt)
            rec["mustChange"] = False
            self._save(d)
            # 改密后保留当前会话（也可选择失效重建；这里保留，避免反复登录）
            sess = self._sessions.get(session_token)
            if sess:
                sess["expires"] = time.time() + SESSION_TTL_SEC
            return {"ok": True, "username": username}

    def logout(self, session_token: str | None) -> None:
        if not session_token:
            return
        with self._lock:
            self._sessions.pop(session_token, None)

    def reset_default(self) -> None:
        """调试/兜底：把 admin 重置回初始口令并强制改密。生产不主动调用。"""
        with self._lock:
            d = self._doc()
            salt = secrets.token_hex(16)
            d["users"][INITIAL_USERNAME] = {
                "salt": salt,
                "hash": _hash_password(INITIAL_PASSWORD, salt),
                "mustChange": True,
                "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "lastLogin": "",
                "loginCount": 0,
            }
            self._save(d)
            self._sessions.clear()
