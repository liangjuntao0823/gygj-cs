# meter-watch · 公寓管家电表云端值守

> 迁移原则：逐功能慢迁，正式仓 `gy-gj` 与线上体系不动；本目录位于私有试验仓 `gygj-cs`。
> 服务器只跑“值守执行 + 同步 API”，**所有设置入口与权威数据都在公寓管家 App**。

## 1. 它做什么

```
公寓管家 App（唯一设置入口）
  │  ① 首次：接入码 enroll 换长期 token（存手机钥匙串）
  │  ② 开“云端值守”：PUT 查询链接/openId、阈值、提醒开关、电表清单（全量同步）
  │  ③ 改阈值 / 新增 / 删除 / 备注电表 → 防抖全量 PUT
  │  ④ 进电表首页（开关开时）→ GET 最近一轮云端快照展示
  ▼
meter-watch（本服务，114.132.93.85:8082，独立 systemd）
  ├─ 同步 API（meter_api.py，Bearer 鉴权，不做网页后台）
  ├─ 值守线程（meter_watch.py Engine，默认 1800s=30 分钟一轮）
  │     └─ 只读查询 http://wy.mlh-china.com（微信 UA + 表单，口径同 iOS MeterQueryService）
  │           index(openId)→wechatId → electricMeterQuery(wechatId,uid)
  ├─ tenants.json  App 同步的租户配置（API 写，worker 每轮重读，原子替换）
  ├─ state.json    最近读数 + 告警去重/边沿状态（仅 worker 写）
  └─ Bark 推送 → 127.0.0.1:8081 自建 bark-server → 苹果 APNs → iPhone
```

- 低电量：合闸且 `0 < 剩余电量 < App 同步阈值`，首次进入低电量**当轮立即推**，持续低电量每 24h 复提醒一次；回升阈值推一条恢复。
- 拉闸：状态变为“拉闸”**当轮立即推**，持续拉闸每 24h 复提醒；恢复合闸推一条恢复。
- 整组连续 `failure_alert_rounds`（默认 3）轮查询失败推运维异常，恢复后推恢复。
- 告警去重状态落 `state.json`，服务重启不会重复轰炸；`shengyu=0 且合闸` 视为平台异常空值，不据此误报低电量（真断电通常状态为“拉闸”）。
- “实时”上限 = 30 分钟轮询周期 + 第三方平台自身抄表更新间隔，不是秒级。

## 2. 文件

| 文件 | 作用 |
|---|---|
| `meter_watch.py` | 平台只读客户端、Bark 客户端、`Store`(service/tenants/state)、值守 `Engine`、CLI |
| `meter_api.py` | HTTP 同步 API + `serve()`：API 线程与值守主线程，systemd 入口 |
| `test_meter_watch.py` | 10 个离线单测（平台解析/告警去重恢复/失败自愈/API 鉴权同步闭环），不连外网 |
| `service.example.json` | 运维侧配置模板；首次启动若 `service.json` 缺失会自动生成（含随机 `enroll_code`） |
| `meter-watch.service` | systemd 单元（独立用户目录、加固项、`Restart=always`） |
| `.gitignore` | 忽略 `service.json/tenants.json/state.json/*.tmp/__pycache__`，机密与业务数据永不入库 |

运行期三个 JSON（部署目录 `/opt/meter-watch/`，权限 600）：

- `service.json`：运维侧（监听、bark 回环地址、默认 bark keys、轮询/限速/复提醒间隔、`enroll_code`）。改监听/轮询/bark 后需 `systemctl restart meter-watch`。
- `tenants.json`：以长期 tenant token 为键，App API 写入：`enabled/device/settings/meters/bark_keys/updated_at`。
- `state.json`：每租户 `last_round_at/last_ok_at/consecutive_failures/meters{uid:{读数,告警边沿}}`。

## 3. 服务器部署（Ubuntu 24.04，自带 Python 3.12，无需 pip）

