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
                       date: Date = Date()) -> HouseLedgerEvent {
        let event = HouseLedgerEvent(date: date, action: action, detail: detail, fieldChanges: fieldChanges)
        fileLock.lock()
        var pending = loadPendingUnlocked(roomKey: roomKey)
        pending.append(event)
        savePendingUnlocked(roomKey: roomKey, events: pending)
        fileLock.unlock()
        scheduleSync(roomKey: roomKey)
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

    /// v2.52：有云配置就后台合并上传；无配置/无效配置也标记待同步，配置好后启动自动补
    static func scheduleSync(roomKey: String) {
        // 服务器模式：账本权威源在 8082 服务器库，切割期旧 COS 桶只作回退底、不回写；
        // 待确认事件保留本机 pending 兜底，不向旧桶发起账本写请求。
        // 分享扩展不含服务器模式判定，条件编译剔除该分支，保持旧链路兜底。
        #if !APP_EXTENSION
        if HouseServerMode.ready {
            markDirty(roomKey)
            return
        }
        #endif
        guard let config = CosConfig.load(), config.isValid else {
            markDirty(roomKey)
            return
        }
        Task {
            do { try await sync(roomKey: roomKey, config: config) }
            catch { markDirty(roomKey) }
        }
    }

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

    /// 单房合并上传：拉远端 → 正式账本+待确认事件一并并集 → 写回；
    /// 弱网/写失败重试一轮，仍失败上抛。成功后待确认事件才并入正式账本并清 pending。
    static func sync(roomKey: String, config: CosConfig) async throws {
        // v2.68：先收养扩展留在共享容器的待确认事件，再走原有合并上传
        adoptSharedPending(roomKey: roomKey)
        // 目录已被删除（如删房后云端失败残留的 dirty 名单）：正式账本与 pending 都不在才清标记，
        // 只剩 pending 时必须继续同步，否则待确认事件永远无法落地
        let hasLedger = FileManager.default.fileExists(atPath: localURL(roomKey: roomKey).path)
        let hasPending = FileManager.default.fileExists(atPath: pendingURL(roomKey: roomKey).path)
        if !hasLedger && !hasPending {
            clearDirty(roomKey)
            return
        }
        guard await HouseLedgerSyncGate.shared.begin(roomKey) else { return }
        defer { Task { await HouseLedgerSyncGate.shared.end(roomKey) } }
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let remote = try await fetchRemote(roomKey: roomKey, config: config)
                fileLock.lock()
                let local = loadUnlocked(roomKey: roomKey)
                let pending = loadPendingUnlocked(roomKey: roomKey)
                fileLock.unlock()
                // 待确认事件并入本次上传的本地副本（按 id 去重），但先不写正式文件
                var combined = local
                let known = Set(local.events.map { $0.id })
                combined.events = local.events + pending.filter { !known.contains($0.id) }
                let mergedFile = merged(roomKey: roomKey, local: combined, remote: remote)
                // v2.58（#9）：上传前再读一次 revision，与刚合并用的 remote 比对
                // （与 CosUploader.uploadGuarded 同一套 CAS 思路）：刚被别人写过 → 本轮不写，
                // 进入下一轮用最新远端重新合并；两轮都变化说明对方持续在写，抛冲突不再静默覆盖。
                let fresh = try await fetchRemote(roomKey: roomKey, config: config)
                if (fresh?.revision ?? 0) != (remote?.revision ?? 0) {
                    if attempt == 0 { continue }
                    throw CloudSyncConflict.recordChanged(roomKey: roomKey, by: "另一台设备")
                }
                let data = try JSONEncoder().encode(mergedFile)
                try await CosUploader.upload(data: data, to: cloudPath(roomKey: roomKey),
                                            contentType: "application/json", config: config)
                // 云端确认成功：事件才落正式账本，并清空 pending
                fileLock.lock()
                writeLocked(roomKey: roomKey, file: mergedFile)
                savePendingUnlocked(roomKey: roomKey, events: [])
                fileLock.unlock()
                clearDirty(roomKey)
                return
            } catch {
                lastError = error
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
        }
        markDirty(roomKey)
        if let lastError { throw lastError }
    }

    /// 批量同步（启动/同步页收尾）：逐房串行，失败不影响其他
    static func syncAll(roomKeys: [String], config: CosConfig) async {
        for key in roomKeys {
            do { try await sync(roomKey: key, config: config) }
            catch { markDirty(key) }
        }
    }

    /// 只拉远端合并到本地（别人操作的事件），不上传
    static func pull(roomKey: String, config: CosConfig) async throws {
        let remote = try await fetchRemote(roomKey: roomKey, config: config)
        guard let remote, !remote.events.isEmpty else { return }
        fileLock.lock()
        let local = loadUnlocked(roomKey: roomKey)
        let mergedFile = merged(roomKey: roomKey, local: local, remote: remote)
        writeLocked(roomKey: roomKey, file: mergedFile)
        fileLock.unlock()
    }

    /// 改名场景：删旧云端目录前，把旧远端账本合并进新房号本地账本（随后由 sync 一并上传）
    static func adoptRemoteLedger(from oldRoomKey: String, to newRoomKey: String, config: CosConfig) async throws {
        guard oldRoomKey != newRoomKey,
              let remote = try await fetchRemote(roomKey: oldRoomKey, config: config) else { return }
        mergeAndSave(roomKey: newRoomKey, events: remote.events)
    }

    private static func fetchRemote(roomKey: String, config: CosConfig) async throws -> HouseLedgerFile? {
        do {
            let data = try await CosUploader.fetchObjectData(path: cloudPath(roomKey: roomKey), config: config)
            return try JSONDecoder().decode(HouseLedgerFile.self, from: data)
        } catch let e as CosObjectNotFoundError {
            return nil
        }
    }

    /// v2.46：迁移器专用——以「真实事件 + 新一批迁移事件」整体重写本地与云端账本。
    /// 普通 sync 是按 id 取并集，删不掉云端残留的旧迁移事件；这里把两端的迁移事件全部丢弃、
    /// 只保留真实事件（migrated == false），再换上新生成的迁移事件，云端同写同清。
    static func replaceMigratedSync(roomKey: String,
                                   newMigratedEvents: [HouseLedgerEvent],
                                   config: CosConfig) async throws {
        guard await HouseLedgerSyncGate.shared.begin(roomKey) else {
            markDirty(roomKey)
            return
        }
        defer { Task { await HouseLedgerSyncGate.shared.end(roomKey) } }
        let remote = try await fetchRemote(roomKey: roomKey, config: config)
        fileLock.lock()
        let local = loadUnlocked(roomKey: roomKey)
        fileLock.unlock()

        var realEvents: [HouseLedgerEvent] = []
        var seen = Set<String>()
        for e in local.events + (remote?.events ?? []) where !e.migrated {
            if seen.insert(e.id).inserted { realEvents.append(e) }
        }
        var events = realEvents + newMigratedEvents
        events.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
        let baseRevision = max(remote?.revision ?? 0, local.revision)
        let file = HouseLedgerFile(roomKey: roomKey, revision: baseRevision + 1, events: events)
        let data = try JSONEncoder().encode(file)
        try await CosUploader.upload(data: data, to: cloudPath(roomKey: roomKey),
                                    contentType: "application/json", config: config)
        fileLock.lock()
        writeLocked(roomKey: roomKey, file: file)
        fileLock.unlock()
        clearDirty(roomKey)
    }

    /// v2.47：一次性清理已废弃的笼统动作（如「媒体更新」）——本地与云端同时删除，
    /// 走同步门串行，基于两端最新 revision 整体重写，避免并集合并又把它拉回来
    static func purgeDeprecatedActionsSync(roomKey: String,
                                          actions: Set<String>,
                                          config: CosConfig) async throws {
        guard await HouseLedgerSyncGate.shared.begin(roomKey) else {
            markDirty(roomKey)
            return
        }
        defer { Task { await HouseLedgerSyncGate.shared.end(roomKey) } }
        let remote = try await fetchRemote(roomKey: roomKey, config: config)
        fileLock.lock()
        let local = loadUnlocked(roomKey: roomKey)
        fileLock.unlock()

        var seen = Set<String>()
        var kept: [HouseLedgerEvent] = []
        for e in local.events + (remote?.events ?? []) {
            if seen.insert(e.id).inserted && !actions.contains(e.action) {
                kept.append(e)
            }
        }
        kept.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
        let baseRevision = max(remote?.revision ?? 0, local.revision)
        let file = HouseLedgerFile(roomKey: roomKey, revision: baseRevision + 1, events: kept)
        let data = try JSONEncoder().encode(file)
        try await CosUploader.upload(data: data, to: cloudPath(roomKey: roomKey),
                                    contentType: "application/json", config: config)
        fileLock.lock()
        writeLocked(roomKey: roomKey, file: file)
        fileLock.unlock()
        clearDirty(roomKey)
    }

    /// v2.53：全量撤回——按事件 id 从本地与云端整体重写移除（事件可能已同步落地）。
    /// 走同步门串行，基于两端最新 revision 整体重写，避免并集合并又把被删事件拉回来。
    static func purgeEventsSync(roomKey: String,
                                eventIds: Set<String>,
                                config: CosConfig) async throws {
        guard !eventIds.isEmpty else { return }
        guard await HouseLedgerSyncGate.shared.begin(roomKey) else {
            markDirty(roomKey)
            return
        }
        defer { Task { await HouseLedgerSyncGate.shared.end(roomKey) } }
        let remote = try await fetchRemote(roomKey: roomKey, config: config)
        fileLock.lock()
        let local = loadUnlocked(roomKey: roomKey)
        fileLock.unlock()

        var seen = Set<String>()
        var kept: [HouseLedgerEvent] = []
        for e in local.events + (remote?.events ?? []) {
            if seen.insert(e.id).inserted && !eventIds.contains(e.id) {
                kept.append(e)
            }
        }
        kept.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
        let baseRevision = max(remote?.revision ?? 0, local.revision)
        let file = HouseLedgerFile(roomKey: roomKey, revision: baseRevision + 1, events: kept)
        let data = try JSONEncoder().encode(file)
        try await CosUploader.upload(data: data, to: cloudPath(roomKey: roomKey),
                                    contentType: "application/json", config: config)
        fileLock.lock()
        writeLocked(roomKey: roomKey, file: file)
        fileLock.unlock()
    }
}

