import Foundation
import Combine
import SwiftUI
import SwiftData

// MARK: - 任务模型

/// 任务类型：名字全部用日常话，界面不出现技术词
enum SyncTaskKind: String, Codable, CaseIterable {
    case cloudPull   // 从云端拉下来
    case pushUp      // 把本机改动传上去
    case media       // 搬媒体（上传/补传/下载）
    case cloudDelete // 删云端
    case retry       // 补漏与失败重试
    case orphan      // 清理桶孤儿媒体
    case mediaDelete // 删云端媒体（本地已删，云端对象没删掉）
    case houseDraft  // 断网时没提交成功的房源改动（原草稿箱，现并入任务中心）

    var displayName: String {
        switch self {
        case .cloudPull: return "从云端拉下来"
        case .pushUp: return "把本机改动传上去"
        case .media: return "搬媒体"
        case .cloudDelete: return "删云端"
        case .retry: return "补漏与失败重试"
        case .orphan: return "清理桶孤儿媒体"
        case .mediaDelete: return "删云端媒体"
        case .houseDraft: return "提交房源改动"
        }
    }

    var iconName: String {
        switch self {
        case .cloudPull: return "arrow.triangle.2.circlepath"
        case .pushUp: return "arrow.up.circle"
        case .media: return "photo.on.rectangle.angled"
        case .cloudDelete: return "trash"
        case .retry: return "wrench.and.screwdriver"
        case .orphan: return "trash.circle"
        case .mediaDelete: return "trash.slash"
        case .houseDraft: return "square.and.pencil"
        }
    }

    /// 全部支持手动重试；孤儿扫描的「取消本次」是另一条路径，不走重试
    var isRetryable: Bool { true }
}

/// v2.59：上传速度的统一文案（0 或异常值返回空串，界面不显示“0 MB/s”误导）
enum UploadSpeedText {
    static func format(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "" }
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        if bytesPerSecond >= 1_024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

/// 一条任务（值类型 + Codable，直接持久化到 UserDefaults）
struct TaskRecord: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        case running, failed, finished, cancelled
    }

    var id: UUID = UUID()
    var kind: SyncTaskKind
    var title: String
    var roomKeys: [String] = []
    var note: String = ""
    var failure: String = ""
    /// 需要按文件重试的任务（删云端媒体）：存具体文件名；旧数据没有该键时为 nil
    var files: [String]? = nil
    /// v2.52：保存房源时的媒体上传任务（区别于旧的分享补传，重试走逐文件上传）
    var isHouseUpload: Bool? = nil
    var total: Int = 1
    var done: Int = 0
    /// v2.59：当前文件内的字节进度（0...1）；旧数据没有该键时为 nil
    var currentFileFraction: Double? = nil
    /// v2.59：实时上传速度（字节/秒）；只在 running 时显示，旧数据没有该键时为 nil
    var bytesPerSecond: Double? = nil
    var state: State = .running
    var createdAt: Date = Date()
    var finishedAt: Date? = nil

    var fraction: Double {
        guard total > 0 else { return 0 }
        let completed = min(Double(done) / Double(total), 1.0)
        guard let currentFileFraction, done < total else { return completed }
        let inFile = max(0, min(1, currentFileFraction))
        return min((Double(done) + inFile) / Double(total), 1.0)
    }

    var percentText: String { "\(Int(fraction * 100))%" }

    /// 任务行百分比旁的速度文案；没有速度时保持原百分比
    var percentWithSpeedText: String {
        guard let bytesPerSecond, !UploadSpeedText.format(bytesPerSecond).isEmpty else {
            return percentText
        }
        return "\(percentText) · \(UploadSpeedText.format(bytesPerSecond))"
    }

    /// v2.53：房源上传任务的全量撤回载荷（旧数据没有该键，解码为 nil，退化为仅删条目）
    var rollback: HouseUploadRollback? = nil
}

// MARK: - v2.53 全量撤回载荷（彻底取消=撤回本次任务全部改动）

/// 一条媒体引用（文件名 + 类型 image/video）
struct HouseUploadMediaRef: Codable, Hashable {
    let fileName: String
    let kind: String
}

/// 编辑前的字段快照（8 个字段，撤回时恢复原样）
struct HouseUploadBeforeSnapshot: Codable, Hashable {
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var statusRaw: String
}

/// 房源上传任务的回滚载荷：记录本次任务改了什么、改之前是什么，供「彻底取消」全量撤回
struct HouseUploadRollback: Codable, Equatable {
    /// 场景：新增整套 / 改名（含跨座）/ 普通编辑
    enum Scene: String, Codable { case newHouse, rename, plainEdit }

    var scene: Scene
    /// 当前（保存后）媒体目录 key
    var roomKey: String
    /// 改名场景的旧目录 key（非改名时为空串）
    var oldRoomKey: String
    /// 编辑前字段快照（newHouse 场景为 nil，整套删除无需恢复字段）
    var before: HouseUploadBeforeSnapshot?
    /// 本次新增的媒体（撤回时本地+云端全删）
    var added: [HouseUploadMediaRef]
    /// 本次删除的旧媒体（撤回时尽量从云端下载恢复）
    var removed: [HouseUploadMediaRef]
    /// 本次账本事件 id（撤回时从 pending 与正式账本移除）
    var ledgerEventIds: [String]
}

// MARK: - v2.52 上传任务句柄登记（取消按钮靠它真正中断 Task）

@MainActor
final class UploadTaskRegistry {
    static let shared = UploadTaskRegistry()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func register(_ id: UUID, task: Task<Void, Never>) {
        tasks[id] = task
    }

    func unregister(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }

    /// 取消：Task.cancel 会中断 URLSession 上传与转码等待
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }
}

// MARK: - 任务中心存储

/// 统一任务中心：进行中 / 待处理（只能手动重试，不做任何自动重试）/ 最近完成。
/// 失败与完成记录持久化在 UserDefaults，杀掉 App 再进来依旧在；
/// 启动时若发现上次有「进行中」残留（进程被杀），一律转成待处理，不丢任务。
@MainActor
final class SyncTaskCenter: ObservableObject {
    static let shared = SyncTaskCenter()

