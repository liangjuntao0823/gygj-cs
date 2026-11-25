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
from datetime import timezone, timedelta
from pathlib import Path
from typing import Any, Callable

# 服务器统一东八区时间，与 house_store.now_local 口径一致
_CST = timezone(timedelta(hours=8))

# 与客户端 MediaNaming 同口径：视频 .mov -> .mp4
FIELD_KEYS = ["roomNo", "tower", "landlord", "layout", "price",
              "password", "remark", "status"]


def cloud_media_name(file_name: str, kind: str) -> str:
    if kind == "video":
        return file_name.rsplit(".", 1)[0] + ".mp4"
    return file_name


def _infer_kind(media_name: str) -> str:
    return "video" if media_name.lower().endswith((".mp4", ".mov")) else "image"


def _epoch_to_iso(value: Any) -> str | None:
    """旧记录 updatedAt/date 是 epoch 秒（float），转东八区 ISO8601；无效返回 None。"""
    try:
        ts = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    if ts <= 0:
        return None
    return datetime.datetime.fromtimestamp(ts, tz=_CST).strftime(
        "%Y-%m-%dT%H:%M:%S+08:00")


def record_to_payload(record: dict[str, Any]) -> dict[str, Any]:
    """把旧 info.json（CloudHouseRecord）转成 HouseStore.import_house 的 payload。"""
    room_key = str(record["roomKey"])
    media: list[dict[str, Any]] = []
    seen: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for name in record.get("mediaNames", []):
        kind = _infer_kind(name)
        cloud_name = cloud_media_name(name, kind)
        object_key = f"h/{room_key}/{cloud_name}"
        item = {"objectKey": object_key, "fileName": name, "kind": kind}
        if object_key in seen:
            # 旧记录可能 mov 与转码后 mp4 同名残留；同实体优先保留 .mp4 文件名
            if name.lower().endswith(".mp4"):
                seen[object_key] = item
            continue
        seen[object_key] = item
        order.append(object_key)
    media = [seen[k] for k in order]
    payload: dict[str, Any] = {"media": media}
    for k in FIELD_KEYS:
        if k in record:
            payload[k] = record[k]
    payload["roomKey"] = room_key
    # tower 兜底：旧记录缺 tower 时，按房号前缀 2- 判定 2 座，否则 1 座
    if not payload.get("tower"):
        payload["tower"] = 2 if room_key.startswith("2-") else 1
    # 保真原始操作人与更新时间（修订号由服务端权威重排，不沿用旧值）
    if record.get("updatedBy"):
        payload["updatedBy"] = str(record["updatedBy"])
    iso_ts = _epoch_to_iso(record.get("updatedAt"))
    if iso_ts:
        payload["updatedAt"] = iso_ts
    return payload


def ledger_events(record: dict[str, Any]) -> list[dict[str, Any]]:
    """把旧 ledger.json 的 events[] 转成 HouseStore.import_house 的账本入参。"""
    out: list[dict[str, Any]] = []
    for ev in record.get("events") or []:
        changes = [{
            "field": str(c.get("field") or ""),
            "oldValue": str(c.get("oldValue") or ""),
            "newValue": str(c.get("newValue") or ""),
        } for c in ev.get("fieldChanges") or []]
        out.append({
            "id": str(ev.get("id") or ""),
            "ts": _epoch_to_iso(ev.get("date")) or "",
            "operator": str(ev.get("operatorName") or ""),
            "action": str(ev.get("action") or ""),
            "detail": str(ev.get("detail") or ""),
            "fieldChanges": changes,
        })
    return out


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

    def _request(self, method: str, url_path: str,
                 query: str = "", sign_path: str | None = None) -> bytes:
        now = int(time.time())
        key_time = f"{now - 60};{now + 600}"
        # 签名用的资源路径必须是原始（未 percent-encode）路径；含中文房号
        # 时若拿编码路径参与签名，COS 会判 SignatureDoesNotMatch(403)。
        sign_path = sign_path or url_path
        url = f"https://{self.host}{url_path}"
        if query:
            url += "?" + query
        auth = self._sign(key_time, method, sign_path, {})
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
            # COS 返回裸标签无命名空间；个别客户端/代理会包 S3 默认 ns，
            # 这里按根标签自动取 ns 前缀，两种形态都兼容。
            ns = root.tag.split("}", 1)[0] + "}" if root.tag.startswith("{") else ""
            for c in root.findall(f"{ns}Contents"):
                k = c.findtext(f"{ns}Key")
                if k and k.endswith("/info.json"):
                    keys.append(k)
            if root.findtext(f"{ns}IsTruncated") == "true":
                marker = root.findtext(f"{ns}NextContinuationToken") or ""
            else:
                break
        return keys

    def get_object(self, key: str) -> bytes:
        url_path = "/" + urllib.parse.quote(key)
        # 传输用编码路径，签名用原始路径（中文房号必须如此才能过签）。
        return self._request("GET", url_path, sign_path="/" + key)


def run_migration(store: Any, client: CosXMLClient,
                  logger: Callable[[str], None] = print) -> dict[str, int]:
    """拉取全部 info.json（连同账本）导入 SQLite，返回对账计数。

    媒体实体不搬运，只写 objectKey 引用；走 import_house 迁移专用落库，
    不产生 outbox 广播；账本缺失或读取失败不阻断房源导入。
    """
    keys = client.list_info_keys()
    result = {"total": len(keys), "imported": 0, "skipped": 0, "failed": 0,
              "ledgerEvents": 0, "mediaRefs": 0}
    for key in keys:
        try:
            record = json.loads(client.get_object(key).decode("utf-8"))
            payload = record_to_payload(record)
            room_key = payload["roomKey"]
            if not room_key:
                result["skipped"] += 1
                logger(f"跳过无 roomKey: {key}")
                continue
            events: list[dict[str, Any]] = []
            ledger_key = key.replace("/info.json", "/ledger.json")
            try:
                led = json.loads(client.get_object(ledger_key).decode("utf-8"))
                events = ledger_events(led)
            except Exception:
                events = []  # 无账本或读取失败：不阻断房源导入
            doc = store.import_house(
                payload, ledger_events=events,
                operator=str(record.get("updatedBy") or "迁移"))
            result["imported"] += 1
            result["ledgerEvents"] += len(events)
            result["mediaRefs"] += len(doc.get("media") or [])
            logger(f"导入 {room_key}（账本 {len(events)} 条，媒体引用 "
                   f"{len(doc.get('media') or [])}）")
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
