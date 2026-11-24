//
//  MeterStore.swift
//  公寓管家 · 电表板块本地存储与设置
//  清单文件：Documents/Meters/meters.json（换机/恢复时随备份包还原）
//

import Foundation
import SwiftUI

@MainActor
final class MeterStore: ObservableObject {

    static let shared = MeterStore()

    @Published var meters: [MeterLedger] = []
    @Published var settings: MeterSettings = .default
    @Published var wechatId: String = ""      // 官方接口会话标识（index 接口返回），仅内存使用不落日志
    @Published var cloudStatusText: String = "" // 云端值守最近同步状态（电表设置页展示）
    @Published var cloudBusy: Bool = false      // 云端同步/快照拉取进行中

    private let fileURL: URL
    private let settingsURL: URL
    private var suppressCloudPush = false       // 应用云端快照落盘期间抑制反向同步钩子

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("meters.json")
        settingsURL = dir.appendingPathComponent("settings.json")
        load()
    }

    // MARK: - 加载 / 保存

    private func load() {
        do {
            if let data = try? Data(contentsOf: fileURL) {
                meters = try JSONDecoder().decode([MeterLedger].self, from: data)
            }
            if let data = try? Data(contentsOf: settingsURL) {
                settings = try JSONDecoder().decode(MeterSettings.self, from: data)
            }
            if settings.openId.isEmpty, let link = parseOpenId(from: settings.queryLink) {
                settings.openId = link
            }
        } catch {
            // 配置文件损坏则回退默认，不清除用户文件
        }
    }

    func saveMeters() {
        do {
            let data = try JSONEncoder().encode(meters)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 本地写失败静默，功能继续用内存
        }
        // 清单变化（新增/删除/备注/置顶；云端快照合并时 suppressCloudPush=true 跳过，避免回环 PUT）
        if !suppressCloudPush {
            MeterCloudSync.shared.scheduleAfterChange(store: self)
        }
    }

    func saveSettings() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
        }
        // v1.95：设置变化后立即按新开关/间隔重建定时器
        startAutoRefreshIfNeeded()
        // 云端值守：开关/阈值/链接/提醒项变化后防抖全量同步；关闭开关时补发 enabled=false
        MeterCloudSync.shared.scheduleAfterChange(store: self)
    }

    // MARK: - v1.95 全局电表盯防定时器（v2.4：取消「启动即补刷」）
    // 说明：autoRefreshEnabled 开启时，App 前台运行期间按 autoRefreshMinutes 间隔自动刷新电表并保存；
    // iOS 系统限制 App 被杀后无法后台执行——App 下次打开不会自动补刷（v2.4 起），
    // 总刷新仅手动按钮/下拉刷新，或设置页开启定时刷新后按间隔执行。
    // 配合低电量本地通知（lowAlertEnabled）即可实现「AI 盯电表」的完整闭环。

    private var refreshTimer: Timer?

    /// 按当前设置启动/重启定时器（设置页保存、App 启动时调用）
    func startAutoRefreshIfNeeded() {
        stopAutoRefresh()
        guard settings.autoRefreshEnabled else { return }
        let minutes = max(10, settings.autoRefreshMinutes)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.autoRefreshOnce()
            }
        }
        // v2.4：不再「启动即先补刷一次」——避免打开 App 就自动全量刷新（用户要求：总刷新仅手动或定时）
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 静默自动刷新一轮（成功保存，失败等下一轮，不打扰用户），返回成功刷新台数
    @discardableResult
    private func autoRefreshOnce() async -> Int {
        return await refreshNow()
    }

    /// v1.96：AI 工具调用入口——立即刷新全部电表，返回成功台数（0 表示无清单或接口失败）
    @MainActor
    func refreshNow() async -> Int {
        guard !meters.isEmpty else { return 0 }
        let provider: MeterQuerying
        switch settings.provider {
        case .webView: provider = MeterWebViewProvider.shared
        default: provider = MeterQueryService.shared
        }
        do {
            let outcome = try await provider.refreshAll(store: self) { _, _, _ in }
            if outcome.okCount > 0 { saveMeters() }
            return outcome.okCount
        } catch {
            return 0
        }
    }

    // MARK: - 查询链接（设置页自定义更换入口）

    /// 从官方查询链接中解析 openId（链接形如 http://wy.mlh-china.com/electricmeter/?openId=xxx）
    func parseOpenId(from link: String) -> String? {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "openId" })?.value
    }

    func applyQueryLink(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.queryLink = trimmed
        settings.openId = parseOpenId(from: trimmed) ?? settings.openId
        saveSettings()
    }

    /// 更换微信身份（换微信换链接）时一键清空会话与绑定，避免旧 openId 串数据
    func resetSession() {
        wechatId = ""
        // 保留电表清单（用户号本身不变），仅清会话，下次刷新自动重建会话
        saveSettings()
    }

    // MARK: - 清单操作（电表管理页使用）

    func upsert(_ ledger: MeterLedger) {
        if let idx = meters.firstIndex(where: { $0.uid == ledger.uid }) {
            meters[idx] = ledger
        } else {
            meters.append(ledger)
        }
        saveMeters()
    }

    func remove(uid: String) {
        meters.removeAll { $0.uid == uid }
        saveMeters()
    }

    /// v2.39：置顶 / 取消置顶（置顶数量不设上限，置顶项永远排在列表最前）
    func togglePin(uid: String) {
        guard let idx = meters.firstIndex(where: { $0.uid == uid }) else { return }
        meters[idx].pinned = meters[idx].isPinned ? nil : true
        saveMeters()
    }

    func updateRoom(uid: String, room: String) {
        guard let idx = meters.firstIndex(where: { $0.uid == uid }) else { return }
        meters[idx].room = room.trimmingCharacters(in: .whitespacesAndNewlines)
        saveMeters()
    }

    func applyQueryResult(uid: String, result: MeterQueryResult) {
        guard let idx = meters.firstIndex(where: { $0.uid == uid }) else { return }
        meters[idx].shengyu = Double(result.shengyu) ?? meters[idx].shengyu
        meters[idx].leiji = Double(result.leiji) ?? meters[idx].leiji
        meters[idx].zhuangtai = result.zhuangtai.isEmpty ? meters[idx].zhuangtai : result.zhuangtai
        meters[idx].shijian = result.shijian.isEmpty ? meters[idx].shijian : result.shijian
        meters[idx].lastRefresh = Date()
        appendHistory(uid: uid, s: meters[idx].shengyu, l: meters[idx].leiji)
        saveMeters()
    }

    /// 用电趋势：每次成功刷新追加一个快照，每户最多保留 200 条（v2.2：原 80；旧数据无 history 字段则初始化）
    private func appendHistory(uid: String, s: Double, l: Double) {
        guard let idx = meters.firstIndex(where: { $0.uid == uid }) else { return }
        var hist = meters[idx].history ?? []
        let now = Date().timeIntervalSince1970
        // 与最后一条间隔过短（< 30 秒）视为同一次刷新，更新该条而非新增
        if let last = hist.last, now - last.t < 30 {
            hist[hist.count - 1] = MeterHistoryPoint(t: now, s: s, l: l)
        } else {
            hist.append(MeterHistoryPoint(t: now, s: s, l: l))
            if hist.count > 200 { hist.removeFirst(hist.count - 200) }
        }
        meters[idx].history = hist
    }

    /// 一键导入：把云端绑定列表（去重、保留备注）并入清单
    func importBindings(_ uids: [String]) {
        var changed = false
        for uid in uids where !uid.isEmpty {
            if !meters.contains(where: { $0.uid == uid }) {
                meters.append(MeterLedger(uid: uid))
                changed = true
            }
        }
        if changed { saveMeters() }
    }

    // MARK: - 低电量提醒（本地通知，每天每户最多一次，防骚扰）

    private let alertDateKey = "meter.lowAlertDate"   // yyyyMMdd，全局每日一次

    func sendLowAlertIfNeeded() {
        guard settings.lowAlertEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let cal = Calendar.current
        let todayKey = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
        }()
        let last = UserDefaults.standard.string(forKey: alertDateKey)
        guard last != todayKey else { return }

        let low = meters.filter { $0.isLow(threshold: settings.lowThreshold) }
        let off = meters.filter { $0.isOff }
        guard !low.isEmpty || !off.isEmpty else { return }

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "电表预警"
            var bodyParts: [String] = []
            if !low.isEmpty {
                let sample = low.prefix(3).map { "\($0.room.isEmpty ? $0.uid : $0.room) \(String(format: "%.1f", $0.shengyu))度" }
                bodyParts.append("低电量 \(low.count) 户：" + sample.joined(separator: "、"))
            }
            if !off.isEmpty {
                let sample = off.prefix(3).map { $0.room.isEmpty ? $0.uid : $0.room }
                bodyParts.append("拉闸 \(off.count) 户：" + sample.joined(separator: "、"))
            }
            content.body = bodyParts.joined(separator: "；") + "。请及时充值。"
            content.userInfo = ["tab": 0]
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let req = UNNotificationRequest(identifier: "meter.lowAlert", content: content, trigger: trigger)
            center.add(req)
            UserDefaults.standard.set(todayKey, forKey: self.alertDateKey)
        }
    }
}

