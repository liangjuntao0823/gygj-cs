#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""服务端分享页渲染：单房 / 合集 / 公开选房列表。

H5 由服务端直接输出完整 HTML（微信不执行 JS），媒体与二维码走带签名的
/api/public/media 路由；og:title / og:description / og:image 用于微信卡片。
"""

from __future__ import annotations

import json
import time
import urllib.parse
from typing import Any

import h5_templates as tpl


def _origin(handler: Any) -> str:
    proto = (handler.headers.get("X-Forwarded-Proto") or "http").split(",")[0].strip()
    host = (handler.headers.get("X-Forwarded-Host") or handler.headers.get("Host") or "")
    return f"{proto}://{host}".rstrip("/")


def media_url(origin: str, rel: str, token: str) -> str:
    return f"{origin}/api/public/media/{urllib.parse.quote(rel)}?t={urllib.parse.quote(token)}"


def page_url(origin: str, token: str) -> str:
    return f"{origin}/api/public/h5?t={urllib.parse.quote(token)}&v={int(time.time())}"


def _display_room_no(tower: int, room_no: str) -> str:
    prefix = "2-" if int(tower or 1) == 2 else "1-"
    raw = str(room_no or "")
    for p in ("1-", "2-"):
        if raw.startswith(p):
            raw = raw[2:]
    return prefix + raw


def _layout_title(layout: str, room_no: str) -> str:
    suffix = "".join(ch for ch in str(room_no or "") if not ch.isdigit() and ch not in "- . /")
    title = layout or "房源"
    if suffix and ("上" not in title and "下" not in title) and not title.endswith(suffix):
        title += " · " + suffix
    return title


def _watermark_html(wm: dict[str, Any] | None) -> str:
    if not isinstance(wm, dict) or not wm.get("enabled"):
        return ""
    text = str(wm.get("text") or "").strip()
    if not text:
        return ""
    position = str(wm.get("position") or "bottomRight")
    x = max(0, int(wm.get("offsetX") or 0))
    y = max(0, int(wm.get("offsetY") or 0))
    placement = {
        "bottomRight": f"right:{x}px;bottom:{y}px;",
        "bottomLeft": f"left:{x}px;bottom:{y}px;",
        "topRight": f"right:{x}px;top:{y}px;",
        "topLeft": f"left:{x}px;top:{y}px;",
    }.get(position, f"right:{x}px;bottom:{y}px;")
    opacity = max(0.0, min(1.0, float(wm.get("opacity") or 0.5)))
    size = max(8, min(48, int(wm.get("fontSize") or 14)))
    return (f'<div class="wm" style="position:absolute;{placement}color:rgba(255,255,255,{opacity});'
            f'font-size:{size}px;font-weight:500;line-height:1;text-shadow:0 1px 2px rgba(0,0,0,.35);'
            f'pointer-events:none;user-select:none;z-index:2;max-width:70%;overflow:hidden;'
            f'text-overflow:ellipsis;white-space:nowrap;">{tpl.esc(text)}</div>')


def _track_script(origin: str, token: str, room: str, mode: str) -> str:
    room_js = json.dumps(room, ensure_ascii=False)
    mode_js = json.dumps(mode, ensure_ascii=False)
    base = json.dumps(f"{origin}/api/public/track?t={urllib.parse.quote(token)}", ensure_ascii=False)
    return f'''<script>(function(){{try{{var u={base};var k='gy_tk_'+encodeURIComponent({room_js})+'_'+encodeURIComponent({mode_js});var now=Date.now(),last=0;try{{last=parseInt(localStorage.getItem(k)||'0',10)||0;}}catch(e){{}}if(now-last<30000)return;try{{localStorage.setItem(k,String(now));}}catch(e){{}}var r=(document.referrer||'').slice(0,120);var img=new Image();img.src=u+'&room='+encodeURIComponent({room_js})+'&mode='+encodeURIComponent({mode_js})+'&ref='+encodeURIComponent(r);}}catch(e){{}}}})();</script>'''


def _room_view(store: Any, origin: str, token: str, room_key: str, mode: str) -> dict[str, Any] | None:
    doc = store.public_single(room_key, mode=mode)
    if not doc:
        return None
    rk = doc["roomKey"]
    media = sorted(doc.get("media") or [],
                   key=lambda m: (0 if m["kind"] == "video" else 1, m.get("sortOrder", 0)))
    images = [m for m in media if m["kind"] != "video"]
    videos = [m for m in media if m["kind"] == "video"]
    image_urls = [media_url(origin, m["objectKey"], token) for m in images]
    video_tags = []
    for m in videos:
        video_url = media_url(origin, m["objectKey"], token)
        thumb_rel = store.media.find_share_asset(rk, m["fileName"] + ".vthumb.jpg")
        thumb_url = media_url(origin, thumb_rel, token) if thumb_rel else video_url
        video_tags.append(tpl.video_tag(video_url, thumb_url))
    cover_rel = store.media.find_share_asset(rk, "cover.jpg")
    if not cover_rel and images:
        cover_rel = images[0]["objectKey"]
    cover = media_url(origin, cover_rel, token) if cover_rel else ""
    display = _display_room_no(doc.get("tower", 1), doc.get("roomNo", "")) if mode == "full" else ""
    return {
        "roomKey": rk,
        "displayRoomNo": display,
        "layout": doc.get("layout") or "房源",
        "title": _layout_title(doc.get("layout") or "房源", doc.get("roomNo", "")),
        "price": int(doc.get("price") or 0),
        "priceText": f"¥{int(doc.get('price') or 0)}",
        "landlord": doc.get("landlord") or "",
        "password": doc.get("password") or "",
        "remark": doc.get("remark") or "",
        "video_tags": video_tags,
        "image_urls": image_urls,
        "cover_url": cover,
    }


def _qr(store: Any, origin: str, token: str) -> str:
    profile = store.profile_get()
    rel = profile.get("qrPath") or ""
    if rel and store.media.read_rel(rel):
        return media_url(origin, rel, token)
    return ""


def render_single(store: Any, handler: Any, token: str, room_key: str,
                  mode: str, wm: dict[str, Any] | None = None) -> str:
    origin = _origin(handler)
    profile = store.profile_get()
    name = profile.get("name") or "梁涛"
    phone = profile.get("phone") or "13288251132"
    room = _room_view(store, origin, token, room_key, mode)
    if not room:
        return tpl.simple_error("该房源暂不可见", "房源已出租或已下架，请联系房东获取最新房源。")
    share_url = page_url(origin, token)
    wm_html = _watermark_html(wm)
    track = _track_script(origin, token, room_key, mode)
    if mode == "full":
        desc = (f"{room['priceText']} · {room['landlord']}\n{name}-{phone}"
                if room["landlord"] else f"{room['priceText']}\n{name}-{phone}")
        title = f"{room['displayRoomNo']} · {room['title']}"
        return tpl.full_single(title, desc, room, name, phone, room["video_tags"],
                               room["image_urls"], room["cover_url"], _qr(store, origin, token),
                               share_url, wm_html, track)
    desc = f"利保米兰公馆\n{name}-{phone}"
    return tpl.masked_single(room["title"], desc, name, phone, room["video_tags"],
                             room["image_urls"], room["cover_url"], _qr(store, origin, token),
                             share_url, wm_html, track)


def render_collection(store: Any, handler: Any, token: str,
                      room_keys: list[str], mode: str,
                      wm: dict[str, Any] | None = None) -> str:
    origin = _origin(handler)
    profile = store.profile_get()
    name = profile.get("name") or "梁涛"
    phone = profile.get("phone") or "13288251132"
    rooms = []
    for rk in room_keys:
        room = _room_view(store, origin, token, rk, mode)
        if room:
            rooms.append(room)
    if not rooms:
        return tpl.simple_error("该分享暂不可见", "房源已出租或已下架，请联系房东获取最新房源。")
    share_url = page_url(origin, token)
    cover = rooms[0]["cover_url"]
    track = _track_script(origin, token, "collection", mode)
    return tpl.collection(rooms, mode, name, phone, cover, _qr(store, origin, token),
                          share_url, _watermark_html(wm), track)


def render_list(store: Any, handler: Any, token: str, mode: str = "masked",
                wm: dict[str, Any] | None = None) -> str:
    origin = _origin(handler)
    profile = store.profile_get()
    name = profile.get("name") or "梁涛"
    phone = profile.get("phone") or "13288251132"
    rooms = []
    for doc in store.public_rooms(mode="masked"):
        rk = doc["roomKey"]
        cover_rel = store.media.find_share_asset(rk, "cover.jpg")
        if not cover_rel:
            first_img = next((m for m in doc.get("media") or [] if m["kind"] != "video"), None)
            cover_rel = first_img["objectKey"] if first_img else ""
        rooms.append({
            "roomKey": rk, "layout": doc.get("layout") or "房源",
            "cover_url": media_url(origin, cover_rel, token) if cover_rel else "",
            "share_url": f"{page_url(origin, token)}&roomKey={urllib.parse.quote(rk)}",
        })
    cover = rooms[0]["cover_url"] if rooms else ""
    track = _track_script(origin, token, "rooms", "rooms")
    return tpl.rooms_list(rooms, name, phone, _qr(store, origin, token),
                          page_url(origin, token), cover, _watermark_html(wm), track)