    @Published private(set) var running: [TaskRecord] = []
    @Published private(set) var failed: [TaskRecord] = []
    @Published private(set) var done: [TaskRecord] = []

    /// 临时进度（总刷新 / 整次同步用）：只在房源页顶部显示进度条，
    /// 结束就消失，不进「待处理」也不进「最近完成」，不落盘——避免点一次同步就留一条记录。
    @Published private(set) var transient: TaskRecord? = nil

    private let failedKey = "taskCenter.failed.v1"
    private let doneKey = "taskCenter.done.v1"
    private let maxFailed = 50
    private let maxDone = 20
    private var bootstrapped = false
    private var sinks: [AnyCancellable] = []

    private init() {
        loadPersisted()
    }

    // MARK: 入队 / 进度 / 结束

    @discardableResult
    func begin(kind: SyncTaskKind,
               title: String,
               roomKeys: [String] = [],
               total: Int = 1,
               note: String = "") -> UUID {
        var item = TaskRecord(kind: kind, title: title, roomKeys: roomKeys,
                              note: note, total: max(1, total), state: .running)
        running.append(item)
        return item.id
    }

    /// v2.52：用外部预先固定的 id 建任务（工作 Task 句柄要在创建前拿到 id 注册）
    @discardableResult
func begin(id: UUID,
               kind: SyncTaskKind,
               title: String,
               roomKeys: [String] = [],
               total: Int = 1,
               note: String = "",
               files: [String]? = nil,
               isHouseUpload: Bool = false,
               rollback: HouseUploadRollback? = nil) -> UUID {
        var item = TaskRecord(id: id, kind: kind, title: title, roomKeys: roomKeys,
                              note: note, files: files, total: max(1, total), state: .running)
        item.isHouseUpload = isHouseUpload
        item.rollback = rollback
        running.append(item)
        return id
    }

    func advance(id: UUID, done: Int, total: Int? = nil, note: String? = nil, currentFileFraction: Double? = nil) {
        guard let idx = running.firstIndex(where: { $0.id == id }) else { return }
        running[idx].done = max(0, done)
        if let total { running[idx].total = max(1, total) }
        if let note { running[idx].note = note }
        running[idx].currentFileFraction = currentFileFraction
    }

    /// v2.59：当前文件内的进度；只在 done 仍等于该文件序号时更新，防止上传完成后的迟到回调把进度拉回去
    func advanceWithinFile(id: UUID, fileIndex: Int, fraction: Double, note: String? = nil) {
        guard let idx = running.firstIndex(where: { $0.id == id }), running[idx].done == fileIndex else { return }
        running[idx].currentFileFraction = max(0, min(1, fraction))
        if let note { running[idx].note = note }
    }

    /// v2.59：实时网速；单独更新，不打断当前文件进度
    func updateSpeed(id: UUID, bytesPerSecond: Double?) {
        guard let idx = running.firstIndex(where: { $0.id == id }) else { return }
        running[idx].bytesPerSecond = bytesPerSecond
    }

    func finish(id: UUID, success: Bool, failure: String = "", note: String = "") {
        guard let idx = running.firstIndex(where: { $0.id == id }) else {
            // 兜底：进程切换后 running 已被转成 failed，也允许按结果归位
            if let fidx = failed.firstIndex(where: { $0.id == id }) {
                if success {
                    var item = failed.remove(at: fidx)
                    item.state = .finished
                    item.failure = ""
                    item.finishedAt = Date()
                    item.currentFileFraction = nil
                    item.bytesPerSecond = nil
                    if !note.isEmpty { item.note = note }
                    pushDone(item)
                } else {
                    if !failure.isEmpty { failed[fidx].failure = failure }
                    failed[fidx].state = .failed
                    failed[fidx].currentFileFraction = nil
                    failed[fidx].bytesPerSecond = nil
                }
                persist()
            }
            return
        }
        var item = running.remove(at: idx)
        item.finishedAt = Date()
        item.currentFileFraction = nil
        item.bytesPerSecond = nil
        if success {
            item.state = .finished
            item.failure = ""
            if !note.isEmpty { item.note = note }
            item.done = item.total
            pushDone(item)
        } else {
            item.state = .failed
            item.failure = failure.isEmpty ? "失败了，请重试" : failure
            if !note.isEmpty { item.note = note }
            // 同类型同房号的旧失败合并，避免反复进页面挂一屏重复项
            if let dup = failed.firstIndex(where: { $0.kind == item.kind && $0.roomKeys == item.roomKeys }) {
                failed[dup] = item
            } else {
                failed.insert(item, at: 0)
                if failed.count > maxFailed { failed = Array(failed.prefix(maxFailed)) }
            }
        }
        persist()
    }

    /// 无声收掉一条任务（如「检查云端更新」发现没变化）：不进最近完成，不留痕
    func discard(id: UUID) {
        if let idx = running.firstIndex(where: { $0.id == id }) {
            running.remove(at: idx)
            persist()
        }
    }

    /// 一次性失败（没有进行中过程的场景，如检测失败、单套推送失败）直接挂待处理
    @discardableResult
    func reportFailure(kind: SyncTaskKind,
                       title: String,
                       roomKeys: [String] = [],
                       failure: String,
                       note: String = "",
                       files: [String]? = nil) -> UUID {
        // 同类型同房号的旧失败先合并，避免同一件事挂一屏
        if let existing = failed.first(where: { $0.kind == kind && $0.roomKeys == roomKeys }) {
            var merged = existing
            merged.failure = failure
            merged.note = note
            if let files { merged.files = Array(Set((existing.files ?? []) + files)) }
            if let i = failed.firstIndex(where: { $0.id == existing.id }) { failed[i] = merged }
            persist()
            return existing.id
        }
        var item = TaskRecord(kind: kind, title: title, roomKeys: roomKeys,
                              note: note, total: max(1, roomKeys.count), state: .failed)
        item.failure = failure
        item.files = files
        item.finishedAt = Date()
        failed.insert(item, at: 0)
        if failed.count > maxFailed { failed = Array(failed.prefix(maxFailed)) }
        persist()
        return item.id
    }

