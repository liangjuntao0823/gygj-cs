import Foundation
import CryptoKit

// MARK: - v2.45 单套房账本（操作日志：从建账起全量记录，云端共享，所有人可见）

/// 字段级变化（租金/备注/密码/房东/房号/户型/状态等）
struct HouseLedgerFieldChange: Codable, Hashable {
    let field: String
    let oldValue: String
    let newValue: String
}

/// 单条账本事件（append-only，不修改不删除）
struct HouseLedgerEvent: Codable, Identifiable, Hashable {
    let id: String
    let date: Date
    /// 操作人（带设备标识，如「涛(iPhone)」；历史迁移数据可能只有用户名）
    let operatorName: String
    /// 动作（如「新增房源」「编辑保存」「切换状态」「删除房源」「补齐媒体」）
    let action: String
    /// 人类可读明细（媒体变化、补充说明等）
    let detail: String
    /// 字段级变化
    let fieldChanges: [HouseLedgerFieldChange]
    /// 历史日志迁移生成的事件
    let migrated: Bool

    init(id: String = UUID().uuidString,
         date: Date = Date(),
         operatorName: String = CloudUser.signedUsername,
         action: String,
         detail: String = "",
         fieldChanges: [HouseLedgerFieldChange] = [],
         migrated: Bool = false) {
        self.id = id
        self.date = date
        self.operatorName = operatorName
        self.action = action
        self.detail = detail
        self.fieldChanges = fieldChanges
        self.migrated = migrated
    }
}

// 以下远程事件转换仅主 App 使用；分享扩展（APP_EXTENSION）不含服务器客户端，单独剔除
#if !APP_EXTENSION
extension HouseLedgerEvent {
    /// 服务器账本事件 → 本地展示模型（服务器模式详情页读取用）
    init(remote: RemoteLedgerEvent) {
        let date = HouseLedgerEvent.parseDate(remote.ts)
        let changes = (remote.fieldChanges ?? []).map {
            HouseLedgerFieldChange(field: $0.field, oldValue: $0.oldValue, newValue: $0.newValue)
        }
        self.init(
            id: remote.id,
            date: date,
            operatorName: remote.operatorName?.isEmpty == false ? remote.operatorName! : "未知用户",
            action: remote.action,
            detail: remote.detail ?? "",
            fieldChanges: changes,
            migrated: remote.migrated ?? false)
    }

    /// 解析服务器 ISO8601 时间（东八区 +08:00）；失败回退普通日期格式，再失败取当前时间
    private static func parseDate(_ ts: String) -> Date {
        if let d = ISO8601DateFormatter().date(from: ts) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = f.date(from: ts) { return d }
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: ts) ?? Date()
    }
}
#endif

/// 单套房账本文件（与 info.json 同目录：本地 media/<roomKey>/ledger.json，云端 h/<roomKey>/ledger.json）
struct HouseLedgerFile: Codable {
    var roomKey: String
    var revision: Int64
    var events: [HouseLedgerEvent]

    static func empty(roomKey: String) -> HouseLedgerFile {
        HouseLedgerFile(roomKey: roomKey, revision: 0, events: [])
    }
}

/// 同步串行门：同一房号同一时刻只允许一个合并写任务，避免并发写互相覆盖
actor HouseLedgerSyncGate {
    static let shared = HouseLedgerSyncGate()
    private var inflight = Set<String>()

    /// 尝试占用；已在跑返回 false
    func begin(_ key: String) -> Bool {
        guard !inflight.contains(key) else { return false }
        inflight.insert(key)
        return true
    }
    func end(_ key: String) { inflight.remove(key) }
}

enum HouseLedgerStore {
    static let fileName = "ledger.json"
    /// v2.52：待确认事件文件——同步成功前事件只待在这里，不进正式账本、界面看不到
    static let pendingFileName = "ledger.pending.json"
    private static let dirtyKey = "houseLedger.dirty.v1"
    private static let fileLock = NSLock()

