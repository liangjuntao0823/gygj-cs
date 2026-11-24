"""
migrate_cos.py — 存量 COS 房源一次性迁移到服务器 SQLite。

范围：
- 读取 COS 上所有 h/<room>/info.json（旧 CloudHouseRecord），转换后写入 HouseStore；
- 媒体实体不搬运、不复制，只把媒体名换算成 objectKey 引用（媒体本就继续留在 COS）；
- 幂等：可重复运行，已存在的房按 revision 校准，不产生重复；
- 导入结果输出对账汇总（成功/跳过/失败），供人工核对。

COS 读取（XML API, sha1 签名）与转换逻辑分离，转换核心可独立单测。
"""

from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

# 与客户端 MediaNaming 同口径：视频 .mov -> .mp4
FIELD_KEYS = ["roomNo", "tower", "landlord", "layout", "price",
              "password", "remark", "status"]


def cloud_media_name(file_name: str, kind: str) -> str:
    if kind == "video":
        return file_name.rsplit(".", 1)[0] + ".mp4"
    return file_name


def _infer_kind(media_name: str) -> str:
    return "video" if media_name.lower().endswith((".mp4", ".mov")) else "image"


def record_to_payload(record: dict[str, Any]) -> dict[str, Any]:
    """把旧 info.json（CloudHouseRecord）转成 HouseStore.upsert_house 的 payload。"""
    room_key = str(record["roomKey"])
    media = []
    for name in record.get("mediaNames", []):
        kind = _infer_kind(name)
        cloud_name = cloud_media_name(name, kind)
        media.append({
            "objectKey": f"h/{room_key}/{cloud_name}",
            "fileName": name,
            "kind": kind,
        })
    payload: dict[str, Any] = {"media": media}
    for k in FIELD_KEYS:
        if k in record:
            payload[k] = record[k]
    payload["roomKey"] = room_key
    return payload


class CosXMLClient:
    """最小 COS XML API 客户端（sha1 签名），只实现 list 与 get。"""

    def __init__(self, secret_id: str, secret_key: str, bucket: str,
                 region: str, host: str | None = None):
        self.secret_id = secret_id
        self.secret_key = secret_key
        self.bucket = bucket
        self.region = region
        self.host = host or f"{bucket}.cos.{region}.myqcloud.com"

    def _sign(self, key_time: str, method: str, path: str,
              headers: dict[str, str]) -> str:
        sign_time = key_time
        # 只签 host
        header_list = "host"
        http_string = f"{method.lower()}\n{path}\n\nhost={self.host}\n"
        string_to_sign = "sha1\n" + sign_time + "\n" + hashlib.sha1(
            http_string.encode("utf-8")).hexdigest() + "\n"
        sign_key = hmac.new(
            self.secret_key.encode("utf-8"), key_time.encode("utf-8"),
            hashlib.sha1).hexdigest()
        signature = hmac.new(
            sign_key.encode("utf-8"), string_to_sign.encode("utf-8"),
            hashlib.sha1).hexdigest()
        return (
            "q-sign-algorithm=sha1"
            f"&q-ak={self.secret_id}"
            f"&q-sign-time={sign_time}"
            f"&q-key-time={key_time}"
            f"&q-header-list={header_list}"
            "&q-url-param-list="
            f"&q-signature={signature}"
        )

    def _request(self, method: str, path: str,
                 query: str = "") -> bytes:
        now = int(time.time())
        key_time = f"{now - 60};{now + 600}"
        url = f"https://{self.host}{path}"
        if query:
            url += "?" + query
        auth = self._sign(key_time, method, path, {})
        req = urllib.request.Request(
            url, headers={"Authorization": auth, "Host": self.host},
            method=method)
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.read()

    def list_info_keys(self) -> list[str]:
        keys: list[str] = []
        marker = ""
        while True:
            q = "list-type=2&prefix=h/&max-keys=1000"
            if marker:
                q += "&continuation-token=" + urllib.parse.quote(marker)
            import xml.etree.ElementTree as ET
            root = ET.fromstring(self._request("GET", "/", q))
            ns = "{http://s3.amazonaws.com/doc/2006-03-01/}"
            for c in root.findall(f"{ns}Contents"):
                k = c.find(f"{ns}Key").text
                if k and k.endswith("/info.json"):
                    keys.append(k)
            if root.findtext(f"{ns}IsTruncated") == "true":
                marker = root.findtext(f"{ns}NextContinuationToken") or ""
            else:
                break
        return keys

    def get_object(self, key: str) -> bytes:
        path = "/" + urllib.parse.quote(key)
        return self._request("GET", path)


def run_migration(store: Any, client: CosXMLClient,
                  logger: Callable[[str], None] = print) -> dict[str, int]:
    """拉取全部 info.json 并导入 SQLite，返回对账计数。"""
    keys = client.list_info_keys()
    result = {"total": len(keys), "imported": 0, "skipped": 0, "failed": 0}
    for key in keys:
        try:
            record = json.loads(client.get_object(key).decode("utf-8"))
            payload = record_to_payload(record)
            operator = str(record.get("updatedBy") or "迁移")
            store.upsert_house(payload, operator=operator,
                               origin_device_id="migration")
            result["imported"] += 1
            logger(f"导入 {payload['roomKey']}")
        except Exception as e:  # 单套失败不阻断其余，最后统一核对
            result["failed"] += 1
            logger(f"失败 {key}: {e}")
    return result


def _main(argv: list[str] | None = None) -> int:
    import argparse
    import os
    import sys

    p = argparse.ArgumentParser(description="存量 COS 房源一次性迁移到服务器 SQLite")
    p.add_argument("--db", default=os.environ.get("HOUSE_DB", "/opt/meter-watch/house.db"),
                   help="房源 SQLite 路径（默认 HOUSE_DB 或 /opt/meter-watch/house.db）")
    args = p.parse_args(argv)

    secret_id = os.environ.get("COS_SECRET_ID", "")
    secret_key = os.environ.get("COS_SECRET_KEY", "")
    app_id = os.environ.get("COS_APP_ID", "")
    bucket = os.environ.get("COS_BUCKET", "")
    region = os.environ.get("COS_REGION", "")
    missing = [k for k, v in (
        ("COS_SECRET_ID", secret_id), ("COS_SECRET_KEY", secret_key),
        ("COS_APP_ID", app_id), ("COS_BUCKET", bucket), ("COS_REGION", region)) if not v]
    if missing:
        print("缺少环境变量: " + ", ".join(missing))
        return 2

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import house_store as hs

    store = hs.HouseStore(args.db)
    client = CosXMLClient(secret_id, secret_key, bucket, region)
    result = run_migration(store, client)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