// MARK: - 云端值守：看板快照合并（#236 双模式）

extension MeterStore {
    /// 电表首页出现时调用：仅“云端值守”开启才节流拉取云端快照；关闭时直接返回，完全保持手动模式。
    func cloudBoardAppearRefresh() async {
        await MeterCloudSync.shared.pullSnapshotIfNeeded(store: self, force: false)
    }

    /// 合并服务器最近一轮值守快照：只更新本机清单已存在的户号；云端成功时间明显更旧时不覆盖本地刚刷新的值。
    func applyCloudSnapshot(_ rows: [MeterCloudMeter]) {
        guard !rows.isEmpty else { return }
        suppressCloudPush = true
        defer { suppressCloudPush = false }
        var changed = false
        for row in rows {
            guard let idx = meters.firstIndex(where: { $0.uid == row.uid }) else { continue }
            let cloudTs = row.lastOkTs ?? 0
            let localTs = meters[idx].lastRefresh?.timeIntervalSince1970 ?? 0
            // 2 秒容差：云端快照比本地最新刷新还旧时，保留本地值，避免旧云数据回盖
            if cloudTs > 0, localTs > 0, cloudTs + 2 < localTs { continue }
            if let s = row.shengyu, s > 0 { meters[idx].shengyu = s }
            if let l = row.leiji { meters[idx].leiji = l }
            if let z = row.zhuangtai, !z.isEmpty { meters[idx].zhuangtai = z }
            if let t = row.shijian, !t.isEmpty { meters[idx].shijian = t }
            if cloudTs > 0 { meters[idx].lastRefresh = Date(timeIntervalSince1970: cloudTs) }
            changed = true
        }
        if changed { saveMeters() }
    }
}

