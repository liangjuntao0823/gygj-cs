#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 管理后台 —— 服务器看板与进程控制（admin_sys）
=========================================================
- 纯标准库读取 /proc、/proc/meminfo、/proc/stat、/proc/net/dev、shutil.disk_usage；
  CPU/网络速率用短采样计算，不依赖 psutil。
- 进程控制只开放白名单内、为 App 服务的 unit；命令参数取自白名单 dict，
  绝不接受前端传入任意服务名或 shell 串。
- 边界（用户既定口径）：
    * meter-watch（8082，本服务）：允许 start / restart / stop。
    * bark-server（8081，v2.4.0）：只读展示状态，不提供启停/重启。
    * jianli-majiang（8878）：后台完全不出现，不读取也不操作。
- 所有控制动作写入审计记录（内存环形表），供后台「操作日志」查看。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

# 白名单：key=systemd unit；can_control=False 的只展示不操作
SERVICES: dict[str, dict[str, Any]] = {
    "meter-watch.service": {
        "display": "meter-watch（值守 + 同步 API · 8082）",
        "can_control": True,
        "desc": "电表云端值守、房源同步 API、通知中心、管理后台入口",
    },
    "bark-server.service": {
        "display": "bark-server（自建推送 · 8081）",
        "can_control": False,
        "desc": "APNs 投递层，v2.4.0 锁定版本，仅展示状态",
    },
}

SYSTEMCTL_TIMEOUT = 10.0
NET_SAMPLE_SEC = 0.25
AUDIT_CAP = 200


def _read_lines(path: str) -> list[str]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.readlines()
    except OSError:
        return []


def _cpu_totals() -> tuple[int, int]:
    """返回 (空闲 jiffies, 总 jiffies)，取自 /proc/stat 首行 cpu。"""
    lines = _read_lines("/proc/stat")
    if not lines:
        return 0, 1
    parts = lines[0].split()
    if len(parts) < 5 or parts[0] != "cpu":
        return 0, 1
    vals = [int(x) for x in parts[1:] if x.isdigit()]
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return idle, sum(vals)


def _mem() -> dict[str, int]:
    info: dict[str, int] = {}
    for line in _read_lines("/proc/meminfo"):
        parts = line.split(":")
        if len(parts) == 2:
            try:
                info[parts[0].strip()] = int(parts[1].strip().split()[0]) * 1024
            except (ValueError, IndexError):
                pass
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", info.get("MemFree", 0))
    used = max(0, total - avail)
    return {"total": total, "used": used, "free": info.get("MemFree", 0),
            "available": avail}


def _net_counters() -> tuple[int, int]:
    rx = tx = 0
    for line in _read_lines("/proc/net/dev")[2:]:
        if ":" not in line:
            continue
        _, rest = line.split(":", 1)
        vals = rest.split()
        if len(vals) >= 10:
            try:
                rx += int(vals[0])
                tx += int(vals[8])
            except ValueError:
                pass
    return rx, tx


def _loadavg() -> list[float]:
    try:
        return [float(x) for x in os.getloadavg()]
    except OSError:
        return [0.0, 0.0, 0.0]


def _cpu_percent() -> float:
    idle1, total1 = _cpu_totals()
    time.sleep(NET_SAMPLE_SEC)
    idle2, total2 = _cpu_totals()
    idle_d, total_d = idle2 - idle1, total2 - total1
    if total_d <= 0:
        return 0.0
    return round(max(0.0, min(100.0, (1 - idle_d / total_d) * 100)), 1)