    /// 取消本次（如孤儿扫描）：停止、不删任何文件，进最近完成并写明「已取消」
    func cancel(id: UUID, note: String) {
        if let idx = running.firstIndex(where: { $0.id == id }) {
            var item = running.remove(at: idx)
            item.state = .finished
            item.finishedAt = Date()
            item.note = note
            pushDone(item)
            persist()
        }
    }

    // MARK: v2.52 上传任务手动取消

    /// 点「取消」：先真正中断 Task；Task 内 catch 到取消会调 finishCancelled。
    /// 兜底：1.5 秒后仍在进行中（取消信号没被接住）就强制转「已取消」，不让界面一直卡着。
    func requestCancel(id: UUID) {
        UploadTaskRegistry.shared.cancel(id)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let idx = running.firstIndex(where: { $0.id == id }) {
                var item = running.remove(at: idx)
                item.state = .cancelled
                item.finishedAt = Date()
                item.failure = "已手动取消，可重试或彻底删除"
                failed.insert(item, at: 0)
                persist()
            }
        }
    }

    /// 上传 Task 捕获到取消后回调：进行中 → 已取消（留在待处理区，可重试/彻底删除）
    func finishCancelled(id: UUID) {
        guard let idx = running.firstIndex(where: { $0.id == id }) else { return }
        var item = running.remove(at: idx)
        item.state = .cancelled
        item.finishedAt = Date()
        item.failure = "已手动取消，本地文件没动；可重试或彻底删除"
        item.currentFileFraction = nil
        item.bytesPerSecond = nil
        if let dup = failed.firstIndex(where: { $0.kind == item.kind && $0.roomKeys == item.roomKeys }) {
            failed[dup] = item
        } else {
            failed.insert(item, at: 0)
        }
        persist()
    }

    /// 彻底删除任务条目（不删本地媒体文件、不碰云端）——仅用于没有回滚载荷的历史任务兜底
    func purge(id: UUID) {
        guard let item = failed.first(where: { $0.id == id }) else { return }
        failed.removeAll { $0.id == id }
        persist()
        // 留痕：让用户在操作日志里能看到「删了哪条任务、没碰房源」，消除「莫名其妙少东西」的疑虑
        BackupLogStore.log(category: "任务", action: "删除任务记录", result: "成功",
                          detail: "仅删除「\(item.title)」任务记录，未改动任何本地文件或云端数据",
                          room: item.roomKeys.first ?? "", cloud: false)
    }

    /// 「彻底取消」：旧链的本地+云端全量撤回随旧桶下线；历史任务这里仅删除任务条目，不再回滚改动。
    func revoke(id: UUID, houseContext: ModelContext?) {
        guard let idx = failed.firstIndex(where: { $0.id == id }) else { return }
        failed.remove(at: idx)
        persist()
    }

    // MARK: 临时进度（总刷新 / 整次同步，不进任务中心）

    @discardableResult
    func beginTransient(kind: SyncTaskKind, title: String, total: Int = 1) -> UUID {
        var item = TaskRecord(kind: kind, title: title, total: max(1, total), state: .running)
        item.done = 0
        transient = item
        return item.id
    }

    func advanceTransient(id: UUID, done: Int, total: Int? = nil, note: String? = nil) {
        guard var item = transient, item.id == id else { return }
        item.done = max(0, done)
        if let total { item.total = max(1, total) }
        if let note { item.note = note }
        transient = item
    }

    /// 结束临时进度：无论成败都只关闭，不写任何历史
    func endTransient(id: UUID) {
        guard let item = transient, item.id == id else { return }
        transient = nil
    }

    // MARK: 手动重试（唯一的重试入口，绝不自动触发）

    func retry(id: UUID) {
        guard let item = failed.first(where: { $0.id == id }) else { return }
        // 整次云端同步：页面流程回报真实结果（成功 / 失败 / 等确认），不再删掉旧任务后无条件记成功
        if item.kind == .cloudPull {
            removeFailed(id: id)
            var live = item
            live.state = .running
            live.failure = ""
            live.note = "正在重试整次同步…"
            live.finishedAt = nil
            live.done = 0
            running.append(live)
            let work = Task {
                let outcome = await TaskRetryPerformer.shared.cloudPull?(live.id)
                    ?? .failed("请先到房源页，再点重试")
                UploadTaskRegistry.shared.unregister(live.id)
                switch outcome {
                case .finished:
                    self.finish(id: live.id, success: true, note: "同步完成")
                    self.notifyRetrySuccess(live, note: "同步完成")
                case .needsConfirmation:
                    // 确认框已弹出（云端变化 / 云端媒体补齐）：任务保持进行中，
                    // 用户点「确认/开始补齐」或「取消」后由页面结算
                    self.advance(id: live.id, done: 0, note: "等你在房源页确认后继续")
                case .failed(let message):
                    self.finish(id: live.id, success: false, failure: message)
                }
            }
            UploadTaskRegistry.shared.register(live.id, task: work)
            return
        }
        if item.kind == .orphan {
            removeFailed(id: id)
            Task { await TaskRetryPerformer.shared.orphanScan?() }
            return
        }
        removeFailed(id: id)
        var live = item
        live.state = .running
        live.failure = ""
        live.note = "正在重试…"
        live.finishedAt = nil
        running.append(live)
        let work = Task {
            await TaskRetryPerformer.shared.perform(live) { [weak self] result in
                guard let self else { return }
                UploadTaskRegistry.shared.unregister(live.id)
                switch result {
                case .success(let note):
                    self.finish(id: live.id, success: true, note: note)
                    // v2.60：新增房源/媒体上传重试成功时，最终日志由 retryHouseUpload 写一条
                    // 「新增房源 / 房号迁移 / 修改房源」，这里不再叠一条「上传媒体 成功」。
                    if live.isHouseUpload != true {
                        // 其他重试也是真实操作：写一条操作日志，账本里能看到「什么时候补传成功的」
                        BackupLogStore.log(category: "同步", action: live.title, result: "成功",
                                          detail: "手动重试成功" + (note.isEmpty ? "" : "：\(note)"),
                                          room: live.roomKeys.prefix(3).joined(separator: "、"),
                                          cloud: true)
                    }
                    self.notifyRetrySuccess(live, note: note)
                case .failure(let message):
                    self.finish(id: live.id, success: false, failure: message)
                }
            }
        }
        UploadTaskRegistry.shared.register(live.id, task: work)
    }

    func removeFailed(id: UUID) {
        failed.removeAll { $0.id == id }
        persist()
    }

    /// v2.60：手动重试成功后补系统通知；前台横幅、通知中心保留，权限被拒时由
    /// HouseActionNotifier 自动降级为顶部页内光条。
    private func notifyRetrySuccess(_ item: TaskRecord, note: String) {
        let room = item.roomKeys.prefix(3).joined(separator: "、")
        let detail = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if room.isEmpty {
            body = detail.isEmpty ? "任务已完成" : detail
        } else {
            body = "\(room)：\(detail.isEmpty ? "任务已完成" : detail)"
        }
        HouseActionNotifier.shared.send(
            key: "taskretry.\(item.id.uuidString)",
            title: "\(item.title)重试成功",
            body: body
        )
    }

    func clearDone() {
        done = []
        persist()
    }

    // MARK: 启动：残留进行中转待处理 + 旧存储迁移

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        // 1) 上次进程被杀时，进行中的任务全部转待处理（不丢、不假装成功）
        for item in running {
            var failedItem = item
            failedItem.state = .failed
            failedItem.failure = "上次没跑完（App 被关掉或中断），请手动重试"
            failed.append(failedItem)
        }
        running = []
        // 2) 旧的「账本未同步」标记迁移进来（旧键只读，由中心接管）
        for key in SyncFailStore.all() {
            guard !failed.contains(where: { $0.kind == .pushUp && $0.roomKeys == [key] }) else { continue }
            var item = TaskRecord(kind: .pushUp, title: "把本机改动传上去",
                                  roomKeys: [key], total: 1, state: .failed)
            item.failure = "\(key) 的改动还在本机，云端没同步上；点重试"
            item.finishedAt = Date()
            failed.append(item)
        }
        // 3) 旧的待补传媒体队列整体迁移进来（队列本身保留，只做「待上传豁免」登记，不再自动补传）
        migrateMediaQueue()
        // 3.1) 原来的草稿箱并入任务中心：草稿不再是独立入口，统一按「提交房源改动」待处理
        migrateDrafts()
        if failed.count > maxFailed { failed = Array(failed.prefix(maxFailed)) }
        persist()

        // 4) 运行期旧存储一旦新增标记，实时并进中心（不用逐个改调用点）
        // 注意：enqueue / mark 常在后台线程调用，并入必须切回主线程改 @Published，否则界面不刷新
        NotificationCenter.default.publisher(for: SyncFailStore.didChange)
            .sink { [weak self] _ in
                Task { @MainActor in self?.absorbNewSyncFailures() }
            }
            .store(in: &sinks)
        NotificationCenter.default.publisher(for: HouseMediaUploadQueue.didEnqueue)
            .sink { [weak self] _ in
                Task { @MainActor in self?.migrateMediaQueue() }
            }
            .store(in: &sinks)
        NotificationCenter.default.publisher(for: HouseDraftStore.didChange)
            .sink { [weak self] _ in
                Task { @MainActor in self?.migrateDrafts() }
            }
            .store(in: &sinks)
    }

    /// 草稿箱并入任务中心：一条草稿 = 一条「提交房源改动」待处理，重试即提交
    private func migrateDrafts() {
        let drafts = HouseDraftStore.shared.drafts
        // 草稿已经提交成功/被删掉的，对应的任务同步收掉
        let aliveKeys = Set(drafts.map { $0.roomKey })
        failed.removeAll { $0.kind == .houseDraft && !aliveKeys.contains($0.roomKeys.first ?? "") }
        for draft in drafts {
            if let i = failed.firstIndex(where: { $0.kind == .houseDraft && $0.roomKeys == [draft.roomKey] }) {
                failed[i].note = draft.changeSummary
                failed[i].failure = "\(draft.displayRoomNo) 的改动只存本机，没提交到云端；点重试"
                continue
            }
            var item = TaskRecord(kind: .houseDraft, title: "提交房源改动",
                                  roomKeys: [draft.roomKey], total: 1, state: .failed)
            item.note = draft.changeSummary
            item.failure = "\(draft.displayRoomNo) 的改动只存本机，没提交到云端；点重试"
            item.finishedAt = Date()
            failed.insert(item, at: 0)
        }
        persist()
    }

    /// 一批任务结算时，把同一批房号下零散的单房记录收掉，只留总任务一条
    /// （批量导入必然产生「整批总任务 + 每套房单独记录」，不收掉会刷一屏）
    func absorbBatch(roomKeys: [String], kinds: [SyncTaskKind] = [.media, .pushUp], since: Date? = nil) {
        guard !roomKeys.isEmpty else { return }
        let keySet = Set(roomKeys)
        failed.removeAll { item in
            guard kinds.contains(item.kind) else { return false }
            guard item.roomKeys.allSatisfy({ keySet.contains($0) }) else { return false }
            guard let since else { return true }
            return item.createdAt >= since
        }
        persist()
    }

    private func absorbNewSyncFailures() {
        var changed = false
        for key in SyncFailStore.all() {
            guard !failed.contains(where: { $0.kind == .pushUp && $0.roomKeys == [key] }) else { continue }
            var item = TaskRecord(kind: .pushUp, title: "把本机改动传上去",
                                  roomKeys: [key], total: 1, state: .failed)
            item.failure = "\(key) 的改动还在本机，云端没同步上；点重试"
            item.finishedAt = Date()
            failed.insert(item, at: 0)
            changed = true
        }
        if changed { persist() }
    }

    /// 旧待补传队列并入中心。
    /// 注意：队列本身**不清空**——它不再是「自动补传器」，但仍是「这些文件还没传上」的登记簿，
    /// 同步对账靠它做「待上传豁免」，清空会让本机新拍的文件被误判成多余而删掉。
    private func migrateMediaQueue() {
        let pending = HouseMediaUploadQueue.pendingItems()
        guard !pending.isEmpty else { return }
        let grouped = Dictionary(grouping: pending, by: { $0.roomKey })
        for (roomKey, items) in grouped {
            let fileNames = items.map { $0.fileName }
            // 同房已有任务：把新入队的文件并进去（此前直接 continue，新文件永远进不来）
            if let i = failed.firstIndex(where: { $0.kind == .media && $0.roomKeys == [roomKey] }) {
                let known = Set(failed[i].files ?? [])
                let newFiles = fileNames.filter { !known.contains($0) }
                guard !newFiles.isEmpty else { continue }
                var merged = failed[i]
                let all = Array(known.union(newFiles))
                merged.files = all
                merged.total = max(1, all.count)
                merged.failure = "\(roomKey) 有 \(all.count) 个媒体没传上：\(all.prefix(3).joined(separator: "、"))；点重试"
                failed[i] = merged
                continue
            }
            var task = TaskRecord(kind: .media, title: "搬媒体",
                                  roomKeys: [roomKey], total: max(1, fileNames.count), state: .failed)
            task.files = fileNames
            task.failure = "\(roomKey) 有 \(fileNames.count) 个媒体没传上：\(fileNames.prefix(3).joined(separator: "、"))；点重试"
            task.finishedAt = Date()
            failed.insert(task, at: 0)
        }
        persist()
    }

    // MARK: 持久化

    private func pushDone(_ item: TaskRecord) {
        done.insert(item, at: 0)
        if done.count > maxDone { done = Array(done.prefix(maxDone)) }
    }

    private func loadPersisted() {
        if let data = UserDefaults.standard.data(forKey: failedKey),
           let list = try? JSONDecoder().decode([TaskRecord].self, from: data) {
            failed = list
        }
        if let data = UserDefaults.standard.data(forKey: doneKey),
           let list = try? JSONDecoder().decode([TaskRecord].self, from: data) {
            done = list
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(failed) {
            UserDefaults.standard.set(data, forKey: failedKey)
        }
        if let data = try? JSONEncoder().encode(done) {
            UserDefaults.standard.set(data, forKey: doneKey)
        }
    }

    // MARK: 界面汇总

    var hasAnything: Bool { !running.isEmpty || !failed.isEmpty }
    var badgeCount: Int { running.count + failed.count }
}

