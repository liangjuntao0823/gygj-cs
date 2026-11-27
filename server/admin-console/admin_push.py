#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 管理后台 —— 推送中心 / 房源板块接入用户（admin_push）
================================================================
以 notify-hub 的用户/设备为唯一数据源，不另建表：
- 业务板块清单：system / meter / house，并自动补上 prefs、设备、事件里出现的新板块；
- 用户级总开关与板块开关；
- 设备级总开关与「每台设备单独订阅哪些板块」；
- 房源板块接入用户：复用 meter tenants.json 的 house_access，后台可逐用户开关；
- 生效规则：业务板块准入（house_access）优先于推送中心开关。
"""

from __future__ import annotations

import time
from typing import Any

MODULES: list[dict[str, str]] = [
    {"key": "system", "name": "系统通道", "desc": "接入码、通道测试等系统级通知"},
    {"key": "meter", "name": "电表值守", "desc": "低电量、拉闸、电表轮询异常"},
    {"key": "house", "name": "房源板块", "desc": "新增、修改、删除房源同步"},
]


def _mask(t: str, head: int = 6, tail: int = 4) -> str:
    t = str(t or "")
    if len(t) <= head + tail + 1:
        return "****" if t else ""
    return f"{t[:head]}…{t[-tail:]}"


def _enabled(v: Any, default: bool = True) -> bool:
    return default if v is None else bool(v)


class PushConsole:
    def __init__(self, hub: Any, meter: Any) -> None:
        self.hub = hub
        self.meter = meter

    # ---- 板块清单 ----
    def _catalog(self, users: list[dict[str, Any]]) -> list[dict[str, str]]:
        known = {m["key"]: dict(m) for m in MODULES}
        def add(key: str) -> None:
            key = str(key or "").strip()[:32]
            if key and key not in known:
                known[key] = {"key": key, "name": key, "desc": "动态接入的业务板块"}
        for u in users:
            prefs = u.get("prefs") if isinstance(u.get("prefs"), dict) else {}
            mods = prefs.get("modules") if isinstance(prefs.get("modules"), dict) else {}
            for k in mods:
                add(k)
            for d in u.get("devices", []):
                if not isinstance(d, dict):
                    continue
                mods = d.get("modules") if isinstance(d.get("modules"), dict) else {}
                for k in mods:
                    add(k)
            for ev in u.get("events", []):
                if isinstance(ev, dict):
                    add(ev.get("module", ""))
        return list(known.values())

    def _tenant_map(self) -> dict[str, dict[str, Any]]:
        if self.meter is None:
            return {}
        try:
            tenants = self.meter.store.load_tenants()
        except Exception:
            return {}
        out: dict[str, dict[str, Any]] = {}
        for token, tenant in (tenants or {}).items():
            if not isinstance(tenant, dict):
                continue
            nt = str(tenant.get("notify_user_token") or "")
            if nt:
                out[nt] = {"tenantToken": token, **tenant}
        return out

    def _modules_for_user(self, user: dict[str, Any]) -> dict[str, bool]:
        prefs = user.get("prefs") if isinstance(user.get("prefs"), dict) else {}
        mods = prefs.get("modules") if isinstance(prefs.get("modules"), dict) else {}
        return {m["key"]: mods.get(m["key"], True) is not False for m in MODULES}

    def overview(self) -> dict[str, Any]:
        hub = self.hub
        users = hub.store.doc().get("users", {}) if hub is not None else {}
        tenant_by_hub = self._tenant_map()
        catalog = self._catalog([u for u in users.values() if isinstance(u, dict)])
        module_counts = {m["key"]: 0 for m in catalog}
        items: list[dict[str, Any]] = []
        total_devices = 0
        for token, user in users.items():
            if not isinstance(user, dict):
                continue
            prefs = user.get("prefs") if isinstance(user.get("prefs"), dict) else {}
            user_enabled = prefs.get("enabled", True) is not False
            user_modules = self._modules_for_user(user)
            tenant = tenant_by_hub.get(str(token), {})
            house_access = tenant.get("house_access", True) is not False if tenant else False
            devices: list[dict[str, Any]] = []
            for d in user.get("devices", []):
                if not isinstance(d, dict):
                    continue
                device_enabled = d.get("enabled", True) is not False
                raw_modules = d.get("modules") if isinstance(d.get("modules"), dict) else {}
                effective = {}
                for m in catalog:
                    key = m["key"]
                    allowed = (user_enabled and device_enabled
                               and user_modules.get(key, True)
                               and (raw_modules.get(key, True) is not False)
                               and (house_access if key == "house" else True))
                    effective[key] = bool(allowed)
                    if allowed:
                        module_counts[key] = module_counts.get(key, 0) + 1
                devices.append({
                    "deviceId": str(d.get("device_id") or ""),
                    "name": str(d.get("name") or ""),
                    "platform": str(d.get("platform") or ""),
                    "enabled": device_enabled,
                    "modules": {m["key"]: raw_modules.get(m["key"], True) is not False for m in catalog},
                    "effectiveModules": effective,
                    "keyMasked": d.get("keyMasked") or "",
                    "lastOkAt": float(d.get("last_ok_at") or 0),
                    "lastError": str(d.get("last_error") or ""),
                })
            total_devices += len(devices)
            items.append({
                "userToken": str(token),
                "tokenMasked": _mask(str(token)),
                "username": str(user.get("username") or ""),
                "enabled": user_enabled,
                "modules": user_modules,
                "houseAccess": bool(house_access),
                "hasTenant": bool(tenant),
                "devices": devices,
                "devicesCount": len(devices),
                "updatedAt": str(user.get("updated_at") or ""),
            })
        items.sort(key=lambda x: (not x["enabled"], x["username"]))
        return {
            "ok": True,
            "modules": catalog,
            "summary": {
                "users": len(items),
                "devices": total_devices,
                "enabledUsers": sum(1 for x in items if x["enabled"]),
                "houseUsers": sum(1 for x in items if x["houseAccess"]),
                "moduleDevices": module_counts,
            },
            "users": items,
            "serverTime": time.strftime("%Y-%m-%d %H:%M:%S"),
        }

    # ---- 推送中心控制 ----
    def set_user(self, token: str, enabled: Any = None,
                 modules: dict | None = None) -> dict[str, Any]:
        kwargs: dict[str, Any] = {}
        if enabled is not None:
            kwargs["enabled"] = bool(enabled)
        if isinstance(modules, dict):
            kwargs["modules"] = modules
        view, err = self.hub.set_prefs(str(token or ""), **kwargs)
        if err:
            return {"ok": False, "error": err}
        return {"ok": True, "user": view}

    def set_device(self, token: str, device_id: str, enabled: Any = None,
                   modules: dict | None = None, name: Any = None) -> dict[str, Any]:
        kwargs: dict[str, Any] = {}
        if enabled is not None:
            kwargs["enabled"] = bool(enabled)
        if isinstance(modules, dict):
            kwargs["modules"] = modules
        if name is not None:
            kwargs["name"] = name
        view, err = self.hub.set_device_prefs(str(token or ""), str(device_id or ""), **kwargs)
        if err:
            return {"ok": False, "error": err}
        return {"ok": True, "user": view}

    def remove_device(self, token: str, device_id: str) -> dict[str, Any]:
        view = self.hub.remove_device(str(token or ""), device_id=str(device_id or ""))
        if view is None:
            return {"ok": False, "error": "unauthorized"}
        return {"ok": True, "user": view}

    # ---- 房源板块接入用户 ----
    def house_users(self) -> dict[str, Any]:
        if self.meter is None:
            return {"ok": False, "error": "meter_store_unavailable"}
        tenants = self.meter.store.load_tenants()
        items: list[dict[str, Any]] = []
        allowed = denied = bound = 0
        for token, tenant in (tenants or {}).items():
            if not isinstance(tenant, dict):
                continue
            access = tenant.get("house_access", True) is not False
            if access:
                allowed += 1
            else:
                denied += 1
            notify_token = str(tenant.get("notify_user_token") or "")
            hub_user = self.hub.store.get_user(notify_token) if notify_token else None
            if isinstance(hub_user, dict):
                bound += 1
            items.append({
                "tenantToken": _mask(str(token)),
                "device": str(tenant.get("device") or ""),
                "username": str((hub_user or {}).get("username") or ""),
                "notifyTokenMasked": _mask(notify_token),
                "notifyBound": isinstance(hub_user, dict),
                "houseAccess": bool(access),
                "devicesCount": len((hub_user or {}).get("devices") or []),
                "updatedAt": str(tenant.get("updated_at") or ""),
            })
        items.sort(key=lambda x: (not x["houseAccess"], x["device"]))
        return {
            "ok": True,
            "summary": {"total": len(items), "allowed": allowed,
                        "denied": denied, "notifyBound": bound},
            "users": items,
        }

    def set_house_access(self, token: str, enabled: bool) -> dict[str, Any]:
        if self.meter is None:
            return {"ok": False, "error": "meter_store_unavailable"}
        full = self.meter.resolve_token(str(token or ""))
        if full is None:
            return {"ok": False, "error": "tenant_not_found"}
        tenants = self.meter.store.load_tenants()
        tenant = tenants.get(full) if isinstance(tenants, dict) else None
        if not isinstance(tenant, dict):
            return {"ok": False, "error": "tenant_not_found"}
        notify_token = str(tenant.get("notify_user_token") or "")
        # 按“用户”开关：同一 notify_user_token 下的多台设备/租户一起切换，避免只关一台造成半开半关。
        targets = [t for t, row in tenants.items()
                   if isinstance(row, dict)
                   and notify_token
                   and str(row.get("notify_user_token") or "") == notify_token]
        if not targets:
            targets = [full]
        changed = 0
        for t in targets:
            res = self.meter.store.upsert_config(t, {"house_access": bool(enabled)})
            if res is not None:
                changed += 1
        return {"ok": changed > 0, "tenant": _mask(full),
                "houseAccess": bool(enabled), "changed": changed,
                "error": None if changed else "update_failed"}