class SystemBoard:
    def __init__(self) -> None:
        self._audit_lock = threading.Lock()
        self._audit: list[dict[str, Any]] = []

    # ---- 审计 ----
    def _record_audit(self, actor: str, action: str, target: str, detail: str) -> None:
        with self._audit_lock:
            self._audit.append({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "actor": actor,
                "action": action, "target": target, "detail": detail,
            })
            if len(self._audit) > AUDIT_CAP:
                self._audit = self._audit[-AUDIT_CAP:]

    def audit_log(self) -> list[dict[str, Any]]:
        with self._audit_lock:
            return list(reversed(self._audit))

    # ---- 看板 ----
    def overview(self) -> dict[str, Any]:
        mem = _mem()
        disk = shutil.disk_usage("/")
        cores = os.cpu_count() or 1
        idle1, total1 = _cpu_totals()
        rx1, tx1 = _net_counters()
        time.sleep(NET_SAMPLE_SEC)
        idle2, total2 = _cpu_totals()
        rx2, tx2 = _net_counters()
        cpu_d, idle_d = total2 - total1, idle2 - idle1
        cpu_pct = round(max(0.0, min(100.0, (1 - idle_d / cpu_d) * 100)), 1) if cpu_d > 0 else 0.0
        net_rx = round((rx2 - rx1) / NET_SAMPLE_SEC, 1)
        net_tx = round((tx2 - tx1) / NET_SAMPLE_SEC, 1)
        return {
            "hostname": os.uname().nodename if hasattr(os, "uname") else "",
            "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "uptimeSec": self._uptime(),
            "cpuCores": cores,
            "cpuPercent": cpu_pct,
            "loadAvg": _loadavg(),
            "memTotal": mem["total"], "memUsed": mem["used"],
            "memAvailable": mem["available"],
            "memPercent": round(mem["used"] / mem["total"] * 100, 1) if mem["total"] else 0.0,
            "diskTotal": disk.total, "diskUsed": disk.used,
            "diskFree": disk.free,
            "diskPercent": round(disk.used / disk.total * 100, 1) if disk.total else 0.0,
            "netRxBps": max(0.0, net_rx), "netTxBps": max(0.0, net_tx),
        }

    @staticmethod
    def _uptime() -> int:
        try:
            with open("/proc/uptime", "r", encoding="utf-8") as f:
                return int(float(f.read().split()[0]))
        except OSError:
            return 0

    # ---- 服务状态 ----
    def _systemctl_show(self, unit: str) -> dict[str, str]:
        fields = ["ActiveState", "SubState", "MainPID", "LoadState",
                  "UnitFileState", "MemoryCurrent"]
        try:
            out = subprocess.run(
                ["systemctl", "show", unit,
                 "--property=" + ",".join(fields)],
                capture_output=True, text=True, timeout=SYSTEMCTL_TIMEOUT)
            if out.returncode != 0:
                return {"ActiveState": "unknown"}
            res: dict[str, str] = {}
            for line in out.stdout.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    res[k] = v.strip()
            return res
        except Exception:
            return {"ActiveState": "unknown"}

    def services(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for unit, meta in SERVICES.items():
            info = self._systemctl_show(unit)
            pid = int(info.get("MainPID") or "0")
            rss = self._pid_rss(pid)
            out.append({
                "unit": unit,
                "display": meta["display"],
                "desc": meta["desc"],
                "canControl": meta["can_control"],
                "active": info.get("ActiveState", "unknown"),
                "subState": info.get("SubState", ""),
                "loadState": info.get("LoadState", ""),
                "unitFileState": info.get("UnitFileState", ""),
                "pid": pid,
                "memoryKb": rss,
            })
        return out

    @staticmethod
    def _pid_rss(pid: int) -> int:
        if pid <= 0:
            return 0
        try:
            for line in _read_lines(f"/proc/{pid}/status"):
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
        except OSError:
            pass
        return 0

    # ---- 控制（仅白名单 can_control）----
    CONTROL_ACTIONS = ("start", "restart", "stop")

    def control(self, unit: str, action: str, actor: str) -> dict[str, Any]:
        meta = SERVICES.get(unit)
        if not meta:
            return {"ok": False, "error": "unit_not_allowed"}
        if not meta["can_control"]:
            return {"ok": False, "error": "unit_readonly",
                    "hint": "该服务为锁定只读项，不允许后台操作"}
        if action not in self.CONTROL_ACTIONS:
            return {"ok": False, "error": "invalid_action"}
        try:
            out = subprocess.run(
                ["systemctl", action, unit],
                capture_output=True, text=True, timeout=SYSTEMCTL_TIMEOUT)
            ok = out.returncode == 0
            self._record_audit(actor, action, unit,
                               (out.stderr or out.stdout or "").strip()[:200])
            if not ok:
                return {"ok": False, "error": "control_failed",
                        "detail": (out.stderr or out.stdout or "").strip()[:200]}
            time.sleep(0.6)
            return {"ok": True, "action": action, "unit": unit,
                    "state": self._systemctl_show(unit)}
        except Exception as e:  # 超时/权限/缺失均不抛到 HTTP 层
            self._record_audit(actor, action, unit, f"exception: {e}")
            return {"ok": False, "error": "control_exception", "detail": str(e)[:200]}