// MARK: - 重试执行器（只在用户点重试时被调用）

enum TaskRetryOutcome {
    case success(note: String)
    case failure(message: String)
}

/// v2.58（#3）：整次云端同步重试的真实结果。
/// 页面流程必须回报，任务中心不再在闭包返回后无条件记成功。
enum CloudPullRunOutcome {
    /// 已执行完（成功或无变化）
    case finished
    /// 已拉取云端变化并弹了确认框，等用户在房源页点「确认同步」
    case needsConfirmation
    /// 拉取/预览阶段失败（消息直接进任务中心）
    case failed(String)
}

@MainActor
final class TaskRetryPerformer {
    static let shared = TaskRetryPerformer()

    /// 由房源页注册：整次云端同步（cloudPull）的重试复用房源页同步流程；
    /// 入参是任务中心里的任务 id（页面确认/执行完成后用它结算真实结果）
    var cloudPull: ((UUID?) async -> CloudPullRunOutcome)?
    /// 由设置页注册：孤儿扫描重试
    var orphanScan: (() async -> Void)?

    private weak var houseContext: ModelContext?

    func bind(houseContext: ModelContext) {
        self.houseContext = houseContext
    }

    func perform(_ item: TaskRecord, completion: @escaping (TaskRetryOutcome) -> Void) async {
        switch item.kind {
        case .cloudPull:
            guard let cloudPull else {
                completion(.failure(message: "请先到房源页，再点重试")); return
            }
            switch await cloudPull(nil) {
            case .finished:
                completion(.success(note: "同步完成"))
            case .needsConfirmation:
                completion(.failure(message: "已拉取云端变化，等你在房源页确认后再执行"))
            case .failed(let message):
                completion(.failure(message: message))
            }
        case .orphan:
            guard let orphanScan else {
                completion(.failure(message: "请先到设置页，再点重试")); return
            }
            await orphanScan()
            completion(.success(note: "扫描完成"))
        case .cloudDelete:
            await retryCloudDelete(item, completion: completion)
        case .pushUp:
            await retryPushUp(item, completion: completion)
        case .mediaDelete:
            await retryMediaDelete(item, completion: completion)
        case .houseDraft:
            await retryHouseDraft(item, completion: completion)
        case .media, .retry:
            if item.isHouseUpload == true {
                await retryHouseUpload(item, completion: completion)
            } else {
                await retryMedia(item, completion: completion)
            }
        }
    }

