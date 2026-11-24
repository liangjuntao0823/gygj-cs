#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 管理后台 —— 电表值守可视化与控制（admin_meter）
==========================================================
数据源复用现有运行时，不另建库：
- meter-watch Store：tenants.json（账户/开关/设置/电表清单/推送绑定）、state.json（最近一轮读数）、
  service.json（接入码 enroll_code）。
- notify-hub HubRuntime：把租户绑定的 notify_user_token 映射到 App 用户名、设备、模块开关与最近投递状态。

提供：
- 汇总（账户数、值守中/暂停、电表数、推送正常/异常）。
- 逐账户明细：App 用户、设备、阈值、轮询间隔、低电量开关、电表详情、推送状态、最近一轮结果。
- 账户控制：启停值守、改阈值/轮询/低电量开关；改动可由上层按推送范围选择 Bark 通知。
- 接入码展示与轮换；惰性检查满 24 小时自动换新。
- 最新快照导出（JSON 字节 + 文件名）。
"""

from __future__ import annotations

import secrets
import time
from pathlib import Path
from typing import Any

CODE_ROTATE_SEC = 24 * 3600


def _mask_token(t: str) -> str:
    t = str(t or "")
    if len(t) <= 10:
        return "****" if t else ""
    return f"{t[:6]}…{t[-4:]}"


class MeterConsole:
    def __init__(self, store: Any, hub: Any) -> None:
        self.store = store
        self.hub = hub

    # ---- 接入码 ----
    def code_info(self) -> dict[str, Any]:
        svc = self.store.svc
        rotated = float(svc.get("enroll_code_rotated_at") or 0.0)
        self._maybe_rotate(force=False)
        svc = self.store.svc
        rotated = float(svc.get("enroll_code_rotated_at") or 0.0)
        remaining = max(0, int(CODE_ROTATE_SEC - (time.time() - rotated))) if rotated else CODE_ROTATE_SEC
        return {
            "enrollCode": str(svc.get("enroll_code") or ""),
            "rotatedAt": rotated,
            "remainingSec": remaining,
            "rotateIntervalSec": CODE_ROTATE_SEC,
        }

    def rotate_code(self) -> dict[str, Any]:
        self._maybe_rotate(force=True)
        svc = self.store.svc
        return {"ok": True, "enrollCode": str(svc.get("enroll_code") or ""),
                "rotatedAt": float(svc.get("enroll_code_rotated_at") or 0.0)}

    def _maybe_rotate(self, force: bool) -> None:
        svc = self.store.svc
        last = float(svc.get("enroll_code_rotated_at") or 0.0)
        now = time.time()
        if force:
            svc["enroll_code"] = secrets.token_hex(16)
            svc["enroll_code_rotated_at"] = now
            self.store.save_service(svc)
            return
        if last == 0.0:
            # 首次载入：已有接入码则仅补记轮换时间，不随意换码；无码才生成
            if not svc.get("enroll_code"):
                svc["enroll_code"] = secrets.token_hex(16)
            svc["enroll_code_rotated_at"] = now
            self.store.save_service(svc)
            return
        if now - last >= CODE_ROTATE_SEC:
            svc["enroll_code"] = secrets.token_hex(16)
            svc["enroll_code_rotated_at"] = now
            self.store.save_service(svc)

    # ---- 账户视图 ----
    def _hub_user_view(self, notify_token: str) -> dict[str, Any]:
        if self.hub is None or not notify_token:
            return {"bound": False}
        user = self.hub.store.get_user(notify_token)
        if not isinstance(user, dict):
            return {"bound": False, "notifyToken": _mask_token(notify_token)}
        prefs = user.get("prefs") if isinstance(user.get("prefs"), dict) else {}
        modules = prefs.get("modules") if isinstance(prefs.get("modules"), dict) else {}
        devices = user.get("devices") or []
        recent = list(user.get("events", []) or [])[-3:]
        push_enabled = prefs.get("enabled", True) is not False
        meter_enabled = modules.get("meter", True) is not False
        push_ok = push_enabled and meter_enabled and len(devices) > 0
        return {
            "bound": True,
            "username": user.get("username", ""),
            "notifyToken": _mask_token(notify_token),
            "pushEnabled": bool(push_enabled),
            "meterModuleEnabled": bool(meter_enabled),
            "devicesCount": len(devices),
            "devices": [{
                "name": d.get("name", ""), "platform": d.get("platform", ""),
                "keyMasked": d.get("keyMasked") if "keyMasked" in d else "",
                "lastOkAt": d.get("last_ok_at", 0), "lastError": d.get("last_error", ""),
            } for d in devices if isinstance(d, dict)],
            "recentEvents": [{
                "at": e.get("at", ""), "title": e.get("title", ""),
                "status": e.get("status", ""), "sent": e.get("sent", 0),
                "total": e.get("total", 0),
            } for e in recent if isinstance(e, dict)],
            "pushOk": bool(push_ok),
        }

    def _meter_rows(self, tenant: dict[str, Any], state_doc: dict[str, Any]) -> list[dict[str, Any]]:
        meters = tenant.get("meters") or []
        mstates = state_doc.get("meters", {}) if isinstance(state_doc.get("meters"), dict) else {}
        rows: list[dict[str, Any]] = []
        for m in meters:
            if not isinstance(m, dict):
                continue
            uid = str(m.get("uid") or "")
            ms = mstates.get(uid, {}) if isinstance(mstates.get(uid), dict) else {}
            shengyu = float(ms.get("shengyu") or 0.0)
            threshold = float((tenant.get("settings") or {}).get("lowThreshold") or 30.0)
            rows.append({
                "uid": uid, "room": str(m.get("room") or ""),
                "shengyu": shengyu, "leiji": float(ms.get("leiji") or 0.0),
                "zhuangtai": str(ms.get("zhuangtai") or ""),
                "time": str(ms.get("shijian") or ""),
                "lastOkTs": float(ms.get("last_ok_ts") or 0.0),
                "low": shengyu <= threshold,
            })
        return rows

    def tenants(self) -> dict[str, Any]:
        tenants = self.store.load_tenants()
        state_doc_all = self.store.load_state_doc().get("tenants", {})
        items: list[dict[str, Any]] = []
        active = paused = meter_total = push_ok = push_bad = 0
        for token, tenant in tenants.items():
            if not isinstance(tenant, dict):
                continue
            enabled = bool(tenant.get("enabled"))
            settings = tenant.get("settings") if isinstance(tenant.get("settings"), dict) else {}
            state_doc = state_doc_all.get(token, {}) if isinstance(state_doc_all, dict) else {}
            rows = self._meter_rows(tenant, state_doc)
            hub_view = self._hub_user_view(str(tenant.get("notify_user_token") or ""))
            if enabled:
                active += 1
            else:
                paused += 1
            meter_total += len(rows)
            if hub_view.get("bound") and hub_view.get("pushOk"):
                push_ok += 1
            elif hub_view.get("bound"):
                push_bad += 1
            items.append({
                "token": _mask_token(token),
                "device": str(tenant.get("device") or ""),
                "enabled": enabled,
                "settings": {
                    "openId": str(settings.get("openId") or ""),
                    "lowThreshold": float(settings.get("lowThreshold") or 30.0),
                    "lowAlertEnabled": bool(settings.get("lowAlertEnabled", True)),
                    "pollIntervalSeconds": int(settings.get("pollIntervalSeconds") or 3600),
                    "provider": str(settings.get("provider") or "direct"),
                },
                "meters": rows,
                "barkKeysCount": len(tenant.get("bark_keys") or []),
                "hub": hub_view,
                "state": {
                    "lastRoundAt": float(state_doc.get("last_round_at") or 0.0),
                    "lastOkAt": float(state_doc.get("last_ok_at") or 0.0),
                    "consecutiveFailures": int(state_doc.get("consecutive_failures") or 0),
                    "lastError": str(state_doc.get("last_error") or ""),
                },
                "updatedAt": str(tenant.get("updated_at") or ""),
                "createdAt": str(tenant.get("created_at") or ""),
            })
        items.sort(key=lambda x: (not x["enabled"], x["device"]))
        return {
            "ok": True,
            "summary": {
                "tenants": len(items), "active": active, "paused": paused,
                "meters": meter_total, "pushOk": push_ok, "pushBad": push_bad,
            },
            "tenants": items,
        }

    # ---- 控制 ----
    def set_enabled(self, token: str, enabled: bool) -> dict[str, Any]:
        full = self.resolve_token(token)
        if full is None:
            return {"ok": False, "error": "tenant_not_found"}
        res = self.store.upsert_config(full, {"enabled": bool(enabled)})
        return {"ok": res is not None, "enabled": bool((res or {}).get("enabled"))}

    def update_settings(self, token: str, settings: dict[str, Any]) -> dict[str, Any]:
        full = self.resolve_token(token)
        if full is None:
            return {"ok": False, "error": "tenant_not_found"}
        res = self.store.upsert_config(full, {"settings": settings})
        if res is None:
            return {"ok": False, "error": "update_failed"}
        return {"ok": True, "settings": res.get("settings")}

    def _find_tenant(self, token: str) -> dict[str, Any] | None:
        full = self.resolve_token(token)
        if full is None:
            return None
        return self.store.load_tenants().get(full)

    def resolve_token(self, mask_or_full: str) -> str | None:
        """后台传入的可能是脱敏串（列表接口回传值），也可能是完整 token；两种都能定位。"""
        for existing_token, existing in self.store.load_tenants().items():
            if existing_token == mask_or_full or _mask_token(existing_token) == mask_or_full:
                return existing_token
        return None

    # ---- 快照导出 ----
    def snapshot_export(self) -> tuple[bytes, str]:
        import json
        doc = self.tenants()
        # 导出时附带原始完整 token 不在其中（视图已脱敏）；文件名带时间戳
        stamp = time.strftime("%Y%m%d-%H%M%S")
        filename = f"meter-snapshot-{stamp}.json"
        return json.dumps(doc, ensure_ascii=False, indent=2).encode("utf-8"), filename
