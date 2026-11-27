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
            // 非 MainActor 的 CloudOps/分享扩展需要读服务器地址：设置加载后同步到共享区。
            SharedBridge.defaults.set(settings.cloudEndpoint, forKey: MeterCloudConfig.endpointCacheKey)
            SharedBridge.defaults.set(settings.cloudEndpoint, forKey: SharedBridge.kEndpoint)
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
            SharedBridge.defaults.set(settings.cloudEndpoint, forKey: MeterCloudConfig.endpointCacheKey)
            SharedBridge.defaults.set(settings.cloudEndpoint, forKey: SharedBridge.kEndpoint)
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
    /// 电表首页出现时调用：仅“云端值守”开启才自动拉取云端快照（3s 仅去重同次进入的重复回调）；关闭时直接返回，完全保持手动模式。
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
    // 内存缓存：保证一次会话内 hasToken 稳定，不闪断
    private var cachedToken: String?
    private init() {}

    // 本机沙盒兜底文件：ad-hoc 侧载（无 team）钥匙串访问组不可靠，文件仅存 App 私有容器、不上云
    private var tokenFileURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("meter-cloud-token")
    }
    private func loadFileToken() -> String? {
        guard let s = try? String(contentsOf: tokenFileURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private func saveFileToken(_ t: String) {
        try? t.write(to: tokenFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: tokenFileURL.path)
    }
    private func deleteFileToken() {
        try? FileManager.default.removeItem(at: tokenFileURL)
    }

    /// 令牌读取：内存缓存 → 钥匙串 → 本机兜底文件，任一存在即视为已接入，
    /// 彻底避免 ad-hoc 钥匙串权限校验失败时被误判成“令牌已清除”。
    var token: String? {
        if let c = cachedToken, !c.isEmpty { return c }
        if let k = KeychainStore.load(MeterCloudConfig.tokenKey), !k.isEmpty {
            cachedToken = k
            return k
        }
        if let f = loadFileToken() {
            cachedToken = f
            _ = KeychainStore.save(f, for: MeterCloudConfig.tokenKey) // 顺手补写钥匙串
            return f
        }
        return nil
    }
    var hasToken: Bool {
        (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private nonisolated static func persistedTokenFileURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("meter-cloud-token")
    }

    private nonisolated static func loadPersistedFileToken() -> String? {
        guard let s = try? String(contentsOf: persistedTokenFileURL(), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// nonisolated 只读持久令牌（钥匙串 → 本机兜底文件），供非 MainActor 的路由/账本存储同步判定；
    /// 不依赖 MainActor 内存缓存，避免跨 actor 隔离引用。
    nonisolated static func persistedToken() -> String? {
        if let k = KeychainStore.load(MeterCloudConfig.tokenKey), !k.isEmpty { return k }
        return loadPersistedFileToken()
    }

    nonisolated static func hasPersistedToken() -> Bool {
        (persistedToken() ?? "").isEmpty == false
    }

    // 测试诊断：分别读取三个来源的原始状态，不依赖 token 的缓存逻辑，用于定位真机令牌丢失环节
    struct TokenDiagnostic {
        let memory: Bool
        let keychain: Bool
        let file: Bool
        let fileExists: Bool
        let filePath: String
        let resolved: Bool
    }
    var tokenDiagnostic: TokenDiagnostic {
        TokenDiagnostic(
            memory: !(cachedToken ?? "").isEmpty,
            keychain: !(KeychainStore.load(MeterCloudConfig.tokenKey) ?? "").isEmpty,
            file: loadFileToken() != nil,
            fileExists: FileManager.default.fileExists(atPath: tokenFileURL.path),
            filePath: tokenFileURL.path,
            resolved: hasToken)
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
            "provider": s.provider.rawValue,
            // 云端值守服务器轮询间隔（秒）：App 设置页 30/60/120 分钟或自定义，服务端按租户独立调度
            "pollIntervalSeconds": s.cloudPollMinutes * 60
        ]
        let metersArray: [[String: Any]] = store.meters.map { m in
            ["uid": m.uid, "room": m.room, "pinned": m.isPinned]
        }
        var payload: [String: Any] = [
            "enabled": enabled,
            "device": "iPhone",
            "settings": settingsDict,
            "meters": metersArray
        ]
        // 已在「云端推送通道」建档登录：电表租户绑定该通知用户，服务端据此只投其本人设备
        if let ut = KeychainStore.load(NotifyHubConfig.tokenKey), !ut.isEmpty {
            payload["userToken"] = ut
        }
        return payload
    }

    @discardableResult
    func pushConfig(store: MeterStore, enabled: Bool) async -> Bool {
        guard let endpoint = currentEndpoint(store: store) else {
            store.cloudStatusText = "云端服务器地址无效"
            return false
        }
        guard let token = token, !token.isEmpty else {
            defaults.set(true, forKey: MeterCloudConfig.dirtyKey)
            store.cloudStatusText = "未保存云端令牌，请先在云端配置填写服务器授权码"
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
                store.cloudStatusText = enabled ? "已同步 · \(t)" : "云端轮询已关闭"
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

    // MARK: 首次接入：授权码换长期令牌（成功后仅存本机钥匙串）

    func enroll(store: MeterStore, code: String) async throws -> String {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { throw MeterCloudError.server("请填写服务器授权码") }
        guard let endpoint = currentEndpoint(store: store),
              let url = URL(string: endpoint + "/api/meter/enroll") else { throw MeterCloudError.badEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var enrollPayload: [String: Any] = ["code": trimmedCode, "device": "iPhone"]
        // 已在通知中心建档则带上 userToken，服务端据此对同用户同设备做 enroll 幂等
        if let ut = KeychainStore.load(NotifyHubConfig.tokenKey), !ut.isEmpty {
            enrollPayload["userToken"] = ut
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: enrollPayload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONDecoder().decode(MeterEnrollResponse.self, from: data)
        guard httpCode == 200, obj?.ok == true, let t = obj?.token, !t.isEmpty else {
            if httpCode == 403 { throw MeterCloudError.server("授权码不正确") }
            if httpCode == 429 { throw MeterCloudError.server("尝试过于频繁，请稍后再试") }
            throw MeterCloudError.server(obj?.error ?? "接入失败（服务器 \(httpCode)）")
        }
        let keychainOK = KeychainStore.save(t, for: MeterCloudConfig.tokenKey)
        // ad-hoc 侧载钥匙串可能不可靠：同时写本机沙盒兜底文件（仅本机、不上云）
        saveFileToken(t)
        let fileOK = loadFileToken() == t
        guard keychainOK || fileOK else {
            throw MeterCloudError.server("本机存储写入失败，请检查 App 签名或重装后重试")
        }
        cachedToken = t
        lastPayloadData = nil
        return t
    }

    func clearToken() {
        // 退出登录：清钥匙串、本机兜底文件与内存缓存
        KeychainStore.delete(MeterCloudConfig.tokenKey)
        deleteFileToken()
        cachedToken = nil
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

    // MARK: 手动立即轮询（b206：不用等云端间隔，服务器唤醒 worker 立即查一轮；HTTP 只入队，异步执行立即返回）

    func runNow(store: MeterStore) async -> String {
        guard let endpoint = currentEndpoint(store: store),
              let token = token, !token.isEmpty,
              let url = URL(string: endpoint + "/api/meter/run-now") else {
            return "尚未接入云端轮询（服务器地址或接入令牌缺失）"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("{}".utf8)
        struct RunNowAck: Codable {
            let ok: Bool?
            let queued: Bool?
            let error: String?
            let hint: String?
            let retry_after: Int?
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ack = try? JSONDecoder().decode(RunNowAck.self, from: data)
            if code == 200, ack?.ok == true {
                return "已通知服务器立即轮询，约十几秒到两分钟完成；有告警会即时推送，稍后进入电表页可看云端更新时间"
            }
            if code == 409 { return ack?.hint ?? "请先开启云端轮询并同步成功后，再点立即轮询" }
            if code == 429 { return "操作太频繁，请 \(ack?.retry_after ?? 10) 秒后再点" }
            if code == 401 { return "云端令牌已失效，请重新在云端配置填写服务器授权码" }
            let detail = ack?.error.map { "：\($0)" } ?? ""
            return "触发失败（服务器 \(code)）\(detail)"
        } catch {
            return "触发失败：\(error.localizedDescription)"
        }
    }

    // MARK: 看板进入时拉取云端快照（3s 仅去重同一次进入的重复 onAppear，等同每次进入都拉；开关关闭直接返回，保持纯手动模式）

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
                store.cloudStatusText = "云端轮询已开启，等待服务器首轮查询"
            }
        } catch {
            store.cloudStatusText = "云端快照获取失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 统一推送通道（notify-hub）
// 架构：通道后以「用户」为单位隔离，一个用户可绑多台手机 Bark Key，只收自己业务数据；
// 通道前各业务模块（电表先行，后续到期/收租）经服务器 dispatch 事件接入。长期用户令牌只存钥匙串。

enum NotifyHubConfig {
    static let tokenKey = "notify.hub.userToken"            // Keychain：通知中心用户长期令牌
    static let usernameCacheKey = "notify.hub.username"    // UserDefaults：最近一次用户名（仅展示/预填，非凭据）
    static let enrollCodeCacheKey = "notify.hub.enrollCode"// UserDefaults：测试期记住授权码方便回填
    static let lastSyncKey = "notify.hub.lastSyncAt"
    static let apiPrefix = "/api/notify"
}

struct NotifyHubDevice: Codable, Identifiable, Equatable {
    let deviceId: String
    let name: String?
    let platform: String?
    let serverBase: String?
    let keyMasked: String?
    let addedAt: String?
    let lastOkAt: Double?
    let lastError: String?
    var id: String { deviceId }
    var displayName: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "我的设备" : n
    }
}

struct NotifyHubEvent: Codable, Identifiable, Equatable {
    let id: String
    let at: String?
    let module: String?
    let type: String?
    let title: String?
    let body: String?
    let status: String?
    let sent: Int?
    let total: Int?
}

struct NotifyHubPrefs: Codable, Equatable {
    var enabled: Bool?
    var modules: [String: Bool]?
}

struct MeterTemplate: Codable, Equatable {
    var title: String
    var subtitle: String
    var body: String
    var showTime: Bool
}

struct MeterTemplateSet: Codable, Equatable {
    var low: MeterTemplate?
    var off: MeterTemplate?
}

/// register/me/prefs/devices 返回用户档案；test 返回投递结果；字段全部可选以兼容服务器演进
private struct NotifyHubResponse: Codable {
    let ok: Bool?
    let token: String?
    let username: String?
    let prefs: NotifyHubPrefs?
    let devices: [NotifyHubDevice]?
    let events: [NotifyHubEvent]?
    let templates: MeterTemplateSet?
    let error: String?
    let reason: String?
    let sent: Int?
    let total: Int?
}

@MainActor
final class NotifyHub: ObservableObject {
    static let shared = NotifyHub()

    @Published var isBound = false
    @Published var username = ""
    @Published var devices: [NotifyHubDevice] = []
    @Published var events: [NotifyHubEvent] = []
    @Published var prefs = NotifyHubPrefs(enabled: true, modules: ["meter": true])
    @Published var busy = false
    @Published var statusText: String?
    @Published var lastSyncAt: Date?
    /// 首次绑定通道账号后“自动补一次电表同步”的结果：nil=未触发（无电表令牌/仅添加设备），true/false=补同步成败
    @Published var lastBindMeterSync: Bool?

    private let defaults = UserDefaults.standard
    private init() {
        username = defaults.string(forKey: NotifyHubConfig.usernameCacheKey) ?? ""
        isBound = !(KeychainStore.load(NotifyHubConfig.tokenKey) ?? "").isEmpty
        lastSyncAt = defaults.object(forKey: NotifyHubConfig.lastSyncKey) as? Date
    }

    var token: String? { KeychainStore.load(NotifyHubConfig.tokenKey) }
    var channelEnabled: Bool { prefs.enabled ?? true }
    var meterModuleEnabled: Bool { prefs.modules?["meter"] ?? true }

    /// 与电表云端值守共用同一台服务器（8082 同进程挂载 /api/notify），地址在「设置 → 云端配置」里改
    var endpoint: String {
        var s = MeterStore.shared.settings.cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = MeterCloudConfig.defaultEndpoint }
        if !s.hasPrefix("http://"), !s.hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func cachedEnrollCode() -> String {
        let v = defaults.string(forKey: NotifyHubConfig.enrollCodeCacheKey) ?? ""
        return v.isEmpty ? "123456" : v
    }

    func rememberEnrollCode(_ code: String) {
        defaults.set(code, forKey: NotifyHubConfig.enrollCodeCacheKey)
    }

    // MARK: 网络

    private func buildURL(_ sub: String) -> URL? {
        URL(string: endpoint + NotifyHubConfig.apiPrefix + "/" + sub)
    }

    private func zhError(_ raw: String, httpCode: Int) -> String {
        switch raw {
        case "invalid_code": return "授权码不正确（测试期固定 123456）"
        case "invalid_bark_key": return "识别不到 Bark Key，请粘贴 Bark App 首页的完整推送链接（形如 http://服务器/一串字符）"
        case "username_exists": return "该用户名已被占用；若是本人换机绑定，请换一个用户名（测试期暂不支持换机找回）"
        case "device_limit": return "该账号绑定设备数已达上限（10 台）"
        case "too_many_attempts": return "失败次数过多，请 10 分钟后再试"
        case "unauthorized": return "登录已失效，请重新绑定"
        case "unsupported_action": return "不支持的设备操作"
        default:
            let r = raw.isEmpty ? "服务器错误" : raw
            return "\(r)（HTTP \(httpCode)）"
        }
    }

    @discardableResult
    private func request(_ sub: String, method: String, body: [String: Any]?,
                         auth: Bool = true) async throws -> NotifyHubResponse {
        guard let url = buildURL(sub) else {
            throw NSError(domain: "NotifyHub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "服务器地址无效，可到「设置 → 云端配置」检查服务器地址"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if auth, let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(NotifyHubResponse.self, from: data)
        if code == 401 {
            throw NSError(domain: "NotifyHub", code: code,
                          userInfo: [NSLocalizedDescriptionKey: zhError("unauthorized", httpCode: code)])
        }
        guard (200..<300).contains(code), let obj = decoded else {
            throw NSError(domain: "NotifyHub", code: code,
                          userInfo: [NSLocalizedDescriptionKey: zhError(decoded?.error ?? decoded?.reason ?? "", httpCode: code)])
        }
        return obj
    }

    private func applyProfile(_ obj: NotifyHubResponse) {
        if let t = obj.token, !t.isEmpty {
            KeychainStore.save(t, for: NotifyHubConfig.tokenKey)
            isBound = true
        }
        if let name = obj.username, !name.isEmpty {
            username = name
            defaults.set(name, forKey: NotifyHubConfig.usernameCacheKey)
        }
        if let p = obj.prefs { prefs = p }
        if let d = obj.devices { devices = d }
        if let e = obj.events { events = e }
        defaults.set(Date(), forKey: NotifyHubConfig.lastSyncKey)
        lastSyncAt = Date()
    }

    // MARK: 动作

    /// 首次建档注册，或已登录时添加/更新本机设备（同一 register 端点，有 token 自动走更新）
    func register(code: String, username inputName: String, barkText: String, deviceName: String) async -> String? {
        busy = true
        statusText = nil
        lastBindMeterSync = nil
        defer { busy = false }
        let oldToken = token ?? ""
        let body: [String: Any] = [
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "username": inputName.trimmingCharacters(in: .whitespacesAndNewlines),
            "barkKey": barkText.trimmingCharacters(in: .whitespacesAndNewlines),
            "deviceName": deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "我的 iPhone" : deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            "platform": "ios"
        ]
        do {
            let obj = try await request("register", method: "POST", body: body)
            applyProfile(obj)
            rememberEnrollCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
            // 仅首次拿到新的通道账号令牌（注册/换机登录）才补同步；已登录添加设备时 token 不变，不重复推电表配置
            if let newToken = obj.token, !newToken.isEmpty, newToken != oldToken {
                lastBindMeterSync = await syncMeterBindingAfterRegister()
            }
            return nil
        } catch {
            statusText = error.localizedDescription
            return error.localizedDescription
        }
    }

    /// 绑定成功后自动补一次电表全量配置，把通道 userToken 绑到电表租户；
    /// 修复“先开电表值守、后绑推送通道”时需手动再同步一次的顺序缺口。
    /// - Returns: nil=本机还没接入服务器云端（无令牌，跳过，之后开值守 buildPayload 会自动带 token）；true/false=补同步成败
    private func syncMeterBindingAfterRegister() async -> Bool? {
        let sync = MeterCloudSync.shared
        guard sync.hasToken else { return nil }
        let store = MeterStore.shared
        // 保持用户当前值守开关状态，不借绑定动作擅自开启服务器轮询
        return await sync.pushConfig(store: store, enabled: store.settings.cloudWatchEnabled)
    }

    func refreshMe() async {
        guard isBound else { return }
        busy = true
        defer { busy = false }
        do {
            let obj = try await request("me", method: "GET", body: nil)
            applyProfile(obj)
            statusText = nil
        } catch {
            statusText = error.localizedDescription
        }
    }

    func sendTest() async -> String {
        busy = true
        defer { busy = false }
        do {
            let obj = try await request("test", method: "POST", body: [:])
            let total = obj.total ?? 0
            let sent = obj.sent ?? 0
            if total == 0 {
                switch obj.reason {
                case "no_device": return "账号下还没有可用设备，请先绑定本机 Bark"
                case "user_disabled": return "通道总开关已关闭，请先打开开关"
                case "module_disabled": return "电表模块通知开关已关闭"
                case "unknown_user": return "服务器未找到该账号，请重新绑定"
                default: return "未实际下发（\(obj.reason ?? "未知原因")）"
                }
            }
            if sent > 0 {
                await refreshMe()
                return "已投递 \(sent)/\(total) 台设备，请查看 iPhone 通知（仅你本人设备接收）"
            }
            await refreshMe()
            return "投递失败（0/\(total)），请检查手机 Bark App 的服务器配置与通知权限"
        } catch {
            return "测试请求失败：\(error.localizedDescription)"
        }
    }

    /// 总开关 / 电表模块开关；先乐观更新再以服务器档案为准回滚
    func updatePrefs(channelEnabled: Bool? = nil, meterEnabled: Bool? = nil) async {
        var body: [String: Any] = [:]
        if let channelEnabled {
            body["enabled"] = channelEnabled
            prefs.enabled = channelEnabled
        }
        if let meterEnabled {
            body["modules"] = ["meter": meterEnabled]
            var modules = prefs.modules ?? [:]
            modules["meter"] = meterEnabled
            prefs.modules = modules
        }
        guard !body.isEmpty else { return }
        do {
            let obj = try await request("prefs", method: "POST", body: body)
            applyProfile(obj)
        } catch {
            statusText = error.localizedDescription
            await refreshMe()
        }
    }

    // MARK: 电表通知文案模板

    func loadMeterTemplates() async throws -> MeterTemplateSet {
        let obj = try await request("templates/meter", method: "GET", body: nil)
        return obj.templates ?? MeterTemplateSet()
    }

    func saveMeterTemplate(_ eventKey: String, tpl: MeterTemplate) async throws -> MeterTemplateSet {
        let obj = try await request("templates/meter", method: "POST", body: [
            eventKey: [
                "title": tpl.title, "subtitle": tpl.subtitle,
                "body": tpl.body, "showTime": tpl.showTime
            ]
        ])
        return obj.templates ?? MeterTemplateSet()
    }

    func previewMeterTemplate(_ eventKey: String) async -> String {
        do {
            let obj = try await request("templates/meter/preview", method: "POST",
                                        body: ["eventKey": eventKey])
            if obj.ok == true { return "预览已真实推送，请查看 iPhone 通知" }
            return "预览失败（\(obj.error ?? "未知原因")）"
        } catch {
            return "预览失败：\(error.localizedDescription)"
        }
    }

    func removeDevice(_ device: NotifyHubDevice) async {
        busy = true
        defer { busy = false }
        do {
            let obj = try await request("devices", method: "POST",
                                        body: ["action": "remove", "deviceId": device.deviceId])
            applyProfile(obj)
        } catch {
            statusText = error.localizedDescription
        }
    }

    /// 仅清本机登录态（Keychain 写空串，KeychainStore 无删除接口，功能等价退出）；服务器档案保留
    func logout() {
        KeychainStore.save("", for: NotifyHubConfig.tokenKey)
        isBound = false
        devices = []
        events = []
        prefs = NotifyHubPrefs(enabled: true, modules: ["meter": true])
        statusText = nil
    }
}