// MARK: - v2.47 废弃动作一次性清理（幂等）

enum HouseLedgerDeprecatedCleanup {
    /// 已从代码移除、历史账本里残留的笼统动作
    static let deprecatedActions: Set<String> = ["媒体更新"]
    private static let flagKey = "houseLedger.cleanup.deprecated.v1"

    static func run() {
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        let rooms = HouseLedgerStore.allLocalRoomKeys()
        guard !rooms.isEmpty else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }
        let config = CosConfig.load()
        Task {
            if let config, config.isValid {
                for roomKey in rooms {
                    do {
                        try await HouseLedgerStore.purgeDeprecatedActionsSync(
                            roomKey: roomKey, actions: deprecatedActions, config: config)
                    } catch {
                        HouseLedgerStore.markDirty(roomKey)
                    }
                }
            } else {
                // 无云配置：只做本地清理
                for roomKey in rooms {
                    HouseLedgerStore.purgeDeprecatedActionsLocal(
                        roomKey: roomKey, actions: deprecatedActions)
                }
            }
            UserDefaults.standard.set(true, forKey: flagKey)
        }
    }
}

// MARK: - v2.45 历史日志迁移（一次性，幂等）

enum HouseLedgerMigrator {
    // v2.46：v3——修复 v2 只清本地、云端旧迁移事件被并集合并拉回导致新旧成对的问题；
    // 同时对云端公共记录与本机日志的同一动作去重
    private static let flagKey = "houseLedger.migration.v3"
    /// 当前代迁移事件的 id 前缀，旧代事件不再接收
    static let currentHistPrefix = "hist3-"
    static var hasRun: Bool { UserDefaults.standard.bool(forKey: flagKey) }