    /// v2.52：保存房源的媒体上传任务（含手动取消后重试）：逐文件走 uploadHouseMedia
    private func retryHouseUpload(_ item: TaskRecord, completion: @escaping (TaskRetryOutcome) -> Void) async {
        guard let config = CosConfig.load(), config.isValid else {
            completion(.failure(message: "云端配置无效，请先到「云端配置」填写")); return
        }
        guard let roomKey = item.roomKeys.first else {
            completion(.failure(message: "缺少房号信息，请到这套房编辑页重新操作")); return
        }
        let files = item.files ?? []
        guard !files.isEmpty else {
            completion(.failure(message: "没有记录到具体文件，请到这套房编辑页重新操作")); return
        }
        var failures: [String] = []
        let progress = HouseSyncProgress.shared
        progress.begin(roomKey: roomKey, direction: .upload, progress: 0, label: "准备重试")
        defer { progress.end() }
        SyncTaskCenter.shared.advance(id: item.id, done: 0, total: files.count, note: "准备重试")
        for (index, fileName) in files.enumerated() {
            let ext = (fileName as NSString).pathExtension.lowercased()
            let kind = ["mov", "mp4", "m4v", "avi"].contains(ext) ? "video" : "image"
            let globalFraction = { (fileFraction: Double) -> Double in
                let doneBase = Double(index)
                let total = Double(files.count)
                return max(0, min(1, (doneBase + fileFraction) / total))
            }
            SyncTaskCenter.shared.advance(id: item.id, done: index, total: files.count, note: "上传中…", currentFileFraction: 0)
            do {
                try await CosUploader.uploadHouseMedia(fileName: fileName, kind: kind,
                                                       roomKey: roomKey, config: config,
                                                       compress: shareCompressionEnabled,
                                                       onStage: { label in
                                                           progress.updateStage(roomKey: roomKey, direction: .upload, label: label)
                                                           Task { @MainActor in SyncTaskCenter.shared.advance(id: item.id, done: index, note: label) }
                                                       },
                                                       onTranscodeProgress: { fraction in
                                                           progress.updateTranscodeProgress(roomKey: roomKey, direction: .upload,
                                                                                            progress: globalFraction(fraction), fraction: fraction)
                                                           Task { @MainActor in
                                                               SyncTaskCenter.shared.advanceWithinFile(id: item.id, fileIndex: index, fraction: fraction)
                                                           }
                                                       },
                                                       onBytes: { fraction in
                                                           progress.update(roomKey: roomKey, direction: .upload,
                                                                            progress: globalFraction(fraction), label: "上传中…")
                                                           Task { @MainActor in
                                                               SyncTaskCenter.shared.advanceWithinFile(id: item.id, fileIndex: index, fraction: fraction)
                                                           }
                                                       },
                                                       onSpeed: { speed in
                                                           progress.updateSpeed(bytesPerSecond: speed)
                                                           Task { @MainActor in SyncTaskCenter.shared.updateSpeed(id: item.id, bytesPerSecond: speed) }
                                                       })
                HouseMediaUploadQueue.remove(roomKey: roomKey, fileName: fileName)
                SyncTaskCenter.shared.advance(id: item.id, done: index + 1, total: files.count, note: "已上传 \(index + 1)/\(files.count)", currentFileFraction: 1)
                progress.update(roomKey: roomKey, direction: .upload, progress: globalFraction(1), label: "已上传 \(index + 1)/\(files.count)")
            } catch {
                failures.append(fileName)
                SyncTaskCenter.shared.updateSpeed(id: item.id, bytesPerSecond: 0)
                progress.updateSpeed(bytesPerSecond: 0)
            }
        }
        if failures.isEmpty {
            // v2.57（P0-1/P1-7）：文件全传上后，按本地记录重写云端账本——当初保存时没敢写进账本
            // 的文件名（防止他端误剔除），现在桶里已有对象，补上引用文件才不算桶孤儿；清单一并 flush。
            var note = "已补传 \(files.count) 个媒体"
            var ledgerWritten = false
            if let ctx = houseContext {
                let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                if let house = all.first(where: { $0.mediaRoomKey == roomKey && !$0.isTrashed }) {
                    let record = CloudHouseSync.record(from: house, username: CloudUser.username)
                    do {
                        _ = try await CloudHouseSync.uploadGuarded(record: record, removedMedia: [], config: config)
                        SyncFailStore.clear(roomKey)
                        await CloudManifestUpdater.shared.flush()
                        LocalHouseLedger.save(house)
                        ledgerWritten = true
                        note += "，云端账本已补上这 \(files.count) 个"
                    } catch {
                        completion(.failure(message: "媒体已传上，但账本没写上（\(error.localizedDescription)）；再点一次重试即可"))
                        return
                    }
                }
            }
            // v2.60：重试成功只写一条最终日志，去掉原来的「上传媒体 成功」+「补传后补写账本 成功」两条。
            let action = retryLogAction(for: item)
            BackupLogStore.log(category: "房源", action: action, result: "成功",
                              detail: HouseMediaLogFormat.retryDetail(fileCount: files.count, ledgerWritten: ledgerWritten),
                              room: roomKey, cloud: true)
            completion(.success(note: note))
        } else {
            completion(.failure(message: "还有 \(failures.count) 个媒体没传上，可再点重试"))
        }
    }

