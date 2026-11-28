#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分享链接签名与有效期。

- HMAC-SHA256 签名，密钥持久化在 data_dir/share_secret（0600），重启不失效；
- token payload: {"sid": 记录ID, "exp": 过期时间戳, "n": 随机串}
- 校验只做签名/过期；记录状态（revoked/kind）由 HouseStore 查库判断。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from pathlib import Path


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


class ShareSigner:
    def __init__(self, secret_path: str | Path):
        self.path = Path(secret_path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.is_file():
            self.path.write_bytes(secrets.token_bytes(48))
            try:
                os.chmod(self.path, 0o600)
            except OSError:
                pass
        self.secret = self.path.read_bytes()

    def sign(self, sid: int, expires_at: int) -> str:
        payload = {"sid": int(sid), "exp": int(expires_at),
                   "n": secrets.token_urlsafe(6)}
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        body = _b64(raw)
        sig = _b64(hmac.new(self.secret, body.encode("ascii"), hashlib.sha256).digest())
        return body + "." + sig

    def verify(self, token: str) -> dict | None:
        try:
            body, sig = str(token or "").split(".", 1)
            expect = _b64(hmac.new(self.secret, body.encode("ascii"), hashlib.sha256).digest())
            if not hmac.compare_digest(sig, expect):
                return None
            payload = json.loads(_unb64(body).decode("utf-8"))
            if not isinstance(payload, dict):
                return None
            if int(payload.get("exp") or 0) < int(time.time()):
                return None
            if not int(payload.get("sid") or 0):
                return None
            return payload
        except Exception:
            return None

    def expires(self, days: int) -> int:
        return int(time.time()) + max(0, int(days)) * 86400