    /// 启动时调用：把云端公共操作记录 + 本机操作日志里能识别房号的动作，迁到各房账本。
    /// validRoomKeys：当前真实房源的媒体目录名集合，用于保护真实目录、清理误建的畸形目录
    static func run(validRoomKeys: Set<String>) {
        guard !hasRun else { return }
        let localEntries = BackupLogStore.all()
        if CloudOps.isConfigured {
            CloudOps.fetch { cloudEntries in
                Task { await build(cloud: cloudEntries, local: localEntries, validRoomKeys: validRoomKeys) }
            }
        } else {
            Task { await build(cloud: [], local: localEntries, validRoomKeys: validRoomKeys) }
        }
    }

    /// 合法房号目录名：1-/2- 前缀 + 房号数字（可带「上/下/测/层」等中文或字母后缀），
    /// 不含空格、括号、点号、文件名等
    static func isValidRoomKey(_ key: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^(1|2)-[0-9]+[0-9A-Za-z\u4e00-\u9fa5]*$"#) else { return false }
        let range = NSRange(key.startIndex..., in: key)
        return regex.firstMatch(in: key, range: range) != nil
    }

    /// 清掉迁移器误建的畸形目录：名字不符合房号规则、且当前没有任何房源记录引用。
    /// 这些目录是旧迁移器从日志文本里误解析房号、写账本时连带创建的；云端若同步过也一并删除
    private static func cleanupMalformedFolders(validRoomKeys: Set<String>, config: CosConfig?) async {
        for key in HouseLedgerStore.allLocalRoomKeys() {
            guard !validRoomKeys.contains(key), !isValidRoomKey(key) else { continue }
            let dir = MediaStore.houseDirectory(roomKey: key)
            try? FileManager.default.removeItem(at: dir)
            HouseLedgerStore.clearDirty(key)
            if let config {
                try? await CloudBackupService.deleteRemoteObject(
                    name: HouseLedgerStore.cloudPath(roomKey: key), config: config)
            }
        }
    }