    /// v2.60：重试成功后按任务回滚场景取动作名；新增房源固定为「新增房源」。
    private func retryLogAction(for item: TaskRecord) -> String {
        if let scene = item.rollback?.scene {
            switch scene {
            case .newHouse: return "新增房源"
            case .rename: return "房号迁移"
            case .plainEdit: return "修改房源"
            }
        }
        return item.title
    }

    /// 删云端媒体：本地已经删了，只补删云端对象（删不存在的对象是幂等，安全）
    private func retryMediaDelete(_ item: TaskRecord, completion: @escaping (TaskRetryOutcome) -> Void) async {
        guard let config = CosConfig.load(), config.isValid else {
            completion(.failure(message: "云端配置无效，请先到「云端配置」填写")); return
        }
        let files = item.files ?? []
        guard !files.isEmpty, let roomKey = item.roomKeys.first else {
            completion(.failure(message: "没有记录到具体文件名，请到这套房的编辑页再删一次")); return
        }
        var failures: [String] = []
        for fileName in files {
            let ext = (fileName as NSString).pathExtension.lowercased()
            let kind = ["mov", "mp4", "m4v", "avi"].contains(ext) ? "video" : "image"
            do {
                try await CosUploader.deleteRemoteMedia(fileName: fileName, kind: kind,
                                                       roomKey: roomKey, config: config)
            } catch {
                failures.append(fileName)
            }
        }
        if failures.isEmpty {
            completion(.success(note: "云端已删掉 \(files.count) 个媒体"))
        } else {
            completion(.failure(message: "还有 \(failures.count) 个媒体没删掉，可再点重试"))
        }
    }