```bash
# 本机（开发机）上传
ssh ubuntu@114.132.93.85 'sudo mkdir -p /opt/meter-watch && sudo chown ubuntu:ubuntu /opt/meter-watch'
scp meter_watch.py meter_api.py meter-watch.service ubuntu@114.132.93.85:/opt/meter-watch/

# 服务器上
cd /opt/meter-watch
python3 meter_watch.py --validate        # 首次会生成 service.json，并打印打码的 enroll_code
# 编辑 service.json：
#   default_bark_keys: ["当前iPhone的Bark Key"]   # 可 curl -s http://127.0.0.1:8081/info 核对，勿硬编码进仓库
#   poll_interval_seconds: 1800
chmod 600 service.json 2>/dev/null || true
python3 test_meter_watch.py 2>/dev/null || true    # 可选：把测试文件也传上去跑
sudo cp meter-watch.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now meter-watch
systemctl --no-pager --full status meter-watch
journalctl -u meter-watch -n 80 --no-pager
curl -s http://127.0.0.1:8082/api/meter/health
```

常用运维：

```bash
journalctl -u meter-watch -f
sudo systemctl restart meter-watch
python3 /opt/meter-watch/meter_watch.py --config-dir /opt/meter-watch --validate
python3 /opt/meter-watch/meter_watch.py --config-dir /opt/meter-watch --once --dry-run
```

回滚卸载（**不影响** `bark-server.service`(8081)、`jianli-majiang.service`(8878)、`/opt/certbot`）：

```bash
sudo systemctl disable --now meter-watch
sudo rm -f /etc/systemd/system/meter-watch.service && sudo systemctl daemon-reload
sudo rm -rf /opt/meter-watch
```

## 4. HTTP API 契约（iOS `MeterCloudSync` 对齐）

Base URL 默认 `http://114.132.93.85:8082`（App 云端值守区可改）。除 health/enroll 外均需请求头 `Authorization: Bearer <tenantToken>`。所有响应 JSON 带 `Cache-Control: no-store`。

### GET `/api/meter/health`
无鉴权探针：`{ok, service, time, tenants, enabled}`（不含明细）。

### POST `/api/meter/enroll`
请求：`{ "code": "部署侧 enroll_code", "device": "iPhone 标识" }`
成功 `200`：`{ok:true, token:"<48 hex>", token_type:"Bearer"}`；接入码错误 `403`；同 IP 10 分钟失败超 10 次 `429`。token 仅本次明文返回，App 存入 Keychain（建议 key `meter.cloud.token`）。

### GET `/api/meter/config`
返回当前租户已同步配置（Bark key 仅回数量与打码）：
`{ok, enabled, device, updated_at, settings:{queryLink,openId,lowThreshold,lowAlertEnabled,provider}, meters:[{uid,room,pinned}], barkKeysCount, barkKeysMasked}`。

### PUT `/api/meter/config`（全量 upsert，App 每次变更防抖后提交）
```json
{
  "enabled": true,
  "device": "iPhone",
  "settings": {
    "queryLink": "http://wy.mlh-china.com/electricmeter/?openId=xxx",
    "openId": "xxx",
    "lowThreshold": 30,
    "lowAlertEnabled": true,
    "provider": "direct"
  },
  "meters": [
    {"uid": "1002334xxxx", "room": "1-2334上", "pinned": false}
  ],
  "barkKeys": []
}
```
- 服务端以最近一次 PUT 的 `settings/meters` **全量覆盖**该租户（天然支持改阈值、新增、删除、改备注、换链接）；`meters` 按 uid 去重、最多 500 台，阈值 clamp 到 1–9999。
- `barkKeys` 可省略（省略时保留服务端已有值；都没有则用 `service.default_bark_keys`）。
- `enabled:true` 的 PUT 会唤醒值守线程尽快跑一轮（worker 内 3s 合并防抖），不必等满 30 分钟。
- 返回 `{ok, enabled, meters, updated_at}`；坏 JSON/超大 body `400`；无 token `401`。

### GET `/api/meter/state`（App 进电表首页拉云端快照）
```json
{
  "ok": true, "server_time": 1764000000.0, "enabled": true,
  "last_round_at": 1764000000.0, "last_ok_at": 1764000000.0,
  "consecutive_failures": 0, "last_error": "",
  "meters": [
    {"uid":"...", "room":"1-2334上", "shengyu":18.2, "leiji":123.4,
     "zhuangtai":"合闸", "shijian":"2026-11-24 13:30:00", "last_ok_ts":1764000000.0}
  ]
}
```
App 合并建议：按平台 `shijian`/`last_ok_ts` 较新者覆盖本地展示字段，避免旧云快照覆盖手机刚手动刷新的新值；房号等台账仍以本地+PUT 清单为准。