    private static func build(cloud: [CloudOpEntry], local: [BackupLogEntry],
                             validRoomKeys: Set<String>) async {
        // 0) 先清掉历史上误建的畸形目录（本地 + 云端）
        await cleanupMalformedFolders(validRoomKeys: validRoomKeys, config: CosConfig.load())

        var grouped: [String: [HouseLedgerEvent]] = [:]
        // 同一动作可能同时存在于云端公共记录和本机日志，按「房号+分钟+动作+明细」去重
        var dedupKeys = Set<String>()

        // 1) 云端公共记录（带 room 字段；旧记录 room 为空时从 detail 解析）
        for e in cloud {
            let roomKey = e.room.isEmpty ? parseRoomKey(in: e.detail) : e.room
            guard let roomKey, !roomKey.isEmpty, isValidRoomKey(roomKey) else { continue }
            let parts = e.op.components(separatedBy: "·")
            let rawAction = parts.count >= 2 ? "\(parts[0])·\(parts[1])" : e.op
            let date = parseDate(e.t) ?? Date()
            guard let normalized = normalize(action: rawAction, detail: e.detail) else { continue }
            let dk = dedupKey(roomKey: roomKey, date: date, action: normalized.action, detail: normalized.detail)
            guard dedupKeys.insert(dk).inserted else { continue }
            let event = HouseLedgerEvent(
                id: historicalID("cloud|\(e.id)"),
                date: date,
                operatorName: e.user.isEmpty ? "未知用户" : e.user,
                action: normalized.action,
                detail: normalized.detail,
                migrated: true
            )
            grouped[roomKey, default: []].append(event)
        }

        // 2) 本机日志（无 room 字段，从 detail 解析房号；解析不出的无法归属，跳过）
        for e in local {
            guard let roomKey = parseRoomKey(in: e.detail), isValidRoomKey(roomKey) else { continue }
            let rawAction = "\(e.category)·\(e.action)"
            guard let normalized = normalize(action: rawAction, detail: e.detail) else { continue }
            let dk = dedupKey(roomKey: roomKey, date: e.date, action: normalized.action, detail: normalized.detail)
            guard dedupKeys.insert(dk).inserted else { continue }
            let event = HouseLedgerEvent(
                id: historicalID("local|\(e.date.timeIntervalSinceReferenceDate)|\(e.category)|\(e.action)|\(e.detail)"),
                date: e.date,
                operatorName: e.username ?? "本机",
                action: normalized.action,
                detail: normalized.detail,
                migrated: true
            )
            grouped[roomKey, default: []].append(event)
        }

        // 3) 所有本机账本房号逐房整体重写（含本次没有新迁移事件的房，也要清掉云端旧条目）
        let allRooms = HouseLedgerStore.allLocalRoomKeys()
        if let config = CosConfig.load(), config.isValid {
            for roomKey in allRooms {
                do {
                    try await HouseLedgerStore.replaceMigratedSync(
                        roomKey: roomKey,
                        newMigratedEvents: grouped[roomKey] ?? [],
                        config: config)
                } catch {
                    HouseLedgerStore.markDirty(roomKey)
                }
            }
        } else {
            // 无云配置：本地逐房清迁移事件，再并入新事件
            for roomKey in allRooms {
                HouseLedgerStore.purgeMigrated(roomKey: roomKey)
                HouseLedgerStore.mergeAndSave(roomKey: roomKey, events: grouped[roomKey] ?? [])
            }
        }
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// 去重键：时间精确到分钟（云端记录本身只到分钟），同房同分钟同动作同明细视为同一动作
    private static func dedupKey(roomKey: String, date: Date, action: String, detail: String) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return "\(roomKey)|\(c.year!)-\(c.month!)-\(c.day!) \(c.hour!):\(c.minute!)|\(action)|\(detail)"
    }