    /// 提交房源改动（原草稿）：走原来的草稿提交逻辑，冲突时保留草稿并提示重新编辑
    private func retryHouseDraft(_ item: TaskRecord, completion: @escaping (TaskRetryOutcome) -> Void) async {
        guard let ctx = houseContext else {
            completion(.failure(message: "数据容器不可用，请重进 App 再试")); return
        }
        guard let roomKey = item.roomKeys.first,
              let draft = HouseDraftStore.shared.drafts.first(where: { $0.roomKey == roomKey }) else {
            completion(.success(note: "这条改动已经提交过了"))
            return
        }
        do {
            let msg = try await HouseDraftSubmitter.submit(draft: draft, ctx: ctx, force: false)
            completion(.success(note: msg))
        } catch let e as HouseDraftError {
            completion(.failure(message: e.errorDescription ?? "提交失败"))
        } catch {
            completion(.failure(message: error.localizedDescription))
        }
    }

    private func retryCloudDelete(_ item: TaskRecord, completion: @escaping (TaskRetryOutcome) -> Void) async {
        guard let config = CosConfig.load(), config.isValid else {
            completion(.failure(message: "云端配置无效，请先到「云端配置」填写")); return
        }
        var failures: [String] = []
        var localCleaned = 0
        for key in item.roomKeys {
            do {
                try await CloudBackupService.deleteHouseRemoteFolder(roomKey: key, config: config, writeLog: false)
                try await CloudHouseSync.delete(roomKey: key, config: config)
                // v2.57（P1-2）：云端删除是「先云后本」的把关步骤——云端删成功才清本地：
                // 数据库记录、媒体目录、状态标记、待传队列一并清掉，完成整条删除闭环
                // （含历史挂账：当年本地已删的房这里查不到对象，只清残留目录与标记，同样安全幂等）。
                if let ctx = houseContext {
                    let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                    if let h = all.first(where: { $0.mediaRoomKey == key }) {
                        MediaStore.deleteHouseDirectory(roomKey: key)
                        SyncFailStore.clear(key)
                        UnreadCloudHouseStore.clear(key)
                        ctx.delete(h)
                        try? ctx.save()
                        localCleaned += 1
                    } else {
                        MediaStore.deleteHouseDirectory(roomKey: key)
                        SyncFailStore.clear(key)
                        UnreadCloudHouseStore.clear(key)
                    }
                    HouseMediaUploadQueue.removeRoom(key)
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                }
            } catch {
                // v2.57（P3-18）：失败带完整原因（String(describing:) 含错误类型，不吃细节），标明删到哪一步失败
                failures.append("\(key)：\(String(describing: error))")
            }
        }
        if failures.isEmpty {
            completion(.success(note: "云端已删除 \(item.roomKeys.count) 套" + (localCleaned > 0 ? "，本地残留已清 \(localCleaned) 套" : "")))
        } else {
            completion(.failure(message: "这几套云端还没删掉（本地保留）：\(failures.joined(separator: "；"))"))
        }
    }

    private func retryPushUp(_ item: TaskRecord, completion: @escaping (TaskRetryOutcome) -> Void) async {
        guard let ctx = houseContext else {
            completion(.failure(message: "数据容器不可用，请重进 App 再试")); return
        }
        guard let config = CosConfig.load(), config.isValid else {
            completion(.failure(message: "云端配置无效，请先到「云端配置」填写")); return
        }
        let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        var byKey: [String: House] = [:]
        for h in local where !h.isTrashed { byKey[h.mediaRoomKey] = h }
        var failures: [String] = []
        for key in item.roomKeys {
            guard let house = byKey[key] else {
                SyncFailStore.clear(key)
                continue
            }
            let record = CloudHouseSync.record(from: house, username: CloudUser.username)
            LocalHouseLedger.save(house)
            do {
                _ = try await CloudHouseSync.uploadGuarded(record: record, config: config)
                SyncFailStore.clear(key)
                house.cloudStatus = .both
            } catch {
                failures.append(key)
            }
        }
        try? ctx.save()
        if failures.isEmpty {
            completion(.success(note: "已传到云端 \(item.roomKeys.count) 套"))
        } else {
            completion(.failure(message: "这几套没传上：\(failures.joined(separator: "、"))"))
        }
    }

    private func retryMedia(_ item: TaskRecord, completion: @escaping (TaskRetryOutcome) -> Void) async {
        guard let ctx = houseContext else {
            completion(.failure(message: "数据容器不可用，请重进 App 再试")); return
        }
        guard let config = CosConfig.load(), config.isValid else {
            completion(.failure(message: "云端配置无效，请先到「云端配置」填写")); return
        }
        let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        var byKey: [String: House] = [:]
        for h in local where !h.isTrashed { byKey[h.mediaRoomKey] = h }
        var failures: [String] = []
        for key in item.roomKeys {
            guard let house = byKey[key] else { continue }
            let files = house.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
            guard !files.isEmpty else { continue }
            let profile = CosUploader.loadShareProfile()
            let info = ShareHouseInfo(
                displayRoomNo: house.displayRoomNo, towerLabel: house.towerLabel,
                layout: house.layout, statusLabel: house.status.label, priceText: house.priceText,
                landlord: house.landlord, password: house.password, remark: house.remark,
                name: profile.name, phone: profile.phone)
            do {
                _ = try await CosUploader.autoRegenerateMaskedShare(
                    mediaFiles: files, roomKey: key, info: info, config: config)
                // 只把这条任务里的文件从待上传登记簿摘掉，别一把清空（同房其他文件可能还没传）
                for fileName in (item.files ?? files.map { $0.name }) {
                    HouseMediaUploadQueue.remove(roomKey: key, fileName: fileName)
                }
                // v2.57（P0-1/P1-7）：分享重传成功后同样补写账本引用（当初没敢写的名字现在补上），清单 flush
                let record = CloudHouseSync.record(from: house, username: CloudUser.username)
                do {
                    _ = try await CloudHouseSync.uploadGuarded(record: record, removedMedia: [], config: config)
                    SyncFailStore.clear(key)
                    await CloudManifestUpdater.shared.flush()
                    LocalHouseLedger.save(house)
                } catch {
                    // 账本补写失败不判整个任务失败（分享页已生成）；提示用户再点一次
                    failures.append("\(key)（媒体已传上，账本没写上）")
                }
            } catch {
                // v2.57（P3-18）：失败带完整原因，方便定位是网络、权限还是转码问题
                failures.append("\(key)：\(String(describing: error))")
            }
        }
        if failures.isEmpty {
            completion(.success(note: "媒体已全部传完"))
        } else {
            completion(.failure(message: "这几套媒体没传上：\(failures.joined(separator: "；"))"))
        }
    }
}