// MARK: - 云端值守同步（#235：设置权威在 App，服务器只负责执行轮询；长期令牌仅存钥匙串）

struct MeterCloudMeter: Codable {
    let uid: String
    let room: String?
    let shengyu: Double?
    let leiji: Double?
    let zhuangtai: String?
    let shijian: String?
    let lastOkTs: Double?
    enum CodingKeys: String, CodingKey {
        case uid, room, shengyu, leiji, zhuangtai, shijian
        case lastOkTs = "last_ok_ts"
    }
}

private struct MeterCloudStateResponse: Codable {
    let ok: Bool?
    let serverTime: Double?
    let lastRoundAt: Double?
    let lastOkAt: Double?
    let meters: [MeterCloudMeter]?
    enum CodingKeys: String, CodingKey {
        case ok
        case serverTime = "server_time"
        case lastRoundAt = "last_round_at"
        case lastOkAt = "last_ok_at"
        case meters
    }
}

private struct MeterEnrollResponse: Codable { let ok: Bool?; let token: String?; let error: String? }
private struct MeterAckResponse: Codable {
    let ok: Bool?
    let sent: Int?
    let total: Int?
    let meters: Int?
    let enabled: Bool?
    let error: String?
}

enum MeterCloudError: LocalizedError {
    case badEndpoint
    case server(String)
    var errorDescription: String? {
        switch self {
        case .badEndpoint: return "服务器地址无效"
        case .server(let m): return m
        }
    }
}