    // MARK: 路径

    static func localURL(roomKey: String) -> URL {
        MediaStore.houseDirectory(roomKey: roomKey).appendingPathComponent(fileName)
    }
    static func pendingURL(roomKey: String) -> URL {
        MediaStore.houseDirectory(roomKey: roomKey).appendingPathComponent(pendingFileName)
    }
    static func cloudPath(roomKey: String) -> String { "h/\(roomKey)/\(fileName)" }

    // MARK: 待确认事件读写

    private static func loadPendingUnlocked(roomKey: String) -> [HouseLedgerEvent] {
        guard let data = try? Data(contentsOf: pendingURL(roomKey: roomKey)),
              let list = try? JSONDecoder().decode([HouseLedgerEvent].self, from: data) else { return [] }
        return list.sorted { $0.date < $1.date }
    }

    private static func savePendingUnlocked(roomKey: String, events: [HouseLedgerEvent]) {
        let url = pendingURL(roomKey: roomKey)
        if events.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let list = events.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 本地读写

    static func load(roomKey: String) -> HouseLedgerFile {
        fileLock.lock()
        defer { fileLock.unlock() }
        return loadUnlocked(roomKey: roomKey)
    }

    /// 调用方已持 fileLock 时使用，避免 NSLock 非重入导致死锁
    private static func loadUnlocked(roomKey: String) -> HouseLedgerFile {
        let url = localURL(roomKey: roomKey)
        guard let data = try? Data(contentsOf: url),
              var file = try? JSONDecoder().decode(HouseLedgerFile.self, from: data) else {
            return .empty(roomKey: roomKey)
        }
        file.roomKey = roomKey
        file.events.sort { $0.date < $1.date }
        return file
    }

    static func events(roomKey: String) -> [HouseLedgerEvent] {
        load(roomKey: roomKey).events.sorted { $0.date > $1.date }
    }

    private static func writeLocked(roomKey: String, file: HouseLedgerFile) {
        var f = file
        f.roomKey = roomKey
        f.events.sort { $0.date < $1.date }
        let data = try? JSONEncoder().encode(f)
        try? data?.write(to: localURL(roomKey: roomKey), options: .atomic)
    }

    /// v2.52：追加事件——只写待确认文件，不进正式账本；
    /// 等云端同步成功后才并入正式 ledger.json，同步失败则一直留在 pending（界面不显示）。
    @discardableResult
    static func append(roomKey: String,
                       action: String,
                       detail: String = "",
                       fieldChanges: [HouseLedgerFieldChange] = [],
                       date: Date = Date(),
                       cloudLog: Bool = true,
                       logAction: String? = nil,
                       logDetail: String? = nil,
                       writeOpLog: Bool = true) -> HouseLedgerEvent {
        let event = HouseLedgerEvent(date: date, action: action, detail: detail, fieldChanges: fieldChanges)
        fileLock.lock()
        var pending = loadPendingUnlocked(roomKey: roomKey)
        pending.append(event)
        savePendingUnlocked(roomKey: roomKey, events: pending)
        fileLock.unlock()
        scheduleSync(roomKey: roomKey)
        // 操作日志沿用旧正式版规则：一次动作只走 BackupLogStore.log(cloud:true)，
        // 同时写本机「本机操作」和服务器 ops「云端操作」，两侧动作名、结果、明细完全一致。
        // 旧版房源页面也是这个写法，不再直接调 CloudOps.log 只写云端、漏掉本机。
        // 各页面若需要“服务器成功后再落日志”，传 writeOpLog:false，由推送结果统一写。
        let changeText = fieldChanges.map { "\($0.field)：\($0.oldValue) → \($0.newValue)" }
            .joined(separator: "；")
        let finalDetail = logDetail ?? (detail.isEmpty ? changeText : detail)
        if cloudLog && writeOpLog {
            BackupLogStore.log(category: "房源",
                               action: logAction ?? action,
                               result: "成功",
                               detail: finalDetail,
                               room: roomKey,
                               cloud: true)
        }
        return event
    }

    /// 批量并入（历史迁移用）：按事件 id 去重，返回实际新增条数
    @discardableResult
    static func mergeAndSave(roomKey: String, events newEvents: [HouseLedgerEvent]) -> Int {
        fileLock.lock()
        defer { fileLock.unlock() }
        var file = loadUnlocked(roomKey: roomKey)
        let existing = Set(file.events.map { $0.id })
        var added = 0
        for e in newEvents where !existing.contains(e.id) {
            file.events.append(e)
            added += 1
        }
        if added > 0 { writeLocked(roomKey: roomKey, file: file) }
        return added
    }

    /// v2.46：迁移器重跑前，清掉某房账本里所有带「历史」标记的旧迁移事件（真实事件不碰）
    @discardableResult
    static func purgeMigrated(roomKey: String) -> Int {
        fileLock.lock()
        defer { fileLock.unlock() }
        var file = loadUnlocked(roomKey: roomKey)
        let before = file.events.count
        file.events.removeAll { $0.migrated }
        let removed = before - file.events.count
        if removed > 0 { writeLocked(roomKey: roomKey, file: file) }
        return removed
    }

    /// 无云配置时本地清理废弃动作
    static func purgeDeprecatedActionsLocal(roomKey: String, actions: Set<String>) {
        fileLock.lock()
        defer { fileLock.unlock() }
        var file = loadUnlocked(roomKey: roomKey)
        let before = file.events.count
        file.events.removeAll { actions.contains($0.action) }
        if file.events.count != before {
            writeLocked(roomKey: roomKey, file: file)
        }
    }

    /// v2.53：全量撤回——从待确认文件移除本次事件 id（同步成功前的事件都在这里）
    @discardableResult
    static func removePendingEvents(roomKey: String, eventIds: Set<String>) -> Int {
        guard !eventIds.isEmpty else { return 0 }
        fileLock.lock()
        defer { fileLock.unlock() }
        let pending = loadPendingUnlocked(roomKey: roomKey)
        let kept = pending.filter { !eventIds.contains($0.id) }
        savePendingUnlocked(roomKey: roomKey, events: kept)
        return pending.count - kept.count
    }

    /// v2.53：全量撤回——从本地正式账本移除本次事件 id（应对事件已同步落地的情况）
    @discardableResult
    static func purgeEventsLocal(roomKey: String, eventIds: Set<String>) -> Int {
        guard !eventIds.isEmpty else { return 0 }
        fileLock.lock()
        defer { fileLock.unlock() }
        var file = loadUnlocked(roomKey: roomKey)
        let before = file.events.count
        file.events.removeAll { eventIds.contains($0.id) }
        if file.events.count != before {
            writeLocked(roomKey: roomKey, file: file)
        }
        return before - file.events.count
    }

    /// 本机所有媒体房号目录（用于迁移器逐房清理）
    static func allLocalRoomKeys() -> [String] {
        let root = MediaStore.mediaDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: 待同步（离线/失败）名单

    /// v2.68：dirty 名单改存 App Group 共享区——扩展同步失败的房号，主 App 启动 syncAll 同一份接手。
    static func dirtyRoomKeys() -> [String] {
        SharedBridge.migrateKey(dirtyKey)
        return (SharedBridge.defaults.stringArray(forKey: dirtyKey) ?? []).filter { !$0.isEmpty }
    }
    static func markDirty(_ roomKey: String) {
        guard !roomKey.isEmpty else { return }
        var set = Set(dirtyRoomKeys())
        set.insert(roomKey)
        SharedBridge.defaults.set(Array(set), forKey: dirtyKey)
    }
    static func clearDirty(_ roomKey: String) {
        var set = Set(dirtyRoomKeys())
        set.remove(roomKey)
        SharedBridge.defaults.set(Array(set), forKey: dirtyKey)
    }

    /// v2.68：收养分享扩展留在共享容器的待确认账本事件（按 id 去重并入本进程 pending），
    /// 随后删除共享 pending 文件。扩展模式 local==shared 跳过。
    /// 事件仍守 v2.52 口径：云端同步成功后才并入正式账本。
    static func adoptSharedPending(roomKey: String) {
        guard !MediaStore.useSharedContainer, let shared = MediaStore.sharedMediaDirectory else { return }
        let sharedPending = shared.appendingPathComponent(roomKey, isDirectory: true).appendingPathComponent(pendingFileName)
        guard let data = try? Data(contentsOf: sharedPending),
              let events = try? JSONDecoder().decode([HouseLedgerEvent].self, from: data),
              !events.isEmpty else { return }
        fileLock.lock()
        var pending = loadPendingUnlocked(roomKey: roomKey)
        let known = Set(pending.map { $0.id })
        pending.append(contentsOf: events.filter { !known.contains($0.id) })
        savePendingUnlocked(roomKey: roomKey, events: pending)
        fileLock.unlock()
        try? FileManager.default.removeItem(at: sharedPending)
    }

    /// 账本权威源在 8082 服务器库：待确认事件逐条 POST 服务器上行；
    /// 成功并入本地正式账本，失败/未绑定令牌时保留 pending 并记 dirty，启动后自动补传。
    /// 旧对象存储直连兜底已下线，账本只走服务器权威接口。
    static func scheduleSync(roomKey: String) {
        markDirty(roomKey)
        #if !APP_EXTENSION
        guard HouseServerMode.ready else { return }
        Task { await syncPending(roomKey: roomKey) }
        #endif
    }

    #if !APP_EXTENSION
    /// 读取某房待确认事件（持锁；供上行补传使用）
    static func pendingEvents(roomKey: String) -> [HouseLedgerEvent] {
        fileLock.lock()
        defer { fileLock.unlock() }
        return loadPendingUnlocked(roomKey: roomKey)
    }

    /// 把某房待确认事件逐条上报服务器；成功并入本地正式账本并清 pending，失败保留 + markDirty
    static func syncPending(roomKey: String) async {
        guard HouseServerMode.ready else { markDirty(roomKey); return }
        guard await HouseLedgerSyncGate.shared.begin(roomKey) else { return }
        defer { Task { await HouseLedgerSyncGate.shared.end(roomKey) } }
        let pending = pendingEvents(roomKey: roomKey)
        guard !pending.isEmpty else { clearDirty(roomKey); return }
        var uploaded: [HouseLedgerEvent] = []
        var failed = false
        for ev in pending {
            do {
                try await HouseRemoteClient.shared.appendLedger(roomKey: roomKey, event: ev)
                uploaded.append(ev)
            } catch {
                failed = true
            }
        }
        if !uploaded.isEmpty {
            _ = mergeAndSave(roomKey: roomKey, events: uploaded)
            removePendingEvents(roomKey: roomKey, eventIds: Set(uploaded.map { $0.id }))
        }
        if failed {
            markDirty(roomKey)
        } else {
            clearDirty(roomKey)
        }
    }

    /// 补传所有 dirty 房号的待确认账本事件（全量同步时调用）
    static func flushPendingAll() async {
        for k in dirtyRoomKeys() { await syncPending(roomKey: k) }
    }
    #endif

    // MARK: 云端合并（append-only 按事件 id 取并集）

    /// 本地与远端合并：事件按 id 取并集，时间正序
    private static func merged(roomKey: String, local: HouseLedgerFile, remote: HouseLedgerFile?) -> HouseLedgerFile {
        var events = local.events
        var ids = Set(events.map { $0.id })
        if let remote {
            // v2.46：旧版本（hist-/hist2-）迁移事件一律不再接收，防止没升级的设备把旧条目合并回来
            for e in remote.events where !ids.contains(e.id)
                && (!e.migrated || e.id.hasPrefix(HouseLedgerMigrator.currentHistPrefix)) {
                events.append(e)
                ids.insert(e.id)
            }
        }
        events.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
        let baseRevision = remote?.revision ?? 0
        return HouseLedgerFile(roomKey: roomKey, revision: max(baseRevision + 1, local.revision + 1), events: events)
    }


}


// MARK: - 房号解析工具

enum HouseLedgerMigrator {
    /// 从文本里提取房号 key（1-/2- 开头，到空格或斜杠为止），如「1-2059/xxx」「1-7899测：更新…」
    static func parseRoomKey(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(1|2)-[^\s/：:]+"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        let key = String(text[r])
        return key.isEmpty ? nil : key
    }
}

// MARK: - 账本时间格式化

enum HouseLedgerFormat {
    static func date(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }

    /// kind 转中文：video → 视频，其余 → 图片
    static func kindLabel(_ kind: String) -> String { kind == "video" ? "视频" : "图片" }

    /// 把 (文件名, kind) 清单分成图片 / 视频两组
    static func split(_ files: [(name: String, kind: String)]) -> (images: [String], videos: [String]) {
        var images: [String] = [], videos: [String] = []
        for f in files {
            if f.kind == "video" { videos.append(f.name) } else { images.append(f.name) }
        }
        return (images, videos)
    }

    /// 媒体分型后的人类可读明细，如「图片 2 个：a.jpg、b.jpg」「视频 1 个：c.mov」
    static func mediaParts(images: [String], videos: [String], includeNames: Bool = true) -> [String] {
        var out: [String] = []
        let imgs = images.sorted(), vids = videos.sorted()
        if !imgs.isEmpty {
            out.append("图片 \(imgs.count) 个" + (includeNames ? "：\(imgs.joined(separator: "、"))" : ""))
        }
        if !vids.isEmpty {
            out.append("视频 \(vids.count) 个" + (includeNames ? "：\(vids.joined(separator: "、"))" : ""))
        }
        return out
    }

    /// 媒体分型的一句话总览（不带文件名），如「图片 2 个、视频 1 个」
    static func mediaSummary(images: Int, videos: Int) -> String {
        mediaParts(images: Array(repeating: "", count: images),
                   videos: Array(repeating: "", count: videos),
                   includeNames: false).joined(separator: "、")
    }
}

/// v2.60：新增房源失败 / 补传成功的日志文案统一在这里生成，避免操作日志里
/// 同时出现「新增媒体失败」「新增房源成功」「上传媒体成功」「补传后补写账本」四条。
enum HouseMediaLogFormat {
    /// 把底层错误压成一句人话：转码失败优先，其次断网，其他保留原文。
    static func failureReason(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["上传失败：", "上传失败:", "错误：", "错误:"] {
            if text.hasPrefix(prefix) {
                text.removeFirst(prefix.count)
                break
            }
        }
        if text.contains("转码") { return "视频转码失败" }
        if text.contains("网络") { return "网络不可用" }
        if text.contains("文件不存在") { return "本地文件不存在" }
        return text.isEmpty ? "媒体上传失败" : text
    }

    /// 新增房源部分失败：一条日志讲清楚「媒体数量 + 失败原因 + 已挂任务中心」。
    static func failureDetail(images: Int, videos: Int, error: String) -> String {
        var counts: [String] = []
        if images > 0 { counts.append("图片\(images)个") }
        if videos > 0 { counts.append("视频\(videos)个") }
        let reason = failureReason(error)
        let reasonText = reason.hasPrefix("因") ? reason : "因\(reason)"
        return (counts.isEmpty ? "" : counts.joined(separator: "，") + "，") +
            "错误原因：\(reasonText)，已挂任务中心，等待重试"
    }

    /// 重试全部成功：只写一条，明确「补传数量 + 账本是否已写回云端」。
    static func retryDetail(fileCount: Int, ledgerWritten: Bool) -> String {
        "\(max(0, fileCount))个媒体补传成功" + (ledgerWritten ? "，云端账本已写入" : "")
    }
}
