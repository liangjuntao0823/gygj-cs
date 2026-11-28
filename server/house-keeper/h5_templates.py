#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分享 H5 / 公开选房页模板（复刻旧 2.72 视觉与交互）。

服务端渲染，微信不执行 JS 也能读到 og:title / og:description / og:image。
所有动态值均经 html.escape。
"""

from __future__ import annotations

import html
import json
from typing import Any


def esc(value: Any) -> str:
    return html.escape(str(value or ""), quote=True)


def qr_column(qr_src: str) -> str:
    if not qr_src:
        return ""
    return (f'<div class="qr-col"><img class="qr" src="{esc(qr_src)}" alt="微信二维码">'
            f'<div class="qr-tip">长按二维码加我好友</div></div>')


def media_block(video_tags: list[str], image_urls: list[str], wm: str = "") -> str:
    parts = list(video_tags)
    for i, url in enumerate(image_urls):
        load = 'loading="eager"' if i < 3 else 'loading="lazy"'
        parts.append(f'<div class="cellwrap" onclick="openImg({i})">'
                     f'<img class="cell" src="{esc(url)}" {load} decoding="async" draggable="false" alt="">'
                     f'{wm}</div>')
    if not parts:
        return ""
    return '<div class="media">' + "".join(parts) + "</div>"


def video_tag(video_url: str, thumb_url: str) -> str:
    return (f'<div class="vwrap" onclick="playVideo(this,\'{esc(video_url)}\')">'
            f'<div class="vthumb" style="background-image:url(\'{esc(thumb_url)}\')"></div>'
            f'<div class="vplay">▶</div>'
            f'<video class="v" controls controlsList="nodownload" disablepictureinpicture '
            f'playsinline webkit-playsinline preload="none"></video></div>')


def card_block(name: str, phone: str, qr_src: str) -> str:
    qr = qr_column(qr_src)
    wrap = "qr-wrap center" if not qr_src else "qr-wrap"
    return f'''<section class="card">
      <div class="{wrap}">
        {qr}
        <div class="card-info">
          <div class="tag">米兰租赁管家 · 专业省心租好房</div>
          <div class="row"><span class="name">{esc(name)}</span><span class="num">{esc(phone)}</span></div>
          <div class="note">微信同号 · 24小时可约看房</div>
          <div class="btns">
            <a class="btn call" href="tel:{esc(phone)}">拨打电话</a>
            <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
          </div>
        </div>
      </div>
    </section>'''


def common_script(phone: str, track_script: str = "",
                  gallery: list[str] | None = None) -> str:
    gallery_js = json.dumps([str(u) for u in (gallery or [])], ensure_ascii=False)
    return f'''<div class="mask" id="mask" style="display:none" onclick="hideModal()"><img id="modalImg" src="" alt=""></div>
<div id="toast"></div>
<div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
<script>
var GALLERY={gallery_js};var gi=0;
function playVideo(w,src){{var v=w.querySelector('video');if(!v.src){{v.src=src;}}var p=v.play();if(p&&p.catch){{p.catch(function(){{}});}}w.className=w.className+' playing';}}
function openImg(i){{gi=i;show();}}
function show(){{var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}}
function lbPrev(){{gi=(gi-1+GALLERY.length)%GALLERY.length;show();}}
function lbNext(){{gi=(gi+1)%GALLERY.length;show();}}
function lbClose(){{document.getElementById('lb').style.display='none';}}
var _sx=0;(function(){{var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){{_sx=e.touches[0].clientX}},{{passive:true}});d.addEventListener('touchend',function(e){{var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){{dx<0?lbNext():lbPrev();}}}},{{passive:true}});}})();
function toast(msg){{var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){{t.style.display='none'}},1600);}}
function showModal(src){{document.getElementById("modalImg").src=src;document.getElementById("mask").style.display="flex";}}
function hideModal(){{document.getElementById("mask").style.display="none";}}
function copyPhone(){{var p='{esc(phone)}';function done(){{toast('已复制 '+p)}}function fb(){{var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}}if(navigator.clipboard&&window.isSecureContext){{navigator.clipboard.writeText(p).then(done,fb)}}else{{fb()}}}}
</script>
{track_script}'''


BASE_CSS = '''body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;margin:0;background:#f4f5f7;color:#1c1c1e;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;}
.wrap{max-width:640px;margin:0 auto;padding:0 16px 16px;}
.hero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;}
.type{font-size:30px;font-weight:700;margin:0 0 14px;}
.loc{display:flex;align-items:center;gap:8px;color:rgba(255,255,255,.92);text-decoration:none;}
.loc-name{font-size:15px;}
.nav-pill{display:inline-flex;align-items:center;gap:4px;background:rgba(255,255,255,.18);border-radius:999px;padding:6px 12px;font-size:13px;margin-left:auto;}
.l1{display:flex;justify-content:space-between;align-items:baseline;}
.room{font-size:30px;font-weight:700;}
.price{font-size:30px;font-weight:700;color:#f5c46b;}
.l2{display:flex;align-items:baseline;gap:14px;margin-top:12px;}
.pw{font-size:18px;color:rgba(255,255,255,.9);}
.layout2{font-size:18px;color:rgba(255,255,255,.9);}
.host{margin-left:auto;font-size:18px;color:rgba(255,255,255,.9);}
.remark{margin-top:10px;font-size:13px;color:rgba(255,255,255,.7);}
.sec{font-size:15px;color:#3a3a3c;margin:18px 4px 10px;font-weight:600;}
.media{background:#fff;border-radius:16px;padding:12px;}
.vwrap{position:relative;width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;margin-bottom:10px;background:#000;cursor:pointer;}
.vthumb{position:absolute;inset:0;background-size:cover;background-position:center;}
.vplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;color:#fff;font-size:28px;border:2px solid rgba(255,255,255,.85);}
.vwrap video{width:100%;height:100%;display:none;background:#000;}
.vwrap.playing .vthumb,.vwrap.playing .vplay{display:none;}
.vwrap.playing video{display:block;}
.cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;position:relative;}
.cell{width:100%;height:100%;object-fit:cover;display:block;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
.card{background:linear-gradient(180deg,#f7fafd,#e9f1f9);border:1px solid #dfe9f3;border-radius:16px;padding:14px;margin-top:12px;}
.qr-wrap{display:flex;align-items:center;gap:14px;}
.qr-wrap.center{justify-content:center;}
.qr-col{display:flex;flex-direction:column;align-items:center;gap:3px;flex-shrink:0;}
.qr-tip{font-size:10px;color:#8e8e93;text-align:center;max-width:108px;white-space:nowrap;line-height:1.3;}
.qr{width:108px;height:108px;border-radius:10px;object-fit:cover;flex-shrink:0;background:#fff;border:1px solid #e3e3e8;-webkit-touch-callout:default;-webkit-user-select:text;user-select:text;-webkit-user-drag:auto;}
.card-info{flex:1;min-width:0;text-align:center;}
.tag{color:#8e8e93;font-size:12px;margin-bottom:10px;}
.row{display:flex;align-items:center;justify-content:center;gap:8px;}
.name{font-size:17px;font-weight:600;}
.num{font-size:16px;font-weight:600;color:#b8860b;}
.note{color:#8e8e93;font-size:12px;margin:10px 0 14px;}
.btns{display:flex;gap:10px;justify-content:center;}
.btn{flex:1;max-width:220px;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;text-decoration:none;}
.btn.call{background:#1f3a5f;color:#fff;}
.btn.copy{background:#f0f0f2;color:#1c1c1e;border:none;}
.foot{text-align:center;color:#8e8e93;font-size:12px;padding:18px 0 26px;}
#toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 18px;border-radius:8px;font-size:14px;z-index:999;display:none;}
#lb{position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:999;display:none;}
#lbImg{position:absolute;inset:0;background-size:contain;background-position:center;background-repeat:no-repeat;}
#lbPrev{position:absolute;left:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
#lbNext{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
#lbClose{position:absolute;top:12px;right:12px;color:#fff;font-size:26px;padding:10px;cursor:pointer;user-select:none;}
#lbCnt{position:absolute;bottom:22px;left:0;right:0;text-align:center;color:rgba(255,255,255,.85);font-size:14px;user-select:none;}'''


def _head(title: str, desc: str, cover: str, share_url: str, css: str) -> str:
    cover_meta = f'<meta property="og:image" content="{esc(cover)}">' if cover else ""
    url_meta = f'<meta property="og:url" content="{esc(share_url)}">' if share_url else ""
    return f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:type" content="website">
{cover_meta}
{url_meta}
<title>{esc(title)}</title>
<style>
{css}
</style>
</head>'''


def masked_single(title: str, desc: str, name: str, phone: str,
                  video_tags: list[str], image_urls: list[str],
                  cover: str, qr: str, share_url: str, wm: str = "",
                  track_script: str = "") -> str:
    media = media_block(video_tags, image_urls, wm)
    body = f'''<body oncontextmenu="return false">
<div class="wrap">
<section class="hero">
  <h1 class="type">{esc(title)}</h1>
  <a class="loc" href="https://uri.amap.com/search?keyword=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E5%AF%93" target="_blank" rel="noopener">
    <span class="loc-name">利保米兰公馆</span>
    <span class="nav-pill"><svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a7 7 0 0 0-4 12.7V17a1 1 0 0 0 2 0v-1h4v1a1 1 0 0 0 2 0v-2.3A7 7 0 0 0 12 2zm0 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10zm0 3a2 2 0 1 0 0 4 2 2 0 0 0 0-4z"/></svg>导航</span>
  </a>
</section>
<h2 class="sec">实拍 · 点击放大</h2>
{media}
{card_block(name, phone, qr)}
<div class="foot">更多优质房源请与我联系-{esc(phone)}</div>
</div>
{common_script(phone, track_script, image_urls)}
</body>
</html>'''
    return _head(title, desc, cover, share_url, BASE_CSS) + body


def full_single(title: str, desc: str, info: dict[str, Any], name: str, phone: str,
                video_tags: list[str], image_urls: list[str],
                cover: str, qr: str, share_url: str, wm: str = "",
                track_script: str = "") -> str:
    media = media_block(video_tags, image_urls, wm)
    host = f'<span class="host">{esc(info.get("landlord"))}</span>' if info.get("landlord") else ""
    pw = f'<span class="pw">密码：{esc(info.get("password"))}</span>' if info.get("password") else ""
    remark = f'<div class="remark">{esc(info.get("remark"))}</div>' if info.get("remark") else ""
    layout = esc(info.get("layout") or "房源")
    body = f'''<body oncontextmenu="return false">
<div class="wrap">
<section class="hero">
  <div class="l1"><span class="room">{esc(info.get("displayRoomNo"))}</span><span class="price">{esc(info.get("priceText"))}</span></div>
  <div class="l2">{pw}<span class="layout2">{layout}</span>{host}</div>
  {remark}
</section>
<h2 class="sec">实拍 · 点击放大</h2>
{media}
{card_block(name, phone, qr)}
<div class="foot">更多优质房源请与我联系-{esc(phone)}</div>
</div>
{common_script(phone, track_script, image_urls)}
</body>
</html>'''
    return _head(title, desc, cover, share_url, BASE_CSS) + body


COLLECTION_CSS = BASE_CSS + '''
.hero2{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px;margin-top:14px;}
.coll-title{font-size:26px;font-weight:700;margin:0 0 8px;}
.coll-sub{font-size:14px;color:rgba(255,255,255,.85);}
.items{margin-top:12px;}
.item{display:flex;gap:12px;background:#fff;border-radius:14px;padding:12px;margin-bottom:10px;align-items:center;}
.thumb{width:96px;height:72px;border-radius:10px;object-fit:cover;display:block;background-color:#e8e8ec;flex-shrink:0;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
.meta{flex:1;min-width:0;}
.rno{font-size:17px;font-weight:700;color:#1c1c1e;}
.sub2{font-size:13px;color:#8e8e93;margin-top:4px;}
.back{display:block;width:100%;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;background:#fff;color:#1f3a5f;border:1px solid #dfe1e6;margin:14px 0 4px;text-decoration:none;}
.dhero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;margin-top:14px;}'''


def collection(rooms: list[dict[str, Any]], mode: str, name: str, phone: str,
               cover: str, qr: str, share_url: str, wm: str = "",
               track_script: str = "") -> str:
    count = len(rooms)
    title = f"已为你挑选{count}套优质房源"
    if mode == "full":
        prices = [int(r.get("price") or 0) for r in rooms]
        min_price = min(prices) if prices else 0
        desc = f"精选{count}套房源 · 起租¥{min_price}\n{name}-{phone}" if min_price else f"精选{count}套房源\n{name}-{phone}"
    else:
        desc = f"利保米兰公馆\n{name}-{phone}"

    items_html: list[str] = []
    detail_parts: list[str] = []
    gallery: list[str] = []
    cursor = 0
    for room in rooms:
        thumb = room.get("cover_url") or ""
        if mode == "masked":
            meta = (f'<div class="meta"><div class="rno">{esc(room.get("layout") or "房源")}</div>'
                    f'<div class="sub2">利保米兰公馆</div></div>')
        else:
            meta = (f'<div class="meta"><div class="rno">{esc(room.get("displayRoomNo"))}</div>'
                    f'<div class="sub2">{esc(room.get("priceText"))} · {esc(room.get("layout") or "房源")}</div></div>')
        img = f'<img class="thumb" src="{esc(thumb)}" draggable="false" alt="">' if thumb else '<img class="thumb" draggable="false" alt="">'
        items_html.append(f'<div class="item" onclick="showDetail({len(detail_parts)})">{img}{meta}</div>')

        detail = _collection_detail(room, mode, name, phone, qr, cursor, wm)
        cursor += len(room.get("image_urls") or [])
        gallery.extend(room.get("image_urls") or [])
        detail_parts.append(json.dumps(detail, ensure_ascii=False))

    items = "\n".join(items_html)
    details_js = ",".join(detail_parts)
    gallery_js = json.dumps(gallery, ensure_ascii=False)
    qr_block = card_block(name, phone, qr)
    body = f'''<body oncontextmenu="return false">
<div class="wrap">
<div id="listView">
  <div class="hero2">
    <h1 class="coll-title">{esc(title)}</h1>
    <div class="coll-sub">点击房源卡片查看详情</div>
  </div>
  <div class="items">
{items}
  </div>
  {qr_block}
  <div class="foot">更多优质房源请与我联系-{esc(phone)}</div>
</div>
<div id="detailView" style="display:none">
  <button class="back" type="button" onclick="showList()">‹ 返回房源列表</button>
  <div id="detailBody"></div>
  <button class="back" type="button" onclick="showList()">返回房源列表</button>
</div>
</div>
<div class="mask" id="mask" style="display:none" onclick="hideModal()"><img id="modalImg" src="" alt=""></div>
<div id="toast"></div>
<div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
<script>
var GALLERY={gallery_js};var gi=0;
function playVideo(w,src){{var v=w.querySelector('video');if(!v.src){{v.src=src;}}var p=v.play();if(p&&p.catch){{p.catch(function(){{}});}}w.className=w.className+' playing';}}
var ROOMS=[{details_js}];
function showDetail(i){{document.getElementById('listView').style.display='none';document.getElementById('detailView').style.display='block';document.getElementById('detailBody').innerHTML=ROOMS[i];window.scrollTo(0,0);}}
function showList(){{document.getElementById('detailView').style.display='none';document.getElementById('listView').style.display='block';window.scrollTo(0,0);}}
function openImg(i){{gi=i;show();}}
function show(){{var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}}
function lbPrev(){{gi=(gi-1+GALLERY.length)%GALLERY.length;show();}}
function lbNext(){{gi=(gi+1)%GALLERY.length;show();}}
function lbClose(){{document.getElementById('lb').style.display='none';}}
var _sx=0;(function(){{var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){{_sx=e.touches[0].clientX}},{{passive:true}});d.addEventListener('touchend',function(e){{var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){{dx<0?lbNext():lbPrev();}}}},{{passive:true}});}})();
function toast(msg){{var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){{t.style.display='none'}},1600);}}
function showModal(src){{document.getElementById("modalImg").src=src;document.getElementById("mask").style.display="flex";}}
function hideModal(){{document.getElementById("mask").style.display="none";}}
function copyPhone(){{var p='{esc(phone)}';function done(){{toast('已复制 '+p)}}function fb(){{var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}}if(navigator.clipboard&&window.isSecureContext){{navigator.clipboard.writeText(p).then(done,fb)}}else{{fb()}}}}
</script>
{track_script}
</body>
</html>'''
    return _head(title, desc, cover, share_url, COLLECTION_CSS) + body


def _collection_detail(room: dict[str, Any], mode: str, name: str, phone: str,
                       qr: str, start_index: int, wm: str) -> str:
    parts = ['<div class="dhero">']
    if mode == "masked":
        parts.append(f'<div class="type">{esc(room.get("layout") or "房源")}</div>')
        parts.append('''<a class="loc" href="https://uri.amap.com/search?keyword=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E5%AF%93" target="_blank" rel="noopener">
          <span class="loc-name">利保米兰公馆</span><span class="nav-pill">导航</span></a>''')
    else:
        parts.append(f'<div class="l1"><span class="room">{esc(room.get("displayRoomNo"))}</span>'
                     f'<span class="price">{esc(room.get("priceText"))}</span></div>')
        l2 = '<div class="l2">'
        if room.get("password"):
            l2 += f'<span class="pw">密码：{esc(room.get("password"))}</span>'
        l2 += f'<span class="layout2">{esc(room.get("layout") or "房源")}</span>'
        if room.get("landlord"):
            l2 += f'<span class="host">{esc(room.get("landlord"))}</span>'
        l2 += "</div>"
        parts.append(l2)
        if room.get("remark"):
            parts.append(f'<div class="remark">{esc(room.get("remark"))}</div>')
    parts.append("</div>")
    media = ['<h2 class="sec">实拍 · 点击放大</h2><div class="media">']
    media.extend(room.get("video_tags") or [])
    for offset, url in enumerate(room.get("image_urls") or []):
        load = 'loading="eager"' if offset < 3 else 'loading="lazy"'
        media.append(f'<div class="cellwrap" onclick="openImg({start_index + offset})">'
                     f'<img class="cell" src="{esc(url)}" {load} decoding="async" draggable="false" alt="">{wm}</div>')
    media.append("</div>")
    parts.append("".join(media))
    parts.append(card_block(name, phone, qr))
    return "".join(parts)


LIST_CSS = '''*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent;}
html,body{background:#f4f5f7;color:#1a1c20;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",system-ui,sans-serif;}
html,body{height:100%;}
body{max-width:560px;margin:0 auto;padding:0 16px 24px;display:flex;flex-direction:column;min-height:100%;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-user-drag:none;}
body *{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-user-drag:none;}
.main{flex:1 0 auto;width:100%;}
.head{display:flex;align-items:center;justify-content:space-between;padding:16px 2px 6px;}
h1{font-size:19px;font-weight:700;color:#1a1c20;letter-spacing:.5px;}
.refresh{color:#1f7a4d;font-size:14px;font-weight:600;background:none;border:none;padding:6px 8px;}
.filters{display:flex;gap:8px;flex-wrap:wrap;padding:10px 2px 4px;}
.chip{padding:5px 13px;border-radius:15px;background:#eef0f2;color:#5b616e;font-size:13px;border:none;}
.chip.on{background:#1f7a4d;color:#fff;font-weight:600;}
#count{font-size:13px;color:#8a919e;padding:4px 2px 2px;}
#loading{text-align:center;color:#8a919e;padding:50px 0;font-size:14px;}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;padding:12px 0;}
.card{position:relative;border-radius:12px;overflow:hidden;background:#fff;aspect-ratio:1/1;box-shadow:0 1px 4px rgba(0,0,0,.06);}
.cover{position:absolute;inset:0;}
.cover img{width:100%;height:100%;object-fit:cover;display:block;}
.ph{width:100%;height:100%;background:linear-gradient(135deg,#dfe3e8,#c6cdd6);}
.play{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:46px;height:46px;border-radius:50%;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;}
.play::after{content:"";border-left:14px solid #fff;border-top:9px solid transparent;border-bottom:9px solid transparent;margin-left:3px;}
.type-tag{position:absolute;left:8px;bottom:8px;background:rgba(0,0,0,.55);color:#fff;font-size:12px;padding:3px 9px;border-radius:10px;}
#empty{display:none;text-align:center;color:#8a919e;padding:60px 0;font-size:14px;}
#mask{display:none;position:fixed;inset:0;background:rgba(0,0,0,.92);z-index:50;align-items:center;justify-content:center;}
#mask img{max-width:92%;max-height:88%;border-radius:8px;}
#mask .x{position:absolute;top:44px;right:18px;color:#fff;font-size:30px;line-height:1;padding:8px;}
#toast{position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:9px 16px;border-radius:8px;font-size:13px;opacity:0;pointer-events:none;transition:opacity .2s;z-index:60;}
#toast.show{opacity:1;}
.person{margin-top:auto;background:#fff;border-radius:12px;padding:14px 14px 12px;box-shadow:0 1px 4px rgba(0,0,0,.06);}
.person .top{display:flex;gap:12px;align-items:flex-start;}
.person .avatar{width:48px;height:48px;border-radius:50%;background:#1f7a4d;color:#fff;display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:700;flex-shrink:0;}
.person .nm{font-size:16px;font-weight:700;}
.person .ph-t{font-size:14px;color:#5b616e;margin-top:2px;}
.person .btns{display:flex;gap:10px;margin-top:12px;}
.person .btn{flex:1;text-align:center;padding:10px 0;border-radius:10px;font-size:14px;}
.person .call{background:#1f7a4d;color:#fff;font-weight:600;}
.person .copy{background:#f0f2f4;color:#1a1c20;}
.qr-row{display:none;margin-top:10px;background:#fff;border-radius:12px;padding:12px;text-align:center;}
.qr-row img{width:110px;height:110px;border-radius:6px;}
.qr-row p{font-size:12px;color:#8a919e;margin-top:6px;}'''


def rooms_list(rooms: list[dict[str, Any]], name: str, phone: str, qr: str,
               share_url: str, cover: str, wm: str = "", track_script: str = "") -> str:
    data = []
    for r in rooms:
        data.append({
            "layout": r.get("layout") or "房源",
            "cover": r.get("cover_url") or "",
            "share": r.get("share_url") or "",
        })
    rooms_js = json.dumps(data, ensure_ascii=False)
    qr_block = ""
    if qr:
        qr_block = f'<div class="qr-row" id="qrCol"><img id="qrImg" src="{esc(qr)}" alt="二维码"><p>扫码加微信 直接看房</p></div>'
    body = f'''<body>
<div class="main">
  <div class="head"><h1>米兰公馆 · 在租房源</h1><button class="refresh" id="refreshBtn">刷新</button></div>
  <div class="filters" id="filters"></div>
  <div id="count"></div>
  <div id="loading">加载中...</div>
  <div class="grid" id="list"></div>
  <div id="empty">暂无待租房源</div>
</div>
<div class="person" id="cardShare">
  <div class="top">
    <div class="avatar" id="avatar">{esc((name or '梁')[0] if name else '梁')}</div>
    <div>
      <div class="nm" id="nameText">{esc(name or '梁涛')}</div>
      <div class="ph-t" id="phoneText">{esc(phone or '13288251132')}</div>
      <div style="font-size:12px;color:#8a919e;margin-top:2px;">微信同号 · 24小时可约看房</div>
    </div>
  </div>
  <div class="btns">
    <div class="btn call" id="callBtn">拨打电话</div>
    <div class="btn copy" id="copyBtn">复制电话</div>
  </div>
</div>
{qr_block}
<div id="mask" onclick="this.style.display='none'"><span class="x">×</span><img id="modalImg" alt=""></div>
<div id="toast"></div>
<script>
var ROOMS={rooms_js};
var curFilter="全部";
function esc(s){{var d=document.createElement("div");d.textContent=(s||"");return d.innerHTML;}}
function render(){{
  var rows=ROOMS;
  if(curFilter!=="全部"){{rows=ROOMS.filter(function(h){{return h.layout===curFilter;}});}}
  document.getElementById("count").textContent="共 "+rows.length+" 套待租房源"+(curFilter!=="全部"?"（"+curFilter+"）":"");
  var list=document.getElementById("list");
  list.innerHTML=rows.map(function(h,i){{
    var cover=h.cover||"";
    var inner=cover?'<img class="cv" src="'+cover+'" alt="" loading="lazy" onerror="this.remove()">':'<div class="ph"></div>';
    return '<div class="card" data-i="'+i+'"><div class="cover">'+inner+'<span class="play"></span><span class="type-tag">'+esc(h.layout)+'</span></div></div>';
  }}).join("");
  document.getElementById("empty").style.display=rows.length?"none":"block";
  document.getElementById("loading").style.display="none";
}}
function buildFilters(){{
  var kinds=["全部"];
  ROOMS.forEach(function(h){{if(kinds.indexOf(h.layout)<0)kinds.push(h.layout);}});
  document.getElementById("filters").innerHTML=kinds.map(function(k){{
    return '<span class="chip'+(curFilter===k?" on":"")+'" data-k="'+k+'">'+k+'</span>';
  }}).join("");
}}
var toastTimer;
function showToast(msg){{var t=document.getElementById("toast");t.textContent=msg;t.classList.add("show");clearTimeout(toastTimer);toastTimer=setTimeout(function(){{t.classList.remove("show");}},1600);}}
function showModal(src){{document.getElementById("modalImg").src=src;document.getElementById("mask").style.display="flex";}}
document.getElementById("list").addEventListener("click",function(e){{
  var card=e.target.closest(".card");if(!card)return;
  var h=ROOMS[parseInt(card.getAttribute("data-i"))];if(!h)return;
  if(h.share){{location.href=h.share;return;}}
  if(h.cover){{showModal(h.cover);}}
}});
function copyPhone(){{
  var p=document.getElementById("phoneText").textContent;
  function done(){{showToast("已复制 "+p);}}
  function fb(){{var i=document.createElement("input");i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand("copy");i.remove();done();}}
  if(navigator.clipboard&&window.isSecureContext){{navigator.clipboard.writeText(p).then(done,fb);}}else{{fb();}}
}}
document.getElementById("filters").addEventListener("click",function(e){{
  var chip=e.target.closest(".chip");if(!chip)return;
  curFilter=chip.getAttribute("data-k");buildFilters();render();
}});
document.getElementById("refreshBtn").addEventListener("click",function(){{location.reload();}});
document.getElementById("copyBtn").addEventListener("click",copyPhone);
document.getElementById("callBtn").addEventListener("click",function(){{var p=document.getElementById("phoneText").textContent;location.href="tel:"+p.replace(/[^0-9]/g,"");}});
buildFilters();render();
</script>
{track_script}
</body>
</html>'''
    desc = "实时更新的在租房源列表，点击查看户型。更多优质房源请与我联系。"
    return _head("米兰公馆 · 在租房源", desc, cover, share_url, LIST_CSS) + body


def simple_error(title: str, message: str) -> str:
    css = '''body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;background:#f4f5f7;color:#1c1c1e;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;}
.box{background:#fff;border-radius:16px;padding:32px 24px;text-align:center;max-width:320px;box-shadow:0 2px 12px rgba(0,0,0,.06);}
h1{font-size:20px;margin:0 0 10px;}p{font-size:14px;color:#8e8e93;margin:0;}'''
    return f'''<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{esc(title)}</title><style>{css}</style></head><body><div class="box"><h1>{esc(title)}</h1><p>{esc(message)}</p></div></body></html>'''