// MARK: - 房源页顶部任务条（没有任务时一个元素都不占；点条进中心）

struct TaskStrip: View {
    @ObservedObject var center = SyncTaskCenter.shared
    @State private var openCenter = false

    var body: some View {
        // v2.50：总刷新/整次同步不再在顶栏另起一条进度条（会和刷新按钮、悬浮胶囊一起出现三处转圈），
        // 只保留任务中心的真实任务条。
        Group {
            if center.hasAnything {
            Button {
                openCenter = true
            } label: {
                HStack(spacing: 8) {
                    if let first = center.running.first {
                        ProgressView().controlSize(.small)
                        Text(first.title).font(.footnote.weight(.semibold))
                        if first.total > 1 {
                            Text(first.percentText).font(.caption2).foregroundColor(.secondary)
                        }
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.footnote).foregroundColor(.orange)
                        Text("\(center.failed.count) 项待处理，点这里查看")
                            .font(.footnote.weight(.semibold))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $openCenter) {
                TaskCenterView()
            }
            }
        }
    }
}

// MARK: - 任务中心全页

struct TaskCenterView: View {
    @ObservedObject private var center = SyncTaskCenter.shared
    @Environment(\.houseModelContext) private var houseModelContext
    // v2.54：无回滚载荷的待处理任务点「删除」时，二次确认防误删
    @State private var purgeTarget: TaskRecord?

    var body: some View {
        NavigationStack {
            List {
                if !center.running.isEmpty {
                    Section("进行中") {
                        ForEach(center.running) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                TaskRowView(record: record)
                                // 撤回流程中的任务不再显示「取消上传」，避免重复操作
                                if record.kind == .media && record.isHouseUpload == true
                                    && record.note != "正在撤回…" {
                                    Button(role: .destructive) {
                                        center.requestCancel(id: record.id)
                                    } label: {
                                        Label("取消上传", systemImage: "xmark.circle")
                                            .font(.footnote.weight(.medium))
                                    }
                                }
                            }
                        }
                    }
                }
                if !center.failed.isEmpty {
                    Section {
                        ForEach(center.failed) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                TaskRowView(record: record)
                                // v2.56：主操作「重试」+ 一个「更多」菜单——放弃类操作收进菜单，
                                // 不再三个按钮挤在一起；每个动作写清后果，破坏性操作二次确认，purge 保证任务一定删得掉
                                HStack(spacing: 10) {
                                    Button {
                                        center.retry(id: record.id)
                                    } label: {
                                        Label("重试", systemImage: "arrow.clockwise")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(Color.themeAccent.opacity(0.12))
                                            .foregroundColor(.themeAccent)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    Menu {
                                        if record.rollback != nil {
                                            Button(role: .destructive) {
                                                center.revoke(id: record.id, houseContext: houseModelContext)
                                            } label: {
                                                Label("撤回本次改动（本地+云端恢复）", systemImage: "arrow.uturn.backward")
                                            }
                                        }
                                        Button(role: .destructive) {
                                            purgeTarget = record
                                        } label: {
                                            Label("仅删除任务记录（保留文件和云端）", systemImage: "trash")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .font(.title3)
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 12)
                                            .background(Color.gray.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("待处理（只能手动重试，不会自动跑）")
                    }
                }
                if !center.done.isEmpty {
                    Section {
                        ForEach(center.done) { TaskRowView(record: $0) }
                    } header: {
                        HStack {
                            Text("最近完成")
                            Spacer()
                            Button("清空") { center.clearDone() }
                                .font(.caption)
                        }
                    }
                }
                if !center.hasAnything && center.done.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 38)).foregroundColor(.green)
                            Text("没有任务").font(.headline)
                            Text("同步失败或中断的任务会留在这里，不会悄悄丢掉")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
            }
            .navigationTitle("同步任务中心")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("删除这条任务？",
                                isPresented: Binding(
                                    get: { purgeTarget != nil },
                                    set: { if !$0 { purgeTarget = nil } }
                                ),
                                presenting: purgeTarget) { target in
                Button("删除", role: .destructive) {
                    center.purge(id: target.id)
                    purgeTarget = nil
                }
                Button("取消", role: .cancel) { purgeTarget = nil }
            } message: { _ in
                Text("仅删除这条任务记录，不会删除本地文件或云端数据。")
            }
        }
    }
}

/// 统一行组件（顶部条 / 中心 / 其他页面复用同一个）
struct TaskRowView: View {
    let record: TaskRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: record.kind.iconName)
                    .font(.subheadline)
                    .foregroundColor(record.state == .failed ? .orange : .themeAccent)
                Text(record.title).font(.subheadline.weight(.semibold))
                Spacer()
                switch record.state {
                case .running: Text(record.percentWithSpeedText).font(.caption2).foregroundColor(.secondary)
                case .failed: Text("待处理").font(.caption2).foregroundColor(.orange)
                case .finished: Text("已完成").font(.caption2).foregroundColor(.green)
                case .cancelled: Text("已取消").font(.caption2).foregroundColor(.secondary)
                }
            }
            if record.state == .running {
                ProgressView(value: record.fraction)
                if !record.note.isEmpty {
                    Text(record.note).font(.caption2).foregroundColor(.secondary)
                }
            } else if record.state == .failed {
                Text(record.failure).font(.caption2).foregroundColor(.secondary)
            } else if record.state == .cancelled {
                Text(record.failure).font(.caption2).foregroundColor(.secondary)
            } else if !record.note.isEmpty {
                Text(record.note).font(.caption2).foregroundColor(.secondary)
            }
            if !record.roomKeys.isEmpty {
                Text(record.roomKeys.prefix(8).joined(separator: "、"))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
