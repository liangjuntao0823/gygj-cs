"""
cos_sts.py — 服务器签发 COS 临时（时效）凭证。

设计：
- 永久 SecretId/SecretKey 只保存在服务器（配置文件 600 或环境变量），永不进 App；
- 客户端按需调用本模块拿到临时凭证，默认 1800 秒（30 分钟）过期；
- 策略最小权限：只允许访问房源媒体前缀 h/，且只给读写对象所需动作；
- 凭证可随时在服务器侧吊销/轮换，泄露面小、爆炸半径有限。

纯标准库实现（urllib + hmac + hashlib），无第三方依赖。
"""

from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import os
import time
import urllib.request
from typing import Any

STS_HOST = "sts.tencentcloudapi.com"
STS_ENDPOINT = "https://sts.tencentcloudapi.com"
STS_SERVICE = "sts"
DEFAULT_TTL = 1800
# 房源媒体所需的最小动作集
MEDIA_ACTIONS = [
    "name/cos:PutObject",
    "name/cos:GetObject",
    "name/cos:HeadObject",
    "name/cos:DeleteObject",
    "name/cos:PostObject",
    "name/cos:InitiateMultipartUpload",
    "name/cos:ListMultipartUploads",
    "name/cos:ListParts",
    "name/cos:UploadPart",
    "name/cos:CompleteMultipartUpload",
    "name/cos:AbortMultipartUpload",
]


class CosConfigError(RuntimeError):
    pass


def load_cos_config() -> dict[str, str]:
    """从环境变量读取永久配置；部署时也可由 systemd EnvironmentFile 注入。"""
    keys = {
        "secretId": os.environ.get("COS_SECRET_ID", ""),
        "secretKey": os.environ.get("COS_SECRET_KEY", ""),
        "appId": os.environ.get("COS_APP_ID", ""),
        "bucket": os.environ.get("COS_BUCKET", ""),
        "region": os.environ.get("COS_REGION", ""),
    }
    missing = [k for k, v in keys.items() if not v]
    if missing:
        raise CosConfigError(f"缺少 COS 永久配置：{', '.join(missing)}")
    return keys


def _build_policy(conf: dict[str, str], prefix: str) -> dict[str, Any]:
    # 资源：限定到桶内指定前缀（房源媒体 h/）
    resource = f"qcs::cos:{conf['appId']}:{conf['bucket']}/{prefix}*"
    statement = {
        "effect": "allow",
        "action": MEDIA_ACTIONS,
        "resource": resource,
    }
    return {"version": "2.0", "statement": [statement]}


def _tc3_signature(secret_key: str, date: str, service: str,
                   string_to_sign: str) -> str:
    def _hmac(key: bytes, msg: str) -> bytes:
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    secret_date = _hmac(("TC3" + secret_key).encode("utf-8"), date)
    secret_service = _hmac(secret_date, service)
    secret_signing = _hmac(secret_service, "tc3_request")
    return hmac.new(secret_signing, string_to_sign.encode("utf-8"),
                    hashlib.sha256).hexdigest()


def _authorization(conf: dict[str, str], payload: str, timestamp: int,
                   host: str) -> str:
    date = datetime.datetime.fromtimestamp(
        timestamp, datetime.timezone.utc).strftime("%Y-%m-%d")
    # 1. 规范请求
    http_method = "POST"
    canonical_uri = "/"
    canonical_query = ""
    canonical_headers = (
        f"content-type:application/json; charset=utf-8\n"
        f"host:{host}\n"
        f"x-tc-action:getfederationtoken\n"
    )
    signed_headers = "content-type;host;x-tc-action"
    hashed_payload = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    canonical_request = "\n".join([
        http_method, canonical_uri, canonical_query,
        canonical_headers, signed_headers, hashed_payload,
    ])
    # 2. 待签名字符串
    algorithm = "TC3-HMAC-SHA256"
    credential_scope = f"{date}/{STS_SERVICE}/tc3_request"
    hashed_canonical = hashlib.sha256(
        canonical_request.encode("utf-8")).hexdigest()
    string_to_sign = "\n".join(
        [algorithm, str(timestamp), credential_scope, hashed_canonical])
    # 3. 签名
    signature = _tc3_signature(conf["secretKey"], date, STS_SERVICE,
                               string_to_sign)
    # 4. Authorization
    return (
        f"{algorithm} Credential={conf['secretId']}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )


def fetch_credentials(conf: dict[str, str] | None = None,
                      duration_seconds: int = DEFAULT_TTL,
                      prefix: str = "h/",
                      name: str = "house-media") -> dict[str, Any]:
    """调腾讯云 STS GetFederationToken，返回临时凭证字典。"""
    conf = conf or load_cos_config()
    timestamp = int(time.time())
    policy = _build_policy(conf, prefix)
    request_payload = json.dumps({
        "Name": name,
        "Policy": json.dumps(policy, ensure_ascii=False),
        "DurationSeconds": duration_seconds,
    })
    authorization = _authorization(conf, request_payload, timestamp, STS_HOST)
    headers = {
        "Authorization": authorization,
        "Content-Type": "application/json; charset=utf-8",
        "Host": STS_HOST,
        "X-TC-Action": "GetFederationToken",
        "X-TC-Version": "2018-08-13",
        "X-TC-Timestamp": str(timestamp),
    }
    req = urllib.request.Request(
        STS_ENDPOINT, data=request_payload.encode("utf-8"),
        headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    if "Response" not in body or "Error" in body.get("Response", {}):
        err = body.get("Response", {}).get("Error", {})
        raise CosConfigError(f"STS 请求失败：{err.get('Message', body)}")
    return body["Response"]


def credentials_for_client(conf: dict[str, str] | None = None,
                           duration_seconds: int = DEFAULT_TTL,
                           prefix: str = "h/") -> dict[str, Any]:
    """整理成客户端直接可用的临时凭证结构（含桶/区域/过期时间）。"""
    resp = fetch_credentials(conf=conf, duration_seconds=duration_seconds,
                             prefix=prefix)
    creds = resp["Credentials"]
    return {
        "ok": True,
        "credentials": {
            "secretId": creds["TmpSecretId"],
            "secretKey": creds["TmpSecretKey"],
            "token": creds["Token"],
            "expiredTime": resp["ExpiredTime"],
        },
        "bucket": (conf or load_cos_config())["bucket"],
        "region": (conf or load_cos_config())["region"],
        "prefix": prefix,
    }
