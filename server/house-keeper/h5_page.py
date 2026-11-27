#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公寓管家 · 公开分享 H5 静态壳（服务器本地托管，不依赖 COS / 旧云函数）
=====================================================================
单页应用：
  - `/api/public/h5?roomKey=<房号>`  → 单房卡片（户型 / 租金 / 实拍图文视频 / 名片）
  - `/api/public/h5`                → 公开选房列表（全部待租房源，脱敏）
数据走免鉴权公开接口：`/api/public/rooms[?roomKey=]`、`/api/public/profile`，
媒体走 `/api/public/media/<objectKey>`。页面不含房号 / 房东 / 备注等内部信息。
"""

HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>房源信息</title>
<style>
:root{--bg:#f5f6f8;--card:#fff;--ink:#1c1c1e;--sub:#8a8a8e;--line:#ececec;--brand:#2f6fed;--price:#e8543f;--radius:14px}
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;padding-bottom:48px}
.wrap{max-width:640px;margin:0 auto;padding:14px}
.topbar{position:sticky;top:0;background:rgba(245,246,248,.92);backdrop-filter:blur(8px);padding:12px 14px;display:flex;align-items:center;gap:8px;z-index:5}
.topbar a{color:var(--brand);text-decoration:none;font-size:16px}
.topbar h1{font-size:17px;font-weight:600}
.card{background:var(--card);border-radius:var(--radius);padding:16px;margin-bottom:14px;box-shadow:0 1px 4px rgba(0,0,0,.05)}
.meta-row{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
.layout{font-size:20px;font-weight:700}
.tower{color:var(--sub);font-size:14px}
.price{font-size:22px;font-weight:700;color:var(--price);margin-left:auto}
.price small{font-size:13px;font-weight:400;color:var(--sub)}
.media-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin-top:14px}
.media-grid figure{border-radius:10px;overflow:hidden;background:#eee;aspect-ratio:4/3}
.media-grid img,.media-grid video{width:100%;height:100%;object-fit:cover;display:block}
.badge{display:inline-block;background:#eef3ff;color:var(--brand);font-size:12px;padding:3px 8px;border-radius:6px;margin-left:6px}
.profile{display:flex;align-items:center;gap:14px;margin-top:4px}
.profile img.qr{width:88px;height:88px;border-radius:10px;border:1px solid var(--line)}
.profile .who{flex:1}
.profile .name{font-size:17px;font-weight:600}
.profile .phone{color:var(--sub);font-size:15px;margin-top:4px}
.actions{display:flex;gap:10px;margin-top:14px}
.btn{flex:1;text-align:center;text-decoration:none;border-radius:12px;padding:13px 0;font-size:16px;font-weight:600}
.btn.call{background:var(--brand);color:#fff}
.btn.copy{background:#fff;color:var(--brand);border:1px solid var(--brand)}
.room-item{display:flex;gap:12px;align-items:center;padding:13px 16px;text-decoration:none;color:var(--ink);background:var(--card);border-radius:var(--radius);margin-bottom:12px;box-shadow:0 1px 4px rgba(0,0,0,.05)}
.room-item .thumb{width:72px;height:72px;border-radius:10px;background:#eee;object-fit:cover;flex:none}
.room-item .info{flex:1;min-width:0}
.room-item .info .t{font-size:16px;font-weight:600}
.room-item .info .s{color:var(--sub);font-size:13px;margin-top:5px}
.room-item .p{color:var(--price);font-weight:700}
.empty{text-align:center;color:var(--sub);padding:60px 20px}
.loading{text-align:center;color:var(--sub);padding:40px}
</style>
</head>
<body>
<div class="topbar"><a id="back" href="/api/public/h5" style="display:none">‹ 返回</a><h1 id="title">房源信息</h1></div>
<div class="wrap" id="app"><div class="loading">加载中…</div></div>
<script>
function qs(k){var p=new URLSearchParams(location.search);return p.get(k)||""}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]})}
function mediaUrl(rel){return "/api/public/media/"+encodeURIComponent(rel)}
function withProfile(href){var n=qs("n"),p=qs("p");if(!n&&!p){return href}return href+(href.indexOf("?")>=0?"&":"?")+"n="+encodeURIComponent(n)+"&p="+encodeURIComponent(p)}
function mediaTag(m){
  var url=mediaUrl(m.objectKey||m.fileName||"");
  if(m.kind==="video"){return '<video src="'+url+'" preload="none" controls playsinline></video>'}
  return '<img src="'+url+'" alt="" loading="lazy">';
}
function localProfile(){
  // 姓名/电话只随分享链接参数传入，服务器不保存；二维码不上服务器，页面不展示
  return {name:qs("n"), phone:qs("p")};
}
function profileHTML(p){
  p=p||{};
  if(!p.name && !p.phone){return ""}
  var who='<div class="who"><div class="name">'+esc(p.name||"房东")+'</div>'+(p.phone?'<div class="phone">'+esc(p.phone)+'</div>':"")+'</div>';
  var call=p.phone?'<a class="btn call" href="tel:'+esc(p.phone)+'">拨打电话</a>':"";
  return '<div class="card"><div class="profile">'+who+'</div>'+(call?'<div class="actions">'+call+'</div>':"")+'</div>';
}
async function getJSON(u){var r=await fetch(u);if(!r.ok)throw new Error("http "+r.status);return r.json()}

async function renderSingle(key){
  document.getElementById("back").style.display="";
  document.getElementById("title").textContent="房源详情";
  var app=document.getElementById("app");
  try{
    var d=await getJSON("/api/public/rooms/"+encodeURIComponent(key));
    if(!d.ok){app.innerHTML='<div class="empty">该房源暂不可见</div>';return}
    var h='<div class="card"><div class="meta-row"><span class="layout">'+esc(d.layout||"户型")+'</span>'+
      '<span class="tower">'+esc((d.tower||"")+" "+(d.roomNo||""))+'</span>'+
      '<span class="price">¥'+esc(d.price||"")+'<small> /月</small></span></div>';
    if(d.media&&d.media.length){h+='<div class="media-grid">'+d.media.map(function(m){return "<figure>"+mediaTag(m)+"</figure>"}).join("")+"</div>"}
    h+="</div>"+profileHTML(localProfile());
    app.innerHTML=h;
  }catch(e){app.innerHTML='<div class="empty">加载失败，请稍后再试</div>'}
}

async function renderList(){
  document.getElementById("back").style.display="none";
  document.getElementById("title").textContent="在租房源";
  var app=document.getElementById("app");
  try{
    var d=await getJSON("/api/public/rooms");
    var rooms=d.rooms||[];
    if(!rooms.length){app.innerHTML='<div class="empty">暂无可看房源</div>';return}
    var h=rooms.map(function(r){
      var thumb=r.media&&r.media.length?'<img class="thumb" src="'+mediaUrl((r.media.find(function(m){return m.kind!=="video"})||r.media[0]).objectKey)+'">':"";
      return '<a class="room-item" href="'+esc(withProfile("/api/public/h5?roomKey="+encodeURIComponent(r.roomKey)))+'">'+thumb+
        '<div class="info"><div class="t">'+esc(r.layout||"户型")+'</div><div class="s">'+esc((r.tower||"")+" "+(r.roomNo||""))+'</div></div>'+
        '<div class="p">¥'+esc(r.price||"")+'</div></a>';
    }).join("");
    app.innerHTML=h+profileHTML(localProfile());
  }catch(e){app.innerHTML='<div class="empty">加载失败，请稍后再试</div>'}
}

var key=qs("roomKey");
if(key){renderSingle(key)}else{renderList()}
</script>
</body>
</html>
"""


def page_html() -> str:
    return HTML