    /// v2.46：迁移条目按新口径归一——去「同步」后缀、技术词改名；明细为空的「修改房源」直接丢弃
    private static func normalize(action rawAction: String, detail: String) -> (action: String, detail: String)? {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDetail.isEmpty && rawAction.contains("修改房源") { return nil }
        var action = rawAction
        if action.hasSuffix("同步") { action = String(action.dropLast(2)) }
        let renames: [String: String] = [
            "重建本地账本镜像": "本地数据刷新",
            "云端覆盖本地": "云端更新本机",
            "跳过云端覆盖": "保留本机修改",
            "清理账本失效媒体引用": "清理失效媒体记录",
            "冲突合并": "合并云端更新"
        ]
        for (old, new) in renames where action.contains(old) {
            action = action.replacingOccurrences(of: old, with: new)
        }
        return (action, detail)
    }

    // MARK: 解析工具

    /// 从文本里提取房号 key（1-/2- 开头，到空格或斜杠为止），如「1-2059/xxx」「1-7899测：更新…」
    static func parseRoomKey(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(1|2)-[^\s/：:]+"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        let key = String(text[r])
        return key.isEmpty ? nil : key
    }

    private static func parseDate(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.date(from: s)
    }

    private static func historicalID(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // v2.46：换前缀，与旧迁移事件区分
        return "hist3-" + String(hex.prefix(20))
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