@MainActor
final class MeterCloudSync {
    static let shared = MeterCloudSync()
    private let defaults = UserDefaults.standard
    private var pushTask: Task<Void, Never>?
    private var lastPayloadData: Data?
    private var lastPullAt: Date?
    private init() {}

    var token: String? { KeychainStore.load(MeterCloudConfig.tokenKey) }
    var hasToken: Bool {
        (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // MARK: 变更后防抖全量同步（saveSettings / saveMeters 统一出口）

    func scheduleAfterChange(store: MeterStore) {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncAfterChange(store: store)
        }
    }

    private func syncAfterChange(store: MeterStore) async {
        if store.settings.cloudWatchEnabled {
            defaults.set(true, forKey: MeterCloudConfig.wasEnabledKey)
            _ = await pushConfig(store: store, enabled: true)
        } else if defaults.bool(forKey: MeterCloudConfig.wasEnabledKey) {
            // 开关从开→关：尽力补发一次 enabled=false，让服务器停止该租户轮询（配置保留便于再次开启）
            let ok = await pushConfig(store: store, enabled: false)
            if ok { defaults.set(false, forKey: MeterCloudConfig.wasEnabledKey) }
        }
    }

    // MARK: 地址规范化（宽容用户漏写 http://）

    private func normalizedEndpoint(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = MeterCloudConfig.defaultEndpoint }
        if !s.hasPrefix("http://"), !s.hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return nil }
        return s
    }

    private func currentEndpoint(store: MeterStore) -> String? {
        normalizedEndpoint(store.settings.cloudEndpoint)
    }

    private func buildPayload(store: MeterStore, enabled: Bool) -> [String: Any] {
        let s = store.settings
        let settingsDict: [String: Any] = [
            "queryLink": s.queryLink,
            "openId": s.openId,
            "lowThreshold": s.lowThreshold,
            "lowAlertEnabled": s.lowAlertEnabled,
            "provider": s.provider.rawValue
        ]
        let metersArray: [[String: Any]] = store.meters.map { m in
            ["uid": m.uid, "room": m.room, "pinned": m.isPinned]
        }
        return [
            "enabled": enabled,
            "device": "iPhone",
            "settings": settingsDict,
            "meters": metersArray
        ]
    }

    @discardableResult
    func pushConfig(store: MeterStore, enabled: Bool) async -> Bool {
        guard let endpoint = currentEndpoint(store: store) else {
            store.cloudStatusText = "云端服务器地址无效"
            return false
        }
        guard let token = token, !token.isEmpty else {
            defaults.set(true, forKey: MeterCloudConfig.dirtyKey)
            store.cloudStatusText = "未保存云端令牌，请先填写接入码"
            return false
        }
        store.cloudBusy = true
        defer { store.cloudBusy = false }

        let payload = buildPayload(store: store, enabled: enabled)
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return false }
        // 开启状态下同步指纹未变（如本地读数刷新触发 saveMeters，但同步字段无变化）则不发无效 PUT，也避免唤醒服务器空轮询
        if enabled, let last = lastPayloadData, last == body {
            if store.cloudStatusText.isEmpty { store.cloudStatusText = "配置已是最新" }
            return true
        }
        guard let url = URL(string: endpoint + "/api/meter/config") else { return false }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.timeoutInterval = 12
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = body
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ack = try? JSONDecoder().decode(MeterAckResponse.self, from: data)
            if code == 200, ack?.ok == true {
                if enabled { lastPayloadData = body }
                defaults.set(false, forKey: MeterCloudConfig.dirtyKey)
                let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                store.cloudStatusText = enabled ? "已同步 · \(t)" : "云端值守已关闭"
                return true
            }
            defaults.set(true, forKey: MeterCloudConfig.dirtyKey)
            store.cloudStatusText = "同步失败（服务器 \(code)），将在下次修改或进入电表页时重试"
            return false
        } catch {
            defaults.set(true, forKey: MeterCloudConfig.dirtyKey)
            store.cloudStatusText = "同步失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: 首次接入：接入码换长期令牌（成功后仅存本机钥匙串）

    func enroll(store: MeterStore, code: String) async throws -> String {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { throw MeterCloudError.server("请填写接入码") }
        guard let endpoint = currentEndpoint(store: store),
              let url = URL(string: endpoint + "/api/meter/enroll") else { throw MeterCloudError.badEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": trimmedCode, "device": "iPhone"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONDecoder().decode(MeterEnrollResponse.self, from: data)
        guard httpCode == 200, obj?.ok == true, let t = obj?.token, !t.isEmpty else {
            if httpCode == 403 { throw MeterCloudError.server("接入码不正确") }
            if httpCode == 429 { throw MeterCloudError.server("尝试过于频繁，请稍后再试") }
            throw MeterCloudError.server(obj?.error ?? "接入失败（服务器 \(httpCode)）")
        }
        KeychainStore.save(t, for: MeterCloudConfig.tokenKey)
        lastPayloadData = nil
        return t
    }

    func clearToken() {
        // KeychainStore 未提供删除接口：写入空串后 hasToken=false，功能等价退出登录（不会用于请求）
        KeychainStore.save("", for: MeterCloudConfig.tokenKey)
        lastPayloadData = nil
    }

    // MARK: 测试推送（经服务器本机自建 Bark 下发）

    func sendTestPush(store: MeterStore) async -> String {
        guard let endpoint = currentEndpoint(store: store),
              let token = token, !token.isEmpty,
              let url = URL(string: endpoint + "/api/meter/test-push") else {
            return "尚未连接云端（地址或令牌缺失）"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ack = try? JSONDecoder().decode(MeterAckResponse.self, from: data)
            if code == 200, ack?.ok == true {
                return "测试推送已发送（\(ack?.sent ?? 0)/\(ack?.total ?? 0) 台设备），请查看手机通知"
            }
            if (ack?.total ?? 0) == 0 { return "服务器暂未绑定 Bark 设备，请先在服务器配置 Bark Key" }
            return "测试推送失败（服务器 \(code)）"
        } catch {
            return "测试推送失败：\(error.localizedDescription)"
        }
    }

    // MARK: 看板进入时拉取云端快照（60s 节流；开关关闭时直接返回，不改变手动模式）

    func pullSnapshotIfNeeded(store: MeterStore, force: Bool) async {
        guard store.settings.cloudWatchEnabled else { return }
        if !force, let last = lastPullAt, Date().timeIntervalSince(last) < MeterCloudConfig.enterPullThrottle { return }
        lastPullAt = Date()

        // 上次有未成功的同步，借进页先补推一次（best effort）
        if defaults.bool(forKey: MeterCloudConfig.dirtyKey) {
            _ = await pushConfig(store: store, enabled: true)
        }
        guard let endpoint = currentEndpoint(store: store),
              let token = token, !token.isEmpty,
              let url = URL(string: endpoint + "/api/meter/state") else {
            store.cloudStatusText = "未保存云端令牌，请先在电表设置中接入"
            return
        }
        store.cloudBusy = true
        defer { store.cloudBusy = false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                store.cloudStatusText = "云端快照获取失败（服务器 \(code)）"
                return
            }
            let decoded = try JSONDecoder().decode(MeterCloudStateResponse.self, from: data)
            store.applyCloudSnapshot(decoded.meters ?? [])
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            if let round = decoded.lastRoundAt, round > 0 {
                store.cloudStatusText = "云端数据 \(fmt.string(from: Date(timeIntervalSince1970: round)))"
            } else {
                store.cloudStatusText = "云端值守已开启，等待服务器首轮巡检"
            }
        } catch {
            store.cloudStatusText = "云端快照获取失败：\(error.localizedDescription)"
        }
    }
}
