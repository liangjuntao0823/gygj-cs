#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 本地磁盘媒体存储（media_store）
=========================================
全新架构（2026-11-25）：放弃 COS 桶，房源图片/视频、二维码、分享产物等
文件实体全部落服务器本地磁盘，HTTP 直出下载/分享。HouseStore 只存相对引用
（rel_path），本模块负责文件的落盘、读取、删除与目录级联清理。

目录约定（相对 media_root）：
  houses/<roomKey>/<fileName>   房源实拍图 / 视频
  profile/qrcode.<ext>          名片微信二维码
  share/<...>                   分享 H5 / 封面 / 首帧等产物
  releases/<file>               App 安装包本体

安全：
  - roomKey / fileName 一律清洗，拒绝路径穿越（../、绝对路径、分隔符）；
  - 扩展名白名单，非媒体/产物类型不落盘；
  - 所有返回给客户端的引用都是相对路径，拼接下载 URL 时由 API 层处理。
"""

from __future__ import annotations

import re
import secrets
from pathlib import Path
from typing import Any

# 允许的媒体/产物扩展名（小写，含点号）
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"}
VIDEO_EXTS = {".mov", ".mp4", ".m4v"}
QR_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
SHARE_EXTS = {".html", ".jpg", ".jpeg", ".png", ".webp", ".js", ".css"}
RELEASE_EXTS = {".ipa", ".zip"}

_MEDIA_EXTS = IMAGE_EXTS | VIDEO_EXTS


def _clean_segment(value: str) -> str:
    """清洗单段目录/文件名：去掉路径分隔符与穿越片段，保留中文与常规字符。"""
    if value is None:
        return ""
    s = str(value).strip()
    s = s.replace("\\", "/")
    # 去掉所有目录穿越
    parts = [p for p in s.split("/") if p not in ("", ".", "..")]
    s = "-".join(parts)
    # 去掉文件系统不安全字符
    s = re.sub(r'[\x00-\x1f<>:"|?*]', "", s)
    return s


def safe_room_key(room_key: str) -> str:
    return _clean_segment(room_key)


def safe_file_name(file_name: str) -> str:
    # 文件名只取最后一段，杜绝把目录带进文件名
    name = str(file_name).replace("\\", "/").rsplit("/", 1)[-1].strip()
    name = re.sub(r'[\x00-\x1f<>:"|?*/]', "", name)
    # 单独一个 . / .. 会让 Path 解析到上级目录，直接拒绝
    if name in ("", ".", ".."):
        return ""
    return name


def _ext(name: str) -> str:
    return (Path(name).suffix or "").lower()


class MediaStore:
    """本地磁盘媒体存取；线程安全由上层 HouseStore 锁覆盖，本类只做文件操作。"""

    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    # ---- 路径解析 ----
    def _resolve(self, rel_path: str) -> Path | None:
        """把相对路径解析到 root 内；越界返回 None。"""
        rel = str(rel_path or "").replace("\\", "/")
        if rel.startswith("/") or ".." in rel.split("/"):
            return None
        target = (self.root / rel).resolve()
        try:
            target.relative_to(self.root.resolve())
        except ValueError:
            return None
        return target

    def house_path(self, room_key: str, file_name: str) -> Path:
        rk = safe_room_key(room_key)
        fn = safe_file_name(file_name)
        return self.root / "houses" / rk / fn

    @staticmethod
    def rel_house(room_key: str, file_name: str) -> str:
        return f"houses/{safe_room_key(room_key)}/{safe_file_name(file_name)}"

    @staticmethod
    def safe_file_name(file_name: str) -> str:
        return safe_file_name(file_name)

    # ---- 房源媒体 ----
    def save_house_media(self, room_key: str, file_name: str, data: bytes) -> str:
        fn = safe_file_name(file_name)
        if _ext(fn) not in _MEDIA_EXTS:
            raise ValueError("unsupported media extension")
        path = self.house_path(room_key, fn)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return self.rel_house(room_key, fn)

    def unique_house_file_name(self, room_key: str, file_name: str,
                               kind: str = "image") -> str:
        """返回该房目录下不会覆盖既有文件的落盘名。

        - 无后缀名（历史客户端可能只传房号）按 kind 补 .jpg/.mp4；
        - 同名文件已存在时追加 8 位随机 ID，绝不 replace 既有媒体；
        - 正常不冲突的文件名原样保留，客户端账本引用不受影响。
        """
        fn = safe_file_name(file_name)
        if not fn:
            fn = self.new_file_name(room_key, "mp4" if kind == "video" else "jpg")
        ext = _ext(fn)
        if not ext:
            ext = ".mp4" if kind == "video" else ".jpg"
            fn = fn + ext
        if not self.house_path(room_key, fn).exists():
            return fn
        stem = Path(fn).stem
        suffix = Path(fn).suffix
        while True:
            candidate = f"{stem}-{secrets.token_hex(4)}-1{suffix}"
            if not self.house_path(room_key, candidate).exists():
                return candidate

    def save_house_media_stream(self, room_key: str, file_name: str, src,
                                length: int, allow_unknown_ext: bool = False,
                                kind: str = "image") -> str:
        """流式落盘：边读边写，避免大视频把整个 body 读进内存。

        allow_unknown_ext=True 时不再按扩展名白名单拒绝。App 端历史/跨端文件名
        可能带未知后缀（例如 .heif/.avi 或 URLSession 传输时的编码差异），
        此时按清洗后的原名落盘即可；路径已限制在 media_root/houses/<roomKey>/ 下，
        且该入口始终经过 Bearer 鉴权。
        """
        fn = safe_file_name(file_name)
        if not fn:
            raise ValueError("invalid media file name")
        if not allow_unknown_ext and _ext(fn) not in _MEDIA_EXTS:
            raise ValueError("unsupported media extension")
        # 上传入口兜底：同名/无后缀一律唯一化，避免第二次上传 replace 掉第一份媒体。
        fn = self.unique_house_file_name(room_key, fn, kind=kind)
        path = self.house_path(room_key, fn)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".part")
        remaining = int(length)
        try:
            with open(tmp, "wb") as f:
                while remaining > 0:
                    chunk = src.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
            if remaining != 0:
                raise ValueError("incomplete media body")
            tmp.replace(path)
        except Exception:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
            raise
        return self.rel_house(room_key, fn)

    def read_house_media(self, room_key: str, file_name: str) -> bytes | None:
        path = self.house_path(room_key, safe_file_name(file_name))
        if not path.is_file():
            return None
        return path.read_bytes()

    def delete_house_media(self, room_key: str, file_name: str) -> None:
        path = self.house_path(room_key, safe_file_name(file_name))
        try:
            path.unlink()
        except FileNotFoundError:
            pass

    def delete_house_dir(self, room_key: str) -> None:
        import shutil
        rk = safe_room_key(room_key)
        if not rk:
            return
        target = self.root / "houses" / rk
        if target.is_dir():
            shutil.rmtree(target, ignore_errors=True)

    # ---- 分享资源（封面 / 视频首帧 / 海报）----
    def share_path(self, room_key: str, file_name: str) -> Path:
        rk = safe_room_key(room_key) or "_shared"
        fn = safe_file_name(file_name)
        return self.root / "share" / rk / fn

    def save_share_asset(self, room_key: str, file_name: str, data: bytes) -> str:
        fn = safe_file_name(file_name)
        if _ext(fn) not in SHARE_EXTS:
            raise ValueError("unsupported share extension")
        path = self.share_path(room_key, fn)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return f"share/{safe_room_key(room_key) or '_shared'}/{fn}"

    def read_share_asset(self, room_key: str, file_name: str) -> bytes | None:
        path = self.share_path(room_key, file_name)
        if not path.is_file():
            return None
        return path.read_bytes()

    def find_share_asset(self, room_key: str, file_name: str) -> str:
        """返回已存在的分享资源相对路径；不存在返回空串。"""
        rel = f"share/{safe_room_key(room_key) or '_shared'}/{safe_file_name(file_name)}"
        return rel if self._resolve(rel).is_file() else ""

    def iter_house_files(self) -> list[tuple[str, int, float]]:
        """列出 houses/ 下全部文件（相对路径、字节数、mtime），供孤儿媒体扫描。"""
        root = self.root / "houses"
        if not root.is_dir():
            return []
        out: list[tuple[str, int, float]] = []
        for p in root.rglob("*"):
            if not p.is_file() or p.name.endswith(".part"):
                continue
            try:
                st = p.stat()
            except OSError:
                continue
            out.append((p.relative_to(self.root).as_posix(), st.st_size, st.st_mtime))
        return out

    def delete_rel(self, rel_path: str) -> bool:
        """按相对路径删除文件；只允许 houses/ 下，防路径穿越。"""
        rel = str(rel_path or "").replace("\\", "/")
        if not rel.startswith("houses/"):
            return False
        path = self._resolve(rel)
        if path is None or not path.is_file():
            return False
        try:
            path.unlink()
            return True
        except OSError:
            return False

    # ---- 名片二维码 ----
    def save_qrcode(self, file_name: str, data: bytes) -> str:
        fn = safe_file_name(file_name)
        if _ext(fn) not in QR_EXTS:
            raise ValueError("unsupported qrcode extension")
        rel = f"profile/qrcode{_ext(fn)}"
        path = self._resolve(rel)
        if path is None:
            raise ValueError("invalid qrcode path")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return rel

    def read_qrcode(self) -> tuple[bytes, str] | None:
        for ext in QR_EXTS:
            path = self.root / "profile" / f"qrcode{ext}"
            if path.is_file():
                return path.read_bytes(), ext
        return None

    # ---- 分享产物 ----
    def save_share(self, name: str, data: bytes) -> str:
        fn = safe_file_name(name)
        if _ext(fn) not in SHARE_EXTS:
            raise ValueError("unsupported share asset extension")
        rel = f"share/{fn}"
        path = self._resolve(rel)
        if path is None:
            raise ValueError("invalid share path")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return rel

    def read_share(self, name: str) -> bytes | None:
        path = self._resolve(f"share/{safe_file_name(name)}")
        if path and path.is_file():
            return path.read_bytes()
        return None

    # ---- 安装包 ----
    def save_release(self, file_name: str, data: bytes) -> str:
        fn = safe_file_name(file_name)
        if _ext(fn) not in RELEASE_EXTS:
            raise ValueError("unsupported release extension")
        rel = f"releases/{fn}"
        path = self._resolve(rel)
        if path is None:
            raise ValueError("invalid release path")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return rel

    def read_release(self, file_name: str) -> bytes | None:
        path = self._resolve(f"releases/{safe_file_name(file_name)}")
        if path and path.is_file():
            return path.read_bytes()
        return None

    # ---- 通用按 rel_path 读取（公开端点用）----
    def read_rel(self, rel_path: str) -> bytes | None:
        path = self._resolve(rel_path)
        if path and path.is_file():
            return path.read_bytes()
        return None

    def guess_content_type(self, rel_path: str) -> str:
        ext = _ext(rel_path)
        if ext in IMAGE_EXTS:
            return "image/" + ("jpeg" if ext in (".jpg", ".jpeg") else ext[1:])
        if ext in VIDEO_EXTS:
            return "video/mp4" if ext in (".mp4", ".m4v") else "video/quicktime"
        if ext == ".html":
            return "text/html; charset=utf-8"
        if ext == ".js":
            return "application/javascript; charset=utf-8"
        if ext == ".css":
            return "text/css; charset=utf-8"
        if ext == ".ipa":
            return "application/octet-stream"
        return "application/octet-stream"

    @staticmethod
    def new_file_name(room_key: str, ext: str) -> str:
        """生成带 8 位唯一 ID 的文件名，与本地 App 命名口径一致。"""
        uid = secrets.token_hex(4)
        clean_ext = ext.lower().lstrip(".") or "jpg"
        return f"{safe_room_key(room_key)}-{clean_ext.upper()}-{uid}-1.{clean_ext}"