### POST `/api/meter/test-push`
向该租户 Bark 设备发测试条：`{ok, sent, total}`；无设备 `total=0`。

## 5. App 端改造口径（#235 / #236，在 `gygj-cs` 私有仓）

- 现有电表主页与“电表设置”既有项目**布局/逻辑不动**；只在 `MeterSettingsDetailView` 最底部新增「云端值守」Section：总开关 + 服务器地址（默认 `http://114.132.93.85:8082`，可改）+ 首次填写接入码（换取 token 存 `KeychainStore`，复用 `AgentTool/HouseKeeper/Services/CosUploader.swift` 的 `KeychainStore`）+ 同步状态/测试推送。
- 不新增 Swift 文件（工程 `project.pbxproj` 为传统显式引用，新增文件需改工程文件、CI 风险高）：`MeterCloudSync` 追加进现有 `MeterStore.swift`。
- 触发点收敛在 `MeterStore.saveSettings()` / `saveMeters()`：开关开时 debounce ≈1.5s 全量 PUT；网络失败不影响本地，标记 dirty 下次保存/进页重试。关开关 PUT `enabled:false`（服务器停止该租户值守，配置保留以便再次开启）。
- 首页双模式（`MeterBoardView.swift`）：
  - 开关**关**：完全保持 2.72 现状（不自动刷新，手动/下拉刷新，显示最后本地读数）。
  - 开关**开**：`.onAppear` 节流（≥60s）调 `GET /api/meter/state` 合并展示；手动刷新按钮保留（直连平台即时查询）。尽量复用卡片第三行 `shijian` 显示数据时间，不新增视觉元素。

## 6. 隐私与安全（现状与待办）

- `service.json/tenants.json/state.json` 含接入码、tenant token、openId、户号、房号、电量，部署目录权限 600、属主 ubuntu；**禁止提交 git、禁止贴公开文档/聊天长留**。
- 初版 API 为明文 HTTP（第三方电表平台本身也是 HTTP，openId 在“服务器→电表平台”一段无法由我方单独加密）。公网暴露 8082 前必须：强随机 enroll/token（已具备）+ 腾讯云安全组限制来源；随后随 Bark 加固 #233 上域名 + TLS 反代（或 Caddy 自动证书），App 端默认地址再切 `https://`。
- 日志对 token/openId/Bark key 打码；API 不提供任何修改/充值电表平台的写操作，仅只读查询与本机配置同步。
- Bark 走服务器回环 `127.0.0.1:8081`，消息不经过 `api.day.app`；iOS 推送仍必经苹果 APNs（系统机制）。

## 7. 验收清单

- [x] `python3 -m unittest -v test_meter_watch`：10 项通过（2026-11-24 vm 开发环境）。
- [ ] 服务器 `--validate`、`/api/meter/health` 本机 200、systemd active + 开机自启。
- [ ] 安全组/公网 `https?://114.132.93.85:8082/api/meter/health` 按部署方案可达性确认。
- [ ] 真实 openId：`--bindings` 拉到户号；`--once` 核对每表 `shijian` 新鲜度与数值。
- [ ] Bark 真机收到低电量/拉闸/恢复/异常演示（`--demo` 与构造阈值）。
- [ ] App 开关：enroll→PUT→服务器热生效；改阈值/增删电表服务器同步变化；关开关停止值守。
- [ ] 开关开时进电表页自动显示云端快照；关时维持纯手动模式。
- [ ] 私有仓 CI 出测试 IPA（测试期只递增 `CURRENT_PROJECT_VERSION`，`MARKETING_VERSION` 不升）并交付本体。

## 8. 待用户提供 / 未决

1. 真实电表查询链接（可等测试包在 App 内粘贴，也可先提供给服务器做真机联调；属隐私凭据，仅写服务器 600 文件，不入 git）。
2. 户号 ↔ 房号规则与 3–5 个样例（用于自动预填房号；规则覆盖不到的仍可 App 手改备注）。
3. 8082 公网放行方式：腾讯云安全组来源限制，或直接推进域名 + HTTPS（与 #233 Bark 加固合并实施，操作前说明影响）。
4. 多使用者形态（本人多微信 / 少数协管 / 外部多租户隔离）：存储已按多 tenant 预留，App UI 本期先做单用户极简开关，账号/接入码分发界面放后续。
