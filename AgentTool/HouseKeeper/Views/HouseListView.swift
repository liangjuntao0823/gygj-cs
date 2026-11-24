import SwiftUI
import AVFoundation
import SwiftData

/// b106：房源排序三档——默认（座号/楼层/房号）/ 价格升序 / 更新时间降序
enum HouseSortMode: String, CaseIterable {
    case `default` = "默认排序"
    case priceAsc = "价格升序"
    case updatedDesc = "更新时间"
    var label: String { rawValue }
}

/// v2.9（P1-1）：轻量变更感知三态结果
enum CloudChangeState: Equatable {
    case noChange        // 两端一致，无变化
    case hasUpdate       // 云端有更新，提示用户下拉同步
    case detectFailed    // 检测失败（断网/超时/未配置云），不再静默
}

/// v2.63（b121 回归）：自动云端变更检测的全局指示状态。
/// 冷启动 / 回前台 / 进板块 30 分钟兜底三条路径最终都走 detectCloudLedgerChange，
/// 在这里统一「点亮 → 至少展示 0.6 秒 → 熄灭」，让用户能看到「正在检测云端变更…」，
/// 不再出现「无变化时一点反馈都没有」的静默感知。
/// 约定：本类所有方法只从主线程调用（异步入口用 MainActor.run 包一层）。
final class CloudDetectActivity: ObservableObject {
    static let shared = CloudDetectActivity()

    /// 自动检测进行中（房源页顶部胶囊进度条据此显示）
    @Published private(set) var isDetecting = false
    /// 手动云端同步进行中——自动检测直接跳过，避免两边同时拉清单、结论互相打架
    @Published private(set) var isManualSyncing = false

    private var detectDepth = 0
    private var manualDepth = 0
    private var startedAt: Date?

    func beginDetecting() {
        detectDepth += 1
        if startedAt == nil { startedAt = Date() }
        isDetecting = true
    }

    /// 至少展示 minimumVisible 秒（沿用 b121 的 0.6 秒口径），避免检测太快、一闪而过感知不到。
    /// 计数归零后才真正收尾；期间又来了新检测则继续显示。
    func endDetecting(minimumVisible: TimeInterval = 0.6) {
        detectDepth = max(0, detectDepth - 1)
        guard detectDepth == 0 else { return }
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        let delay = max(0, minimumVisible - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.detectDepth == 0 else { return }
            self.isDetecting = false
            self.startedAt = nil
        }
    }

    func beginManualSync() {
        manualDepth += 1
        isManualSyncing = true
    }

    func endManualSync() {
        manualDepth = max(0, manualDepth - 1)
        if manualDepth == 0 { isManualSyncing = false }
    }
}

struct HouseListView: View {
    /// 房源板块使用独立 HouseStore 容器的专属 context（由 App 注入）。
    /// 不能用主容器的 modelContext——iOS 17 早期版本多配置容器上查询会崩溃（闪退根因）。
    @Environment(\.houseModelContext) private var houseModelContext
    @State private var houses: [House] = []

    static let houseStoreChanged = Notification.Name("houseStoreChanged")
    /// b118（清单12）：打开 App 轻量变更感知——启动/回前台探测云端账本有变化时广播
    static let cloudLedgerChangedLight = Notification.Name("cloudLedgerChangedLight")

    /// v1.67：后台线程安全的媒体对账快照——SwiftData @Model 属性（mediaItems 等）只能在
    /// 主线程/模型上下文访问，跨线程读会崩溃（v1.66 刷新「点击没反应」根因）。
    /// 因此先在主线程把需要的数据提取成纯值，后台只做网络请求。
    private struct PendingMediaHouseSnapshot {
        let roomKey: String
        let displayRoomNo: String
        let files: [ShareMediaFile]
        let info: ShareHouseInfo
    }

    @State private var searchText = ""
    /// v2.18：房源顶栏「操作日志」入口（批量导入旁边），不用再进设置页才能看日志
    @State private var showLogs = false
    /// v2.16：订阅卡片进度条——正在上传/同步的那套临时置顶，让高楼层的房源不用下滑才看到进度
    @ObservedObject private var syncProgress = HouseSyncProgress.shared
    // v2.41：快捷指令深链 → 唤起新增房源并自动解析剪贴板
    @ObservedObject private var houseImportIntent = HouseImportIntent.shared
    @State private var autoImportNext = false
    @State private var handledImportTick = 0
    @State private var towerFilter: Int? = nil      // nil = 全部
    @State private var statusFilter: HouseStatus? = .available   // 首页默认显示待租房源
    @State private var layoutFilters: Set<String> = []   // v1.3：户型筛选支持多选，空 = 全部户型
    @State private var showOnlyNoMedia = false   // v2.7（P2⑮）：只看无媒体房源
    @State private var showAdd = false
    @State private var showBatchImport = false   // v1.58：批量录入（清单/zip/扫描）
    // b106：房源排序（默认=现有逻辑 / 价格低→高 / 更新时间降序）
    @State private var houseSortMode: HouseSortMode = .default
    // b106：向下滚动自动折叠卡片以上区域（统计/搜索/筛选），向上滚动自动展开
    @State private var headerCollapsed = false

    // 卡片左滑菜单（编辑 / 已租 / 删除）
    @State private var showEditHouse: House?
    @State private var singleShareHouse: House?
    @State private var deleteTarget: House?
    @State private var showDetailHouse: House?

    // v1.14 需求6：合并所有 confirmationDialog 为单一枚举弹窗（iOS 17 同一视图多个 confirmationDialog 会互相覆盖，
    // 导致删除确认弹窗不显示）；按触发源分发文案与按钮
    // v1.16 需求2：删除确认彻底改回 DealsView 同款独立 alert（swipeActions 手势会拦截 confirmationDialog 按钮点击；
    // 且 presenting 变体 + 自定义 Binding 在 iOS 17 swipeActions 环境不可靠）——拆分：
    //   - showDeleteConfirm + deleteTarget/isBatchDelete：删除确认（挂 body 链最末，最后挂载优先响应）
    //   - showShareModeAlert + activeDialog：分享方式选择（普通按钮触发，非 swipeActions）
    //   - showInfoAlert + infoMessage：分享错误 / 批量结果提示
    @State private var showDeleteConfirm = false
    @State private var isBatchDelete = false
    @State private var deleteRunning = false
    @State private var deleteDone = 0
    @State private var deleteTotal = 0
    @State private var deleteCurrentRoom = ""
    /// v2.24：只看无媒体 = 沙盒 media/<房号>/ 目录里实际没有媒体文件（与卡片「无实拍图」同口径）
    @State private var noMediaKeys: Set<String> = []
    @State private var showShareModeAlert = false
    @State private var showInfoAlert = false
    @State private var infoMessage = ""
    // v1.73（#1 重做）：原生悬浮结果提示——顶部胶囊横幅，自动消失，替代「占半个屏幕」的居中大弹窗
    @State private var infoToast: String?
    @State private var infoToastIsError = false
    // v1.40 第11点：同步先弹变化确认（预览 → 确认 → 应用）
    @State private var showSyncConfirm = false
    // v1.72（#1/#5）：刷新/同步进行中状态——点刷新立即反馈「正在刷新…」，比对完成才收起
    @State private var isSyncing = false
    /// v2.63：自动检测指示状态（冷启动 / 回前台 / 进板块兜底三条路径共用同一个全局状态）
    @StateObject private var detectActivity = CloudDetectActivity.shared
    /// v2.65：长按触发的深度核对与普通刷新分开提示（否则长按后只显示「正在刷新…」，看不出走的是哪条路）
    @State private var isDeepSyncing = false
    /// v2.50：云端有更新 → 顶栏常驻横幅，只有手动点 ✕ 才收起（此前 toast 不到 1 秒就消失，容易错过）
    @State private var cloudUpdateBannerVisible = false
    // v1.68：云端媒体对账确认（先干跑列桶 → 弹确认 → 确认后才上传）+ 同步任务进度/最小化
    @State private var showMediaSyncConfirm = false
    @State private var pendingMediaSnaps: [PendingMediaHouseSnapshot] = []
    @ObservedObject private var syncCenter = SyncTaskCenter.shared
    @State private var pendingSyncRecs: [CloudHouseRecord] = []
    // v2.62（B1）：本次同步的云端权威房号集合（来自目录列举），执行侧判断「云端是否有这套」只用它
    @State private var pendingSyncCloudKeys: Set<String> = []
    @State private var pendingSyncAdded: [(roomNo: String, roomKey: String, mediaNames: [String])] = []
    @State private var pendingSyncUpdated: [(roomNo: String, byUser: String)] = []
    @State private var pendingSyncDeleted: [(roomKey: String, roomNo: String)] = []   // v1.42：带房号
    @State private var pendingSyncPushed: [(roomKey: String, roomNo: String)] = []     // v1.42：带房号
    @State private var pendingSyncMediaDiff: [(roomNo: String, missing: Bool)] = []    // v1.43：媒体差异房号（含「本地缺文件需从云端补回」）
    // v2.58（#3）：任务中心 cloudPull 重试发起的这次同步——确认框弹出后要等用户决定，
    // 点「确认同步」执行完 / 点「取消」才结算任务，不能提前报成功
    @State private var pendingSyncRetryTaskID: UUID?
    // v2.58（#3）：媒体补齐确认同样可能由 cloudPull 重试触发——确认/取消后结算原任务
    @State private var pendingMediaSyncRetryTaskID: UUID?
    @State private var activeDialog: HouseListDialog?

    // v1.22：首页多选分享——一次选多套，生成【一个合集分享卡片】（好友点开链接即可查看全部 N 套），
    // 不再逐套生成链接逐次弹微信，避免 App 与微信来回跳转
    @State private var isSelecting = false
    @State private var selectedHouseIDs = Set<UUID>()
    // v2.17：队列元素从「卡片链接」扩展为任意分享素材（卡片 = [URL]，只分享视频 = [AVAsset]）
    @State private var shareQueue: [[Any]] = []
    /// v2.29：分享面板回到 SwiftUI sheet 呈现（与 2.17 一致，实测 2.17 视频分享可用）
    @State private var currentShareStep: ShareStep? = nil
    // v2.17：多选逐套分享时，一套发完询问「继续下一套 / 结束」
    @State private var showContinueShare = false
    // v2.17：保存类操作的轻提示（与工作台/成交板块一致的底部小胶囊，不弹遮罩、不占屏）
    @State private var saveToast: String?
    @State private var remainingShareCount = 0
    @State private var shareIndex = 0
    @State private var isGenerating = false
    @State private var generateTip = ""
    @State private var generateProgress = 0.0   // v1.13 需求13：上传百分比进度
        // v1.12：多选模式批量操作——批量已租 / 批量删除（保留原有多选分享逻辑不动）
    
    /// v1.15 需求2：单一弹窗枚举（iOS 17 同一视图多个 confirmationDialog/alert 会互相覆盖、且 swipeActions
    /// 手势会拦截 confirmationDialog 按钮点击，删除确认因此无反应）——统一改用单一 alert 呈现所有确认/提示
    /// v1.16 需求2：枚举仅保留「分享方式选择」两类（multiShare/singleShare）；删除/批量删除走独立 showDeleteConfirm
    enum HouseListDialog: Identifiable {
        case multiShare
        case singleShare
        var id: String {
            switch self {
            case .multiShare: return "multiShare"
            case .singleShare: return "singleShare"
            }
        }
    }

    /// 筛选后的房源：默认待租，并按「座号 + 楼层 + 房号」升序排列（1座在前，同座先按楼层、再按房号从小到大）
    /// v1.29（优化评估）：搜索/筛选在内存中进行。房源规模通常为个位数~几十套，
    /// 全量 @Query + 内存过滤即最优解；若未来房源破百再考虑把过滤下推到 SQLite（动态 @Query predicate）。
    private var filteredHouses: [House] {
        let base = houses
            .filter { house in
                let matchSearch: Bool = {
                    guard !searchText.isEmpty else { return true }
                    let keyword = searchText.lowercased()
                    return house.roomNo.lowercased().contains(keyword)
                        || house.displayRoomNo.lowercased().contains(keyword)
                        || house.landlord.lowercased().contains(keyword)
                        || house.layout.lowercased().contains(keyword)
                        || house.remark.lowercased().contains(keyword)
                }()
                let matchTower = towerFilter == nil || house.tower == towerFilter
                let matchStatus = statusFilter == nil || house.status == statusFilter
                let matchLayout = layoutFilters.isEmpty || layoutFilters.contains(house.layout)
                // v2.24：无媒体筛选以「沙盒目录里实际有没有文件」为准（此前判 mediaItems，与卡片口径打架）
                let matchNoMedia = !showOnlyNoMedia || noMediaKeys.contains(house.mediaRoomKey)
                return matchSearch && matchTower && matchStatus && matchLayout && matchNoMedia
            }
            .sorted { a, b in
                // b106：排序三档——默认（现有逻辑）/ 价格升序 / 更新时间降序
                switch houseSortMode {
                case .priceAsc:
                    // v2.24：未填租金（0 元）排最后，不再霸占榜首
                    let ap = a.price > 0 ? a.price : Int.max
                    let bp = b.price > 0 ? b.price : Int.max
                    if ap != bp { return ap < bp }
                case .updatedDesc:
                    let at = a.lastUpdatedAt ?? a.updatedAt
                    let bt = b.lastUpdatedAt ?? b.updatedAt
                    if at != bt { return at > bt }
                case .default:
                    break
                }
                if a.tower != b.tower { return a.tower < b.tower }
                if a.floorNumber != b.floorNumber { return a.floorNumber < b.floorNumber }
                if a.roomNumber != b.roomNumber { return a.roomNumber < b.roomNumber }
                // 同座同层同号（如 1420上 / 1420下）：按原始房号字符串稳定排序
                return a.roomNo < b.roomNo
            }

        // v2.16：正在上传/云端同步的那套临时置顶（高楼层的房源不用下滑去找进度条）；
        // 进度清空（HouseSyncProgress.end 后 roomKey 变 nil）自动回落到原排序，不改变任何排序规则
        guard let activeKey = syncProgress.roomKey, !activeKey.isEmpty,
              let activeIndex = base.firstIndex(where: { $0.mediaRoomKey == activeKey }) else {
            return base
        }
        var list = base
        let activeHouse = list.remove(at: activeIndex)
        list.insert(activeHouse, at: 0)
        return list
    }

    // v2.7（P2⑬ 户型筛选联动）：基于「已按座号+状态+搜索+无媒体过滤后」的结果取户型去重，
    // 不含 layoutFilters 本身——避免选了某户型后该选项消失。
    // 例：点了「未租」+「1座」，户型筛选只列出 1座未租 房源里实际存在的户型；
    // 已租才有而未租没有的户型不展示。座号/状态/搜索/无媒体组合筛选同理。
    private var layouts: [String] {
        let base = houses.filter { h in
            let matchSearch = searchText.isEmpty || h.displayRoomNo.localizedCaseInsensitiveContains(searchText)
            let matchTower = towerFilter == nil || h.tower == towerFilter
            let matchStatus = statusFilter == nil || h.status == statusFilter
            let matchNoMedia = !showOnlyNoMedia || noMediaKeys.contains(h.mediaRoomKey)
            return matchSearch && matchTower && matchStatus && matchNoMedia
        }
        return Array(Set(base.compactMap { $0.layout.isEmpty ? nil : $0.layout })).sorted()
    }

    /// v1.16 需求2：分享方式选择弹窗标题（activeDialog 仅用于分享选择）
    private var dialogTitle: String {
        switch activeDialog {
        case .multiShare: return "选择分享方式"
        case .singleShare: return "选择分享方式"
        case nil: return ""
        }
    }

    private var tower1Count: Int { houses.filter { $0.tower == 1 }.count }
    private var tower2Count: Int { houses.filter { $0.tower == 2 }.count }
    private var availableCount: Int { houses.filter { $0.status == .available }.count }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    TaskStrip()
                    cloudUpdateBanner
                    announcementBanner
                    collapsibleHeader
                    houseList
                }
            }
            .navigationTitle("房源管理")
            .navigationBarTitleDisplayMode(.inline)
            // v1.72（#1/#5）：同步/刷新进行中——顶部横幅立即反馈「正在刷新…」（比对完成自动收起）
            // v1.73（#1 重做）：刷新/同步结果改为原生悬浮横幅（自动消失），不再弹占半个屏幕的居中提示框
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    if isSyncing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(isDeepSyncing ? "正在深度核对…" : "正在刷新…")
                                .font(.footnote.weight(.medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else if detectActivity.isDetecting {
                        // v2.63（b121 回归）：自动检测期间的细进度条提示；
                        // 手动刷新/同步优先（isSyncing 为真时上面那条占了位置），两者不会叠在一起。
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在检测云端变更…")
                                .font(.footnote.weight(.medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let toast = infoToast {
                        HStack(spacing: 6) {
                            Image(systemName: infoToastIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundColor(infoToastIsError ? .red : .green)
                            Text(toast)
                                .font(.footnote.weight(.medium))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 6)
            }
            .toolbar {
                // v1.59：左上角 = 手动同步 + 多选入口（多选从右上角移到刷新旁边）
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        // v1.19：左上角手动同步（与下拉刷新同效果——拉取云端房源）
                        Button {
                            Task { await syncCloudHouses() }
                        } label: {
                            if isSyncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        // v2.62（B5）：长按 = 深度刷新——忽略清单摘要与 24h 缓存，逐套全量核对。
                        // 日常点按走增量（1~3 秒）；怀疑漏更新时用长按强制全量。
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                                Task { await syncCloudHouses(deep: true) }
                            }
                        )
                        // v2.63：同步进行中禁用按钮（点按与长按都生效），配合入口重入保护，连点不会再开第二份任务
                        .disabled(isSyncing)
                        // v1.21：多选分享入口（v1.59 移到左上角）
                        Button {
                            isSelecting = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                    .disabled(isSelecting)
                }
                // v1.7：房源设置已合并进主 App 设置页，左上角设置按钮移除（无独立设置入口）
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("取消") { exitMultiSelect() }
                    } else {
                        HStack(spacing: 14) {
                            // v2.18：操作日志入口（批量导入旁边；原来只能进设置页才能看日志）
                            Button {
                                showLogs = true
                            } label: {
                                Image(systemName: "list.bullet.rectangle")
                            }
                            // v1.58：批量录入入口（清单导入 / 媒体包导入 / 扫描补录）
                            Button {
                                showBatchImport = true
                            } label: {
                                Image(systemName: "square.and.arrow.down.on.square")
                            }
                            // v1.7：+ 按钮样式与其他板块一致（plus.circle.fill + 主题绿）
                            Button {
                                showAdd = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.themeAccent)
                            }
                        }
                    }
                }
            }
            // v2.29：分享面板走 sheet（与 2.17 可用版本一致）；面板关闭后再问「继续/结束」
            .sheet(item: $currentShareStep, onDismiss: {
                if !shareQueue.isEmpty, shareIndex < shareQueue.count - 1 {
                    remainingShareCount = shareQueue.count - shareIndex - 1
                    showContinueShare = true
                } else if !shareQueue.isEmpty {
                    exitMultiSelect()
                }
            }) { step in
                HouseShareSheet(items: step.items)
            }
            .sheet(isPresented: $showAdd, onDismiss: {
                autoImportNext = false
            }) {
                HouseEditView(house: nil, autoImportClipboard: autoImportNext)
            }
            // v2.41：深链到达时切到本 tab 后唤起新增房源；冷启动（本视图尚未创建）由下面 onAppear 兜底
            .onChange(of: houseImportIntent.tick) { _, newValue in
                guard newValue != handledImportTick else { return }
                handledImportTick = newValue
                autoImportNext = true
                showAdd = true
            }
            .onAppear {
                if houseImportIntent.tick != handledImportTick {
                    handledImportTick = houseImportIntent.tick
                    autoImportNext = true
                    showAdd = true
                }
            }
            .sheet(isPresented: $showBatchImport) {
                HouseBatchImportView()
            }
            // v2.18：顶栏操作日志（本机区 + 云端区，与设置页同一个查看器）
            .sheet(isPresented: $showLogs) {
                BackupLogsView()
            }
            .sheet(item: $showEditHouse) { house in
                HouseEditView(house: house)
            }
            .navigationDestination(item: $showDetailHouse) { house in
                HouseDetailView(house: house)
            }
            // v1.16 需求2：分享方式选择（普通按钮触发，非 swipeActions；用真 @State 绑定避免 iOS 17 自定义 Binding 不可靠问题）
            .alert(dialogTitle, isPresented: $showShareModeAlert) {
                switch activeDialog {
                case .multiShare:
                    Button("发给客户（隐藏版）") { generateShareQueue(mode: .masked) }
                    Button("发给同事（完整版）") { generateShareQueue(mode: .full) }
                    // v2.17：只分享视频——不走云端卡片，直接按视频消息发（每套一次，微信收到即可播放）
                    Button("只分享视频（\(selectedHouseIDs.count) 套）") { generateVideoOnlyShare() }
                    Button("取消", role: .cancel) {}
                case .singleShare:
                    Button("发给客户（隐藏版）") { generateSingleShare(mode: .masked) }
                    Button("发给同事（完整版）") { generateSingleShare(mode: .full) }
                    // v2.17：只分享视频——不生成卡片，直接按视频消息发
                    Button("只分享视频") { generateSingleVideoShare() }
                    Button("取消", role: .cancel) {}
                case nil:
                    EmptyView()
                }
            } message: {
                switch activeDialog {
                case .multiShare:
                    Text("已选 \(selectedHouseIDs.count) 套，将生成一个合集分享卡片：好友点开链接即可查看全部房源，每套单独一页（含实拍图/视频）。隐藏版不显示房号/价格/房东，完整版显示全部信息。")
                case .singleShare:
                    Text("隐藏版只显示户型、位置和您的联系方式；完整版额外显示房号、价格、房东和密码。")
                case nil:
                    Text("")
                }
            }
            // v2.17：多选逐套分享——继续 / 结束
            .alert("还有 \(remainingShareCount) 套没发", isPresented: $showContinueShare) {
                Button("继续发送下一套") {
                    if shareIndex < shareQueue.count - 1 {
                        shareIndex += 1
                        presentShareStep(shareQueue[shareIndex])
                    }
                }
                Button("结束分享", role: .cancel) { exitMultiSelect() }
            } message: {
                Text("发完在微信里不会自动跳回来。切回公寓管家后点「继续发送下一套」接着发；不想发了点「结束分享」。")
            }
            // v1.16 需求2：分享错误 / 批量结果提示（单行文本，独立 alert）
            // v1.71（#95）：提示改由 MainTabView 的 GlobalAlertOverlay 全局呈现——
            // 此前挂在房源页，离开房源板块后「好」按钮被禁用变灰只能重启；现在任何页面都能点。
            .onChange(of: showInfoAlert) { _, shown in
                if shown {
                    let msg = infoMessage
                    showInfoAlert = false   // 本地状态立即复位（全局已接管呈现）
                    GlobalAlertCenter.shared.show(msg)
                }
            }
            // v1.40 第11点：同步变化确认——先展示变化详情，确认后才应用
            .alert("发现云端变化", isPresented: $showSyncConfirm) {
                Button("确认同步", role: .destructive) {
                    // v2.58（#3）：把重试任务 id 带进执行体，执行完按真实结果显示成功/失败
                    let retryTaskID = pendingSyncRetryTaskID
                    pendingSyncRetryTaskID = nil
                    Task { await applySyncPreview(retryTaskID: retryTaskID) }
                }
                Button("取消", role: .cancel) {
                    // v2.58（#3）：用户主动取消，不写失败记录，直接收掉这次重试任务
                    if let retryTaskID = pendingSyncRetryTaskID {
                        syncCenter.discard(id: retryTaskID)
                        pendingSyncRetryTaskID = nil
                    }
                }
            } message: {
                Text(syncChangeSummary())
            }
            // v1.68：云端媒体对账确认——干跑列桶后发现云端缺媒体，确认后才开始上传（不再静默后台跑）
            .alert("确认补齐云端媒体", isPresented: $showMediaSyncConfirm) {
                Button("开始补齐", role: .destructive) {
                    // v2.58（#3）：补齐完成后按真实结果结算 cloudPull 重试任务
                    let retryTaskID = pendingMediaSyncRetryTaskID
                    pendingMediaSyncRetryTaskID = nil
                    let snaps = pendingMediaSnaps
                    pendingMediaSnaps = []
                    Task { await runMediaUpload(snaps: snaps, config: CosConfig.load(), ctx: houseModelContext, cloudPullTaskID: retryTaskID) }
                }
                Button("取消", role: .cancel) {
                    pendingMediaSnaps = []
                    if let retryTaskID = pendingMediaSyncRetryTaskID {
                        syncCenter.discard(id: retryTaskID)
                        pendingMediaSyncRetryTaskID = nil
                    }
                }
            } message: {
                Text(mediaSyncConfirmSummary())
            }
            // v2.26：分享面板改为 SharePresenter 直呈，不再挂 sheet（sheet 里第二次弹微信点不动）
            .overlay {
                if isGenerating {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView(value: generateProgress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                            Text(generateTip)
                                .font(.footnote)
                                .foregroundColor(.white)
                            Text("\(Int(generateProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .padding(20)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            // v1.16 需求2：删除确认——复刻 DealsView 已验证可用的模式：独立 alert + 真 @State Bool 绑定，
            // 挂在本链最末（最后挂载优先响应），避免 iOS 17 swipeActions 手势拦截 confirmationDialog / 自定义 Binding 失效的问题
            // v1.36 需求1：删除改为彻底删除（不再进回收站）
            .alert(isBatchDelete ? "删除选中的 \(selectedHouseIDs.count) 套房源" : "删除这套房源", isPresented: $showDeleteConfirm) {
                Button("仅删除本地（云端保留）") { startDelete(both: false) }
                Button("删除双端（推荐）", role: .destructive) { startDelete(both: true) }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteConfirmMessage)
            }
        }
        .onAppear {
            reloadHouses()
            // v2.58（#3）：整次云端同步的重试入口——页面必须回报真实结果（成功/失败/等确认）
            TaskRetryPerformer.shared.cloudPull = { retryTaskID in
                await syncCloudHouses(retryTaskID: retryTaskID)
            }
            // v2.62（A3）：进板块不再每次检测——从详情页返回、从编辑页返回、切 tab 回来都不再触发，
            // 只消费「App 启动 / 回前台」写下的 pending 标记；没有标记就不发请求。
            let pending = UserDefaults.standard.bool(forKey: "cloudLedgerPendingHint")
            UserDefaults.standard.set(false, forKey: "cloudLedgerPendingHint")
            if pending { showCloudChangeHint() }
            // v2.62（A5）：静默兜底——距上次检测超过 30 分钟、且当前没有上传任务时，才轻量检测一次；
            // 失败不弹提示（避免刚进页面就打扰），只有真有更新才挂横幅。
            Task {
                let hasRunningUpload = await MainActor.run(body: { Self.hasRunningHouseUpload() })
                guard !hasRunningUpload else { return }
                let now = Date().timeIntervalSince1970
                let lastAt = UserDefaults.standard.double(forKey: "cloudDetectLastAt")
                guard now - lastAt >= 1800 else { return }
                let changeState = await Self.detectCloudLedgerChange(houseContext: houseModelContext)
                if changeState == .hasUpdate { showCloudChangeHint() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.houseStoreChanged)) { _ in
            reloadHouses()
        }
        // b118（清单12：打开 App 轻量变更感知）：App 启动/回前台探测到云端账本有变化 →
        // 顶部横幅轻提示「云端有更新」，用户下拉刷新即同步（不自动拉取，省流量、不打断当前操作）
        // b119（清单1 重做）：文案改为「检测到云端有更新，请同步」；本页收到通知直接提示
        // b120：通知到达也走统一提示入口（showCloudChangeHint 防抖），并消费 pendingHint
        .onReceive(NotificationCenter.default.publisher(for: Self.cloudLedgerChangedLight)) { _ in
            UserDefaults.standard.set(false, forKey: "cloudLedgerPendingHint")
            showCloudChangeHint()
        }
    }

    /// b120（清单1）：统一「云端有更新」横幅提示入口——5 秒防抖，避免启动/回前台通知
    /// 与 onAppear 实时检测并发时重复提示；有变化才提示、无变化静默。
    private func showCloudChangeHint() {
        // v2.50：不再用 1 秒就消失的 toast——有变化就常驻顶栏横幅，用户手动关或同步成功后自动收起
        if !cloudUpdateBannerVisible {
            withAnimation(.easeInOut(duration: 0.18)) { cloudUpdateBannerVisible = true }
        }
    }

    /// v2.9（P1-1）：检测失败提示（断网/超时/未配置云），与「无变化」区分，不再静默吞错。
    private func showCloudDetectFailedHint() {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: "cloudLedgerHintShownAt")
        if now - last < 5 { return }
        UserDefaults.standard.set(now, forKey: "cloudLedgerHintShownAt")
        showToast("云端检测失败：请检查网络或云配置后重试")
    }

    /// v2.37（#15/#34）：变更感知改为「只拉 1 个总清单」做增量比对，请求数从约 128 降到 1。
    /// - 本地还没有任何修订号基线（首次安装/刚升级），或云端总清单缺失：退回一次全量精确比对（fetchAll），
    ///   顺手重建总清单、建立基线；之后就只拉总清单。
    /// - 有基线：拉总清单，按「修订号是否变化 + 房号/座号/媒体数摘要」判断；本地有、清单没有或反之也算差异。
    /// - 加 45 秒节流：短时间内反复进入页面直接复用上次结果，不重复发请求。
    /// 探测失败（断网/超时/未配置云）→ .detectFailed，与「无变化」严格区分。
    static func detectCloudLedgerChange(houseContext: ModelContext?) async -> CloudChangeState {
        guard let config = CosConfig.load(), config.isValid else { return .detectFailed }
        guard let ctx = houseContext else { return .detectFailed }

        // v2.62（A2）：有房源上传任务正在跑时，整次检测直接跳过——不上传途中弹「云端有更新」，
        // 也不写缓存（避免把这一刻的错误结论留到 45 秒后继续复用）。
        if await MainActor.run(body: { Self.hasRunningHouseUpload() }) {
            return .noChange
        }

        // v2.63：手动云端同步（左上角刷新/长按深度刷新）进行中时直接跳过检测——
        // 两边都要拉云端清单，并发会重复请求，检测基于同步中途的中间态也不可信。
        // 下拉刷新是纯本地媒体对账、不联网，不在此列，只靠 UI 让位（手动优先）。
        if await MainActor.run(body: { CloudDetectActivity.shared.isManualSyncing }) {
            return .noChange
        }

        // v2.63（b121 回归）：从这里开始算「正在检测」——房源页顶部显示细进度条 +「正在检测云端变更…」；
        // 无论正常结束、无变化、失败还是提前返回，都由 defer 统一熄灭，且至少展示 0.6 秒。
        await MainActor.run { CloudDetectActivity.shared.beginDetecting() }
        defer { DispatchQueue.main.async { CloudDetectActivity.shared.endDetecting() } }

        // 45 秒节流：只复用「无变化」（v2.62：hasUpdate 不再复用，避免旧结论反复弹横幅）
        let now = Date().timeIntervalSince1970
        let lastAt = UserDefaults.standard.double(forKey: "cloudDetectLastAt")
        if now - lastAt < 45,
           let cached = UserDefaults.standard.string(forKey: "cloudDetectLastState"),
           let state = cloudChangeState(fromRaw: cached),
           state == .noChange {
            return state
        }

        // v2.62（A1）：本机正在上传/待重试的房号，不参与「本地 vs 云端」差异判定
        let activeKeys = await MainActor.run(body: { Self.activeUploadRoomKeys() })

        let state: CloudChangeState
        // 没有任何基线（首次）→ 全量精确比对并建立基线
        if CloudRevisionStore.all().isEmpty {
            state = await compareWithFullFetch(config: config, ctx: ctx, activeKeys: activeKeys)
        } else {
            do {
                if let manifest = try await CloudHouseSync.fetchManifest(config: config) {
                    // v2.54：compareManifest 改为 async 精确口径（revision 不再一票否决）
                    state = await compareManifest(manifest, config: config, ctx: ctx, activeKeys: activeKeys)
                } else {
                    // 云端总清单缺失：全量重建 + 精确比对
                    state = await compareWithFullFetch(config: config, ctx: ctx, activeKeys: activeKeys)
                }
            } catch {
                state = .detectFailed
            }
        }
        UserDefaults.standard.set(now, forKey: "cloudDetectLastAt")
        UserDefaults.standard.set(cloudChangeRawValue(state), forKey: "cloudDetectLastState")
        return state
    }

    private static func cloudChangeRawValue(_ s: CloudChangeState) -> String {
        switch s {
        case .noChange: return "noChange"
        case .hasUpdate: return "hasUpdate"
        case .detectFailed: return "detectFailed"
        }
    }

    private static func cloudChangeState(fromRaw raw: String) -> CloudChangeState? {
        switch raw {
        case "noChange": return .noChange
        case "hasUpdate": return .hasUpdate
        case "detectFailed": return .detectFailed
        default: return nil
        }
    }

    /// 全量精确比对（fetchAll 逐间对比），并把云端修订号记成本地基线、确保总清单存在
    private static func compareWithFullFetch(config: CosConfig, ctx: ModelContext, activeKeys: Set<String>) async -> CloudChangeState {
        guard let recs = try? await CloudHouseSync.fetchAll(config: config) else { return .detectFailed }
        let state = stateFromFullRecords(recs, ctx: ctx, activeKeys: activeKeys)
        // 建立/刷新修订号基线
        var rev: [String: Int64] = [:]
        for r in recs { rev[r.roomKey] = r.revision ?? 0 }
        CloudRevisionStore.remember(rev)
        // 确保云端有一份总清单（best-effort，失败不影响检测结论）
        if (try? await CloudHouseSync.fetchManifest(config: config)) == nil {
            _ = try? await CloudHouseSync.rebuildManifest(config: config)
        }
        return state
    }

    /// 检测到有更新时，列出具体是哪几套房变了（供任务中心写明白「xx 房更新」）。
    /// 有基线走总清单（一次请求），无基线走全量账本；失败返回空数组，不影响提示。
    static func cloudChangedRoomKeys(houseContext: ModelContext?) async -> [String] {
        guard let config = CosConfig.load(), config.isValid, let ctx = houseContext else { return [] }
        let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        var localByKey: [String: House] = [:]
        for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
        // v2.62：本机正在上传/待重试的房号不列为「云端变化」
        let activeKeys = await MainActor.run(body: { Self.activeUploadRoomKeys() })
        let seen = CloudRevisionStore.all()
        if !seen.isEmpty, let manifest = try? await CloudHouseSync.fetchManifest(config: config) {
            var cloudByKey: [String: CloudManifestEntry] = [:]
            for e in manifest.rooms { cloudByKey[e.roomKey] = e }
            var keys: [String] = []
            for (key, entry) in cloudByKey {
                if activeKeys.contains(key) { continue }
                guard let h = localByKey[key] else { keys.append(key); continue }
                // v2.54：与 compareManifest 同口径，revision 不再一票否决，只看摘要
                if manifestSummaryDiffers(entry, from: h) { keys.append(key) }
            }
            for key in localByKey.keys where cloudByKey[key] == nil && !activeKeys.contains(key) { keys.append(key) }
            return keys.sorted()
        }
        guard let recs = try? await CloudHouseSync.fetchAll(config: config) else { return [] }
        var keys: [String] = []
        let cloudKeys = Set(recs.map { $0.roomKey })
        for rec in recs where !activeKeys.contains(rec.roomKey) {
            guard let h = localByKey[rec.roomKey] else { keys.append(rec.roomKey); continue }
            if cloudRecordDiffers(rec, from: h) != nil { keys.append(rec.roomKey) }
        }
        for key in localByKey.keys where !cloudKeys.contains(key) && !activeKeys.contains(key) { keys.append(key) }
        return keys.sorted()
    }

    private static func stateFromFullRecords(_ recs: [CloudHouseRecord], ctx: ModelContext, activeKeys: Set<String>) -> CloudChangeState {
        let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        var localByKey: [String: House] = [:]
        for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
        for rec in recs where !activeKeys.contains(rec.roomKey) {
            guard let h = localByKey[rec.roomKey] else { return .hasUpdate }
            if cloudRecordDiffers(rec, from: h) != nil { return .hasUpdate }
        }
        let cloudKeys = Set(recs.map { $0.roomKey })
        // v2.62：本机正在上传/待重试的房号不算「云端没有」
        for key in localByKey.keys where !cloudKeys.contains(key) && !activeKeys.contains(key) { return .hasUpdate }
        return .noChange
    }

    /// v2.54：总清单增量比对。revision 号只作「可能变化」的触发信号，最终结论以实际内容为准，
    /// 且每次检测后都刷新基线，使 revision 错位能自愈（不再「有更新就不更新基线、卡住反复提示」）。
    private static func compareManifest(_ manifest: CloudManifest, config: CosConfig, ctx: ModelContext, activeKeys: Set<String>) async -> CloudChangeState {
        let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        var localByKey: [String: House] = [:]
        for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
        let seen = CloudRevisionStore.all()
        var cloudByKey: [String: CloudManifestEntry] = [:]
        for e in manifest.rooms { cloudByKey[e.roomKey] = e }

        // 本地有、云端清单没有：沿用原口径判差异（具体补传还是删除由 syncCloudHouses 决定）
        // v2.62：本机正在上传/待重试的房号整体豁免——这是「自己还没传完」，不是云端更新
        for key in localByKey.keys where cloudByKey[key] == nil && !activeKeys.contains(key) {
            rememberManifestBaseline(manifest)
            return .hasUpdate
        }

        // 收集「可能有变化」的房间：本地缺失 / 摘要不同 / 摘要一致但 revision 变了（字段可能变，摘要看不出）
        var suspectKeys: [String] = []
        for (key, entry) in cloudByKey {
            if activeKeys.contains(key) { continue }
            guard let h = localByKey[key] else {
                suspectKeys.append(key)
                continue
            }
            if manifestSummaryDiffers(entry, from: h) {
                suspectKeys.append(key)
                continue
            }
            if let s = seen[key], s != entry.revision {
                suspectKeys.append(key)
            }
        }

        // 无嫌疑：内容一致，刷新基线，无变化
        guard !suspectKeys.isEmpty else {
            rememberManifestBaseline(manifest)
            return .noChange
        }

        // 有嫌疑：只拉这些房间的完整账本，按实际内容（8 字段 + 媒体 canonicalKey）精确判定。
        // v2.64：改成 16 并发窗口 + ETag 复用（fetchRecords）。原来这里是逐套串行 await，
        // 一旦清单缺指纹（v2.62 前写入的旧清单 mediaHash/fieldsHash 全为 nil → 每条都判嫌疑），
        // 218 套就是 218 个串行往返 ≈ 20 秒；同一批请求并发后 2~3 秒。
        let fetchedRecords: [CloudHouseRecord]
        do {
            fetchedRecords = try await CloudHouseSync.fetchRecords(keys: suspectKeys, config: config)
        } catch {
            // 网络/解析失败：既不能当无变化也不能当有更新，按检测失败处理
            return .detectFailed
        }
        let fetchedKeys = Set(fetchedRecords.map { $0.roomKey })
        // 清单有条目但 info.json 404（目录为空/已删）：这是「清单幽灵」脏数据，不是真实更新
        let ghostKeys = suspectKeys.filter { !fetchedKeys.contains($0) }
        var recByKey: [String: CloudHouseRecord] = [:]
        for rec in fetchedRecords { recByKey[rec.roomKey] = rec }

        var hasRealChange = false
        for key in suspectKeys {
            guard let rec = recByKey[key] else { continue }
            guard let h = localByKey[key] else {
                hasRealChange = true   // 云端账本真实存在、本地确实没有这套房
                continue
            }
            if cloudRecordDiffers(rec, from: h) != nil { hasRealChange = true }
        }

        // v2.64：顺手回填清单指纹。旧清单（v2.62 之前写入）每条的 mediaHash / fieldsHash 都是 nil，
        // 判定处 `guard let ... else { return true }` 会把全部房源当成「必须拉明细」，导致每次检测
        // 都全量拉一遍（20 秒+），而检测路径原来只写 revision 基线、从不修清单，所以永远修不好。
        // 本次已经拿到这些房的明细，直接按真实记录补写回清单（读-改-写；失败只记日志，下次再补）。
        let needsFingerprintBackfill = manifest.rooms.contains { $0.mediaHash == nil || $0.fieldsHash == nil }
        var baselineManifest = manifest
        if needsFingerprintBackfill || !ghostKeys.isEmpty {
            var upserts: [String: CloudManifestEntry] = [:]
            if needsFingerprintBackfill {
                for rec in fetchedRecords { upserts[rec.roomKey] = CloudManifestEntry(record: rec) }
            }
            do {
                try await CloudHouseSync.applyManifestChanges(
                    upserts: upserts, removes: Set(ghostKeys), config: config)
                // 回填成功：按「回填后的清单」记基线。回填条目的 revision 取自明细，
                // 可能与旧清单条目不同；若仍按旧清单记基线，下一次会因 revision 错位再全量拉一遍。
                var merged = Dictionary(manifest.rooms.map { ($0.roomKey, $0) }, uniquingKeysWith: { first, _ in first })
                for (key, entry) in upserts { merged[key] = entry }
                for key in ghostKeys { merged[key] = nil }
                baselineManifest = CloudManifest(version: manifest.version, revision: manifest.revision + 1,
                                                 generatedAt: Date(), rooms: Array(merged.values))
            } catch {
                BackupLogStore.log(category: "同步", action: "回填清单摘要", result: "失败",
                                  detail: "清单 \(upserts.count) 套指纹未回填、幽灵 \(ghostKeys.count) 套未摘除：\(error.localizedDescription)，下次检测再补",
                                  cloud: true)
            }
        }

        // 关键：无论是否真有差异，都把当前 manifest revision 记为基线，让 revision 错位自愈、不再卡住
        rememberManifestBaseline(baselineManifest)
        return hasRealChange ? .hasUpdate : .noChange
    }

    /// 把当前总清单各房 revision 整体记为「本机已见」基线（幂等）
    private static func rememberManifestBaseline(_ manifest: CloudManifest) {
        var rev: [String: Int64] = [:]
        for e in manifest.rooms { rev[e.roomKey] = e.revision }
        CloudRevisionStore.remember(rev)
    }

    /// v2.54：摘要口径（不含 revision 号）——座号/房号/媒体数（归一化去重）不同才算嫌疑
    private static func manifestSummaryDiffers(_ entry: CloudManifestEntry, from house: House) -> Bool {
        if entry.tower != house.tower { return true }
        if entry.roomNo != house.roomNo { return true }
        let exempt = exemptPendingKeys(roomKey: house.mediaRoomKey)
        let localMedia = Set(house.mediaItems.map { mediaNormKey($0.fileName) }).subtracting(exempt)
        if entry.mediaCount != localMedia.count { return true }
        // v2.62：清单指纹比对。旧清单条目没有指纹（nil）→ 必须拉明细，
        // 绝不能只凭「数量一样」判同——删 6 个又新增 6 个时数量不变但内容全变了。
        guard let mediaHash = entry.mediaHash, let fieldsHash = entry.fieldsHash else { return true }
        if mediaHash != CloudManifestFingerprint.mediaHash(Array(localMedia)) { return true }
        if fieldsHash != CloudManifestFingerprint.fieldsHash(
            roomNo: house.roomNo, tower: house.tower, landlord: house.landlord,
            layout: house.layout, price: house.price, password: house.password,
            remark: house.remark, status: house.statusRaw) { return true }
        return false
    }

    /// 从独立 HouseStore 配置拉取房源（按创建时间倒序，与原来 @Query 一致；v1.7：排除已进回收站的软删除房源）
    /// v1.9：isDeleted 为可选属性，SwiftData #Predicate 对「可选 Bool」在 iOS 17 会触发翻译崩溃（点进房源板块闪退的根因），
    /// 改为全量拉取 + 内存过滤（房源数量级小，性能无影响）
    private func reloadHouses() {
        guard let ctx = houseModelContext else { return }
        let descriptor = FetchDescriptor<House>(sortBy: [SortDescriptor(\House.createdAt, order: .reverse)])
        let all = (try? ctx.fetch(descriptor)) ?? []
        // v1.70：强制从持久层重载每个房源对象（含 mediaItems 关系）——修复「批量恢复媒体后
        // 卡片仍显示无实拍图/不显示缩略图，必须重启才正常」：SwiftData 同一上下文里插入媒体后，
        // 已缓存对象的 to-many 关系不会自动刷新，列表重新 fetch 拿到的仍是同一实例、关系为旧缓存。
        // v1.70：提交挂起变更（含媒体关系插入），确保批量恢复/编辑后重新 fetch 拿到最新关系——
        // 此前列表重新 fetch 返回同一对象实例、mediaItems 关系为旧缓存，缩略图不显示需重启。
        // 注：ModelContext 无 CoreData 式 refresh API，用 processPendingChanges 强制同步变更。
        ctx.processPendingChanges()
        houses = all.filter { !$0.isTrashed }
        // v1.71：存量无前缀媒体目录自动归一迁移（media/2059/ → media/1-2059/），幂等；修复
        // v1.69 前编辑页新图落盘无前缀目录导致的上传失败、云端断媒体、刷新缺媒体死循环。
        MediaStore.migrateUnprefixedHouseDirectories(houses: houses)
        // v2.24：刷新「无媒体」房号集合（按磁盘实际文件，不看 mediaItems 关系缓存）
        var noMedia: Set<String> = []
        for h in houses {
            let dir = MediaStore.houseDirectory(roomKey: h.mediaRoomKey)
            if MediaStore.mediaFileNames(in: dir).isEmpty { noMedia.insert(h.mediaRoomKey) }
        }
        noMediaKeys = noMedia
    }

    // MARK: - 头部折叠（v2.3 需求②：自动折叠方案确认无效，改为按钮式——手动收起/展开；不再随滚动自动切换）

    /// v2.24（B13）：筛选区收起后显示当前筛选条件，而不是一句「已收起」
    private var filterSummaryText: String {
        var parts: [String] = []
        parts.append(towerFilter.map { "\($0)座" } ?? "全部座")
        parts.append(statusFilter?.label ?? "全部状态")
        if !layoutFilters.isEmpty { parts.append(layoutFilters.sorted().joined(separator: "、")) }
        if showOnlyNoMedia { parts.append("只看无媒体") }
        if !searchText.isEmpty { parts.append("搜「\(searchText)」") }
        return parts.joined(separator: " · ")
    }

    private var collapsibleHeader: some View {
        VStack(spacing: 0) {
            if !headerCollapsed {
                statsBar
                searchBar
                filterBar
            } else {
                // 收起态：单行提示条，点它展开
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { headerCollapsed = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("\(filterSummaryText) · 点此展开")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: headerCollapsed)
    }

    // MARK: - 统计（动态跟随当前筛选；v1.31：恢复 v1.29 显示方式 + 修复统计栏下沉）
    // 规则：
    //  - 筛选了座号 / 户型 → 显示筛选口径数量（如「1座 X套」「1座 单间上层 X套」，状态为隐含条件不拼入）
    //  - 仅筛选状态（含默认待租）→ 显示「待租 X套 + 1座 X套 + 2座 X套」：状态在前、该状态下的座号分布跟上，
    //    1座/2座不再被默认「待租」筛选顶替掉（统计栏不下沉）
    //  - 无任何筛选 → 显示「1座 X套 2座 X套 待租 X套」

    private var statsBar: some View {
        HStack(spacing: 12) {
            // v2.3（需求⑤修正）：上版误删了整条统计栏——恢复 v1.99/b106 版（排序 + 数量胶囊全部保留），
            // 只删除原「房源统计」4 字标识（因为它会被折叠收起来，其余全部保留）
            // 折叠按钮（v2.3 需求②）：手动收起统计/搜索/筛选区
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { headerCollapsed = true }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起筛选区")

            // 排序三档（默认=现有逻辑 / 价格升序 / 更新时间降序）
            // v2.7（P2⑮）：去掉文字只留图标，功能不变
            Menu {
                ForEach(HouseSortMode.allCases, id: \.self) { m in
                    Button {
                        houseSortMode = m
                    } label: {
                        Label(m.label, systemImage: houseSortMode == m ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .background(AppTheme.primary.opacity(0.08))
                    .foregroundColor(AppTheme.primary)
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("排序：\(houseSortMode.label)")

            // v2.7（P2⑮）：无媒体筛选按钮（只看没有实拍图/视频的房源）
            // b117→b119：曾用 photo.on.rectangle.slash（iOS 部分版本该符号渲染为空 → 只剩底色圆点）。
            // v2.9（第六大点3 删除重建）：改用 photo/photo.fill 基础符号（全 iOS 版本确定渲染），
            // 未选中 浅绿底+绿图标，选中 实心绿底+白图标，与排序按钮一眼区分。
            Button {
                showOnlyNoMedia.toggle()
            } label: {
                Image(systemName: showOnlyNoMedia ? "photo.fill" : "photo")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .background(showOnlyNoMedia ? Color.green : Color.green.opacity(0.15))
                    .foregroundColor(showOnlyNoMedia ? .white : Color.green)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showOnlyNoMedia ? "仅看无媒体（已开启）" : "仅看无媒体")

            // v2.18：已收录总数（从设置页移来）——固定显示全量套数，不随筛选变化
            Text("共\(houses.count)套")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer()

            if towerFilter != nil || !layoutFilters.isEmpty {
                Text(statsFilteredLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                    .lineLimit(1)
            } else if let status = statusFilter {
                Text("\(status.label) \(filteredHouses.count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("1座 \(filteredHouses.filter { $0.tower == 1 }.count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("2座 \(filteredHouses.filter { $0.tower == 2 }.count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
            } else {
                Text("1座 \(tower1Count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("2座 \(tower2Count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("待租 \(availableCount) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    private var statsFilteredLabel: String {
        var parts: [String] = []
        if let t = towerFilter { parts.append("\(t)座") }
        if !layoutFilters.isEmpty { parts.append(layoutFilters.sorted().joined(separator: "、")) }
        parts.append("\(filteredHouses.count)套")
        return parts.joined(separator: " ")
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索房号 / 房东 / 户型 / 备注", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 分类检索（第一行：座号 / 状态；第二行：户型）

    private var filterBar: some View {
        VStack(spacing: 8) {
            // 第一行：座号 + 状态
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(title: "全部座", isOn: towerFilter == nil) {
                        towerFilter = nil
                    }
                    filterChip(title: "1座", isOn: towerFilter == 1) {
                        towerFilter = 1
                    }
                    filterChip(title: "2座", isOn: towerFilter == 2) {
                        towerFilter = 2
                    }

                    Divider().frame(height: 16)

                    filterChip(title: "全部状态", isOn: statusFilter == nil) {
                        statusFilter = nil
                    }
                    filterChip(title: "待租", isOn: statusFilter == .available) {
                        statusFilter = .available
                    }
                    filterChip(title: "已租", isOn: statusFilter == .rented) {
                        statusFilter = .rented
                    }
                }
                .padding(.horizontal, 16)
            }

            // 第二行：户型筛选（独立一行，选项随已收录房源的户型类型动态增减；支持多选）
            // v1.69：「全部户型」固定在最左，不随右侧户型左右移动
            HStack(spacing: 8) {
                filterChip(title: "全部户型", isOn: layoutFilters.isEmpty) {
                    layoutFilters.removeAll()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(layouts, id: \.self) { layout in
                            filterChip(title: layout, isOn: layoutFilters.contains(layout)) {
                                if layoutFilters.contains(layout) {
                                    layoutFilters.remove(layout)
                                } else {
                                    layoutFilters.insert(layout)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private func filterChip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? AppTheme.primary : Color.white)
                .foregroundColor(isOn ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 列表（点击卡片进入详情；多选模式点击卡片切换选中；编辑/已租/删除在详情页操作）

    private var houseList: some View {
        Group {
            if houses.isEmpty {
                EmptyStateView(
                    icon: "house",
                    title: "还没有房源",
                    subtitle: "点右上角「+」登记第一套房源"
                )
            } else if filteredHouses.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "没有匹配的房源",
                    subtitle: "换个搜索词或筛选条件试试"
                )
            } else {
                // v1.10：列表容器由 ScrollView+自定义 SwipeActionRow 改为 List+原生 swipeActions（与其他板块一致），
                // 左滑菜单「分享」替换为「已租」（直接切换房源状态为已租）
                List {
                    ForEach(filteredHouses) { house in
                        if isSelecting {
                            // 多选模式：点击整卡切换选中，左上角勾选标记
                            Button {
                                toggleHouseSelect(house)
                            } label: {
                                HouseCardView(house: house)
                                    .overlay(alignment: .topLeading) {
                                        Image(systemName: selectedHouseIDs.contains(house.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundColor(selectedHouseIDs.contains(house.id) ? AppTheme.primary : Color.white)
                                            .shadow(radius: 2)
                                            .padding(8)
                                    }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        } else {
                            // 卡片左滑菜单（编辑 / 状态切换 / 删除），样式与其他板块一致；点击卡片进入详情
                            // v1.11：状态按钮按当前状态动态显示（待租→「已租」、已租→「待租」），颜色用绿色与编辑的蓝色区分
                            HouseCardView(house: house)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    showDetailHouse = house
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteTarget = house
                                        isBatchDelete = false
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .tint(.red)
                                    Button {
                                        toggleHouseStatus(house)
                                    } label: {
                                        Label(house.status == .rented ? "待租" : "已租", systemImage: house.status == .rented ? "arrow.uturn.backward" : "checkmark.circle")
                                    }
                                    .tint(.green)
                                    Button {
                                        showEditHouse = house
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    .tint(.themeBlue)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.background)
                // v2.3（需求②）：折叠已改为按钮式手动收起/展开，不再随滚动自动切换（原 b106 自动方案无效）
                // v1.19：下拉刷新 = 从云端拉取房源（与左上角手动同步同效果）
                // v1.63：下拉刷新改本地刷新——媒体补全检测（磁盘与记录对账），不再触发云端同步；
                //        左上角刷新按钮保持云端同步不变
                .refreshable {
                    await localRefreshWithMediaCheck()
                }
            }
        }
        // v1.21：多选模式底部操作栏（v1.12：增加批量已租 / 批量删除，分享逻辑保留不动）
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text("已选 \(selectedHouseIDs.count) 套")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.primary)
                        Spacer()
                        Button("全选") {
                            selectAllFiltered()
                        }
                        .font(.subheadline)
                        .disabled(selectedHouseIDs.count == filteredHouses.count)
                    }
                    HStack(spacing: 10) {
                        // v2.17：批量保存视频到相册——之后到微信聊天里「相册」多选一次发完
                        Button {
                            saveSelectedVideos()
                        } label: {
                            Text("保存")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(selectedHouseIDs.isEmpty)
                        // v1.12：批量已租——选中的待租房源一键标为已租（已租的保持不变）
                        Button {
                            batchSetRented()
                        } label: {
                            Text("已租")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(selectedHouseIDs.isEmpty)
                        // v1.12：批量删除——移入回收站（二级确认，不删照片视频）
                        Button(role: .destructive) {
                            isBatchDelete = true
                            showDeleteConfirm = true
                        } label: {
                            Text("删除")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(selectedHouseIDs.isEmpty)
                        // v1.21：批量分享（合集卡片）——保留原逻辑
                        Button {
                            startMultiShare()
                        } label: {
                            Text("分享（\(selectedHouseIDs.count)）")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primary)
                        .disabled(selectedHouseIDs.isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        // v2.24：云端删除进度 / 失败重试浮层（居中，成功自动消失）
        .overlay { deleteOverlayCard }
        // v2.17：轻提示（底部胶囊，2.6 秒自动消失，不挡列表、不需要点「好」）
        .overlay(alignment: .bottom) {
            if let t = saveToast {
                Text(t)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82))
                    .clipShape(Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - v1.21 多选分享

    private func toggleHouseSelect(_ house: House) {
        if selectedHouseIDs.contains(house.id) {
            selectedHouseIDs.remove(house.id)
        } else {
            selectedHouseIDs.insert(house.id)
        }
    }

    private func selectAllFiltered() {
        for house in filteredHouses {
            selectedHouseIDs.insert(house.id)
        }
    }

    /// v2.26：分享面板从顶层直呈，面板关闭后按队列决定「继续下一套 / 结束」
    private func presentShareStep(_ items: [Any]) {
        currentShareStep = ShareStep(items: items)
    }

    private func exitMultiSelect() {
        isSelecting = false
        selectedHouseIDs.removeAll()
        shareQueue = []
        shareIndex = 0
    }

    // MARK: - v2.24 删除（仅本地 / 双端）

    private var deleteConfirmMessage: String {
        let count = isBatchDelete ? selectedHouseIDs.count : 1
        let scope: String
        switch deleteTarget?.cloudStatus {
        case .some(.local): scope = "这套房源本机有、云端没有"
        case .some(.cloud): scope = "这套房源本机无媒体、云端有"
        default: scope = "这套房源本地和云端都有"
        }
        let head = isBatchDelete ? "共 \(count) 套，\(scope)。" : "\(scope)。"
        return head + "\n\n仅删除本地：云端不动，下次同步会把它们重新带回列表。\n删除双端（推荐）：本地照片视频、数据库记录、云端 h/<房号>/ 与账本一并清除，不可恢复（备份镜像 backups/media 保留）。"
    }

    /// v2.57（P1-2）：统一下手改为「先删云端、成功再删本地」——
    /// 旧顺序（先本地后云端）在云端删除失败期间，任何设备一同步就把已删的房原样拉回来（“删了又复活”）。
    /// 现在：先云后本，云端删成功的房立即清本地（界面马上见效）；云端删失败的房本地保留，
    /// 挂任务中心标注「云端环节失败」，retryCloudDelete 重试成功后自动清掉本地残留。
    private func startDelete(both: Bool) {
        guard let ctx = houseModelContext else {
            showToast(RemoteConfig.tip("containerUnavailable", "数据容器不可用，无法删除"), isError: true)
            return
        }
        // 先把房号目录取成值，删完对象就失效了
        var keys: [String] = []
        var rooms: [String] = []
        if isBatchDelete {
            for h in houses where selectedHouseIDs.contains(h.id) {
                keys.append(h.mediaRoomKey); rooms.append(h.displayRoomNo)
            }
        } else if let t = deleteTarget {
            keys.append(t.mediaRoomKey); rooms.append(t.displayRoomNo)
        }
        guard !keys.isEmpty else { deleteTarget = nil; isBatchDelete = false; return }
        _ = rooms

        // 仅删本地：走老路（不动云端），云端本来就不打算删
        if !both {
            for h in houses where keys.contains(h.mediaRoomKey) {
                MediaStore.deleteHouseDirectory(roomKey: h.mediaRoomKey)
                SyncFailStore.clear(h.mediaRoomKey)
                UnreadCloudHouseStore.clear(h.mediaRoomKey)
                ctx.delete(h)
            }
            do {
                try ctx.save()
            } catch {
                showToast(RemoteConfig.tip("deleteFail", "删除失败：{error}").replacingOccurrences(of: "{error}", with: error.localizedDescription), isError: true)
                return
            }
            deleteTarget = nil
            if isBatchDelete { exitMultiSelect() }
            isBatchDelete = false
            // v2.57（P1-5）：本地已删，队列里这套房的待传项全部清掉，不再复活成幽灵任务
            for key in keys { HouseMediaUploadQueue.removeRoom(key) }
            NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
            showToast(RemoteConfig.tip("deletedLocalOnly", "已删除本地房源；云端仍保留，下次同步会重新出现").replacingOccurrences(of: "本地房源", with: "\(keys.count) 套本地房源"))
            return
        }

        // 服务器模式：双端删除走服务器软删除（进回收站，可恢复），逐套同步
        if HouseServerMode.ready {
            runServerDelete(keys: keys, ctx: ctx)
            return
        }

        // 双端删除：无云端配置 → 云端本来就没有，只删本地
        guard let config = CosConfig.load(), config.isValid else {
            for h in houses where keys.contains(h.mediaRoomKey) {
                MediaStore.deleteHouseDirectory(roomKey: h.mediaRoomKey)
                SyncFailStore.clear(h.mediaRoomKey)
                UnreadCloudHouseStore.clear(h.mediaRoomKey)
                ctx.delete(h)
            }
            do {
                try ctx.save()
            } catch {
                showToast(RemoteConfig.tip("deleteFail", "删除失败：{error}").replacingOccurrences(of: "{error}", with: error.localizedDescription), isError: true)
                return
            }
            deleteTarget = nil
            if isBatchDelete { exitMultiSelect() }
            isBatchDelete = false
            for key in keys { HouseMediaUploadQueue.removeRoom(key) }
            NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
            showToast("已删除本地 \(keys.count) 套（未配置云端，无需再删云端）")
            return
        }

        // 双端删除（先云后本）：云端先删。删完云端的房才动本地；
        // 云端失败的房本地先不删（防“复活”），挂任务中心标明失败环节，云端重试成功后再清本地。
        runCloudThenLocalDelete(keys: keys, config: config, ctx: ctx)
    }

    /// v2.57（P1-2）：双端删除执行体——先逐套删云端，成功一套删一套本地；全部云端成功的房本地立即清、
    /// 界面马上见效；云端失败的房本地保留（同步不会把它拉回来，因为云端已删/在删），挂任务中心
    /// 「删云端」任务标注失败环节，retryCloudDelete 成功后自动清掉本地残留。
    /// 服务器模式双端删除：逐套调服务器软删除（进回收站），本地同步标记；失败的房本地保留可重试
    private func runServerDelete(keys: [String], ctx: ModelContext) {
        deleteTotal = keys.count
        deleteDone = 0
        deleteRunning = true
        deleteCurrentRoom = ""
        Task {
            var ok = 0
            for key in keys {
                await MainActor.run { deleteCurrentRoom = key }
                if let h = houses.first(where: { $0.mediaRoomKey == key }) {
                    do {
                        try await HouseSyncEngine.shared.pushDelete(h)
                        ok += 1
                    } catch {
                        showToast("删除失败 \(key)：\(error.localizedDescription)", isError: true)
                    }
                }
                await MainActor.run { deleteDone += 1 }
            }
            await MainActor.run {
                try? ctx.save()
                deleteRunning = false
                deleteCurrentRoom = ""
                deleteTarget = nil
                if isBatchDelete { exitMultiSelect() }
                isBatchDelete = false
                for key in keys { HouseMediaUploadQueue.removeRoom(key) }
                NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
                if ok > 0 { showToast("已移入回收站 \(ok) 套") }
            }
        }
    }

    private func runCloudThenLocalDelete(keys: [String], config: CosConfig, ctx: ModelContext) {
        deleteTotal = keys.count
        deleteDone = 0
        deleteCurrentRoom = ""
        deleteRunning = true
        let taskID = syncCenter.begin(kind: .cloudDelete, title: "删云端",
                                      roomKeys: keys, total: keys.count)
        Task {
            var cloudFailed: [String] = []      // 云端没删掉 → 本地保留、任务中心重试
            var localDeleted: [String] = []      // 云端删成功、本地已标记删除（循环结束统一 save）
            var queueRemovalKeys: [String] = []  // 待清队列的房号（循环结束统一清）
            // v2.58（#8）：本地房源只在开头查一次表，循环内不再每套都 fetch 全表
            var byKey: [String: House] = [:]
            await MainActor.run {
                let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                for h in all { byKey[h.mediaRoomKey] = h }
            }
            for (idx, key) in keys.enumerated() {
                await MainActor.run { deleteCurrentRoom = key }
                var objCount = 0
                do {
                    try await CloudBackupService.deleteHouseRemoteFolder(roomKey: key, config: config, writeLog: false, reportCount: { objCount = $0 })
                    try await CloudHouseSync.delete(roomKey: key, config: config)
                    BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "成功", detail: "删除房源（云端桶文件夹\(objCount)个对象 + 云端账本已移除）", room: key, cloud: true)
                } catch {
                    cloudFailed.append(key)
                    BackupLogStore.log(category: "删除", action: "删除（云端环节）", result: "失败", detail: "云端删除失败：\(error.localizedDescription)；本地暂不删除，待云端删除成功后自动清理", room: key, cloud: true)
                }
                // 云端删成功的房：本地跟着删（只标记删除、累计房号；save 与通知统一放到循环结束）
                if !cloudFailed.contains(key) {
                    await MainActor.run {
                        if let h = byKey.removeValue(forKey: key) {
                            MediaStore.deleteHouseDirectory(roomKey: key)
                            SyncFailStore.clear(key)
                            UnreadCloudHouseStore.clear(key)
                            ctx.delete(h)
                            localDeleted.append(key)
                        }
                        // v2.57（P1-5）：队列残留一并清，防幽灵任务（v2.58 起循环结束统一清）
                        queueRemovalKeys.append(key)
                    }
                }
                await MainActor.run {
                    deleteDone = idx + 1
                    syncCenter.advance(id: taskID, done: idx + 1, note: "正在删 \(key)")
                }
            }
            await MainActor.run {
                // v2.58（#8）：批量删除收口——一次 save、一次列表通知（进度条仍逐套推进）
                for key in queueRemovalKeys { HouseMediaUploadQueue.removeRoom(key) }
                if !localDeleted.isEmpty {
                    try? ctx.save()
                }
                if !queueRemovalKeys.isEmpty {
                    NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
                }
                deleteRunning = false
                deleteCurrentRoom = ""
                deleteTarget = nil
                if isBatchDelete { exitMultiSelect() }
                isBatchDelete = false
                let okCount = keys.count - cloudFailed.count
                if cloudFailed.isEmpty {
                    showToast(RemoteConfig.tip("deleteBothOk", "已删除（本地 + 云端）").replacingOccurrences(of: "已删除", with: "已删除 \(keys.count) 套"))
                    syncCenter.finish(id: taskID, success: true, note: "云端已删除 \(keys.count) 套")
                    HouseActionNotifier.shared.send(
                        key: "delete.\(keys.joined(separator: ","))",
                        title: "房源已删除",
                        body: "\(keys.joined(separator: "、")) 本地与云端均已删除"
                    )
                } else {
                    // 失败标注环节：这些房云端没删掉、本地保留
                    syncCenter.finish(id: taskID, success: false,
                                     failure: "这几套云端没删掉（本地保留未删）：\(cloudFailed.joined(separator: "、"))，点重试；云端删除成功后会自动清掉本地")
                    HouseActionNotifier.shared.send(
                        key: "deletefail.\(cloudFailed.joined(separator: ","))",
                        title: "云端没删掉",
                        body: "\(cloudFailed.count) 套云端删除失败（本地保留）：\(cloudFailed.joined(separator: "、"))，可到任务中心重试",
                        silent: true
                    )
                    if okCount > 0 {
                        showToast("已删除 \(okCount) 套（本地 + 云端）；\(cloudFailed.count) 套云端没删掉、本地保留，可到任务中心重试")
                    } else {
                        showToast("云端删除失败（\(cloudFailed.joined(separator: "、"))），本地已保留，可到任务中心重试", isError: true)
                    }
                }
            }
        }
    }

    /// 云端删除进度浮层（只负责进行中展示；失败进任务中心，不再在浮层里放重试）
    @ViewBuilder private var deleteOverlayCard: some View {
        if deleteRunning {
            VStack(spacing: 12) {
                Text("正在同步删除云端")
                    .font(.headline)
                ProgressView(value: deleteTotal == 0 ? 0 : Double(deleteDone) / Double(deleteTotal))
                    .progressViewStyle(.linear)
                    .frame(width: 210)
                Text("\(deleteDone)/\(deleteTotal)" + (deleteCurrentRoom.isEmpty ? "" : " · h/\(deleteCurrentRoom)/"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 12)
        }
    }

    /// v1.11：卡片左滑状态切换按钮——待租→已租、已租→待租，按当前状态动态显示并反向切换。
    /// 默认列表筛选口径为「待租」，切换为已租后该房源从当前列表消失；已租筛选下左滑可一键改回待租。
    /// v1.19：切换时刷新最后更新时间，并把新状态同步到云端账本（共享房源）。
    private func toggleHouseStatus(_ house: House) {
        guard let ctx = houseModelContext else { return }
        let oldStatus = house.status
        let roomKey = house.mediaRoomKey
        house.status = (house.status == .rented) ? .available : .rented
        house.lastUpdatedAt = Date()
        try? ctx.save()
        // v2.45：账本事件
        HouseLedgerStore.append(
            roomKey: roomKey,
            action: "切换状态",
            fieldChanges: [HouseLedgerFieldChange(field: "状态", oldValue: oldStatus.label, newValue: house.status.label)])
        pushHouseToCloud(house, action: "切换状态", changeText: "状态：\(oldStatus.label) → \(house.status.label)")
        NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
    }

    // MARK: - v1.19 云端房源同步（共享房源）

    /// 把单套房源推送到云端账本（读改写，同房号覆盖）。无云存储配置则跳过（仅本地）。
    /// v1.72（#7）：动作按场景命名（切换状态同步…）；（#8）账本上传也驱动卡片进度条；（#6）写本地账本镜像。
    private func pushHouseToCloud(_ house: House, action: String = "同步房源（本地→云端）", changeText: String = "") {
        guard let config = CosConfig.load() else { return }
        let record = CloudHouseSync.record(from: house, username: CloudUser.username)
        let roomKey = house.mediaRoomKey
        let roomNo = house.displayRoomNo
        LocalHouseLedger.save(house)
        HouseSyncProgress.shared.begin(roomKey: roomKey, direction: .upload, progress: 0.2, label: "同步账本")
        Task {
            do {
                // v2.36（#6）：状态切换改走 uploadGuarded 合并写——先读云端再合并媒体名单、revision+1，
                // 不再裸 upload 覆盖他人刚写入的数据/媒体
                _ = try await CloudHouseSync.uploadGuarded(record: record, config: config)
                HouseSyncProgress.shared.end()
                await MainActor.run {
                    house.cloudStatus = .both
                    SyncFailStore.clear(roomKey)
                    try? houseModelContext?.save()
                    // v2.44：状态切换同步结果
                    HouseActionNotifier.shared.send(
                        key: "status.\(roomKey)",
                        title: "状态已同步",
                        body: "\(roomNo) 已改为\(house.status.label)，云端已更新"
                    )
                }
                BackupLogStore.log(category: "房源", action: action, result: "成功", detail: changeText, room: roomNo, cloud: true)
            } catch {
                HouseSyncProgress.shared.end()
                await MainActor.run {
                    SyncFailStore.mark(roomKey)
                    HouseActionNotifier.shared.send(
                        key: "statusfail.\(roomKey)",
                        title: "状态同步失败",
                        body: "\(roomNo) 已改本机，云端没同步上：\(error.localizedDescription)",
                        silent: true
                    )
                }
                BackupLogStore.log(category: "房源", action: action, result: "失败", detail: "同步失败：\(error.localizedDescription)", room: roomNo, cloud: true)
            }
        }
    }

    /// v2.50：云端有更新横幅——常驻顶栏，只有点右侧 ✕ 才收起；同步成功后自动收起。
    @ViewBuilder
    private var cloudUpdateBanner: some View {
        Group {
            if cloudUpdateBannerVisible {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.down").font(.footnote)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("检测到云端有更新")
                            .font(.footnote.weight(.semibold))
                        Text("点右上角刷新或下拉列表同步")
                            .font(.caption2).opacity(0.85)
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { cloudUpdateBannerVisible = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote)
                            .padding(.vertical, 8)
                            .padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭云端更新提示")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.14))
                .foregroundColor(.orange)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// v1.80：公告横幅——读云端远程配置 announcement（后台「远程配置」页可编辑，改动即时生效）
    @ViewBuilder
    private var announcementBanner: some View {
        if let ann = RemoteConfig.announcement, ann.enabled, !ann.text.isEmpty {
            Button {
                // v1.83：只放行 http/https 链接，其他 scheme（javascript: 等）一律忽略，防异常链接
                if let link = ann.link, !link.isEmpty,
                   let url = URL(string: link),
                   let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "megaphone.fill")
                        .font(.footnote)
                    Text(ann.text)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if !(ann.link ?? "").isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.14))
                .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
        }
    }

    private func showToast(_ msg: String, isError: Bool = false) {
        withAnimation(.easeOut(duration: 0.18)) {
            infoToast = msg
            infoToastIsError = isError
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            guard infoToast == msg else { return }
            withAnimation(.easeIn(duration: 0.18)) { infoToast = nil }
        }
    }

    /// v1.41：云端账本与本地房源的字段级对比——任一字段（含媒体清单）不同即视为有变化。
    /// v1.43：媒体名归一化 key——去扩展名 + 小写。
    /// 视频 .mov/.mp4 同源（上传云端统一转 mp4、本地按原样或账本名保存），按此视为同一文件；
    /// 图片保留完整后缀（foo.jpg ≠ foo.png），不同 base 名也区分。v2.37（#11）：统一走 MediaNaming.canonicalKey。
    private static func mediaNormKey(_ name: String) -> String {
        MediaNaming.canonicalKey(name)
    }

    /// 仍在待上传登记簿里的媒体属于“本地还没传完”，对账时不能把它算成本地与云端的真实差异。
    /// 否则失败任务被取消后，这条本地媒体仍被豁免删除，但每轮刷新又被判成“云端有更新”，形成死循环。
    private static func exemptPendingKeys(roomKey: String) -> Set<String> {
        Set(HouseMediaUploadQueue.pendingItems()
            .filter { $0.roomKey == roomKey }
            .map { mediaNormKey($0.fileName) })
    }

    /// v2.62：本机「正在上传 / 待重试」的房号集合。
    /// 这些房是「本地先建好、云端还没写完」，检测时必须整体豁免——否则新增房源上传途中
    /// 任何一次检测都会命中「本地有、云端没有」，弹出假「云端有更新」。
    @MainActor
    private static func activeUploadRoomKeys() -> Set<String> {
        var keys = Set(HouseMediaUploadQueue.pendingItems().map { $0.roomKey })
        for task in SyncTaskCenter.shared.running where task.isHouseUpload == true {
            keys.formUnion(task.roomKeys)
        }
        return keys
    }

    /// v2.62：当前是否有房源上传任务正在跑（决定要不要跳过整次检测）
    @MainActor
    private static func hasRunningHouseUpload() -> Bool {
        SyncTaskCenter.shared.running.contains { $0.isHouseUpload == true }
    }

    /// 替代旧的时间戳比较：时间戳只有秒级精度且恢复备份后 lastUpdatedAt 为空，
    /// 会导致「明明没变化每次同步都判更新」。字段级对比满足「一个标点符号变了都要同步」。
    /// v1.43：媒体清单改用归一化等价比较（去扩展名小写）——视频 .mov/.mp4 视为同一文件，
    ///        不再因两套扩展名互斥而每次同步都误判「更新」。
    /// b116：返回差异描述（nil=一致，非nil=具体哪个字段不同），字符串先 trim 防首尾空格死循环。
    /// b120：改为 static——轻量变更感知（detectCloudLedgerChange）与同步按钮共用同一判定口径。
    private static func cloudRecordDiffers(_ rec: CloudHouseRecord, from house: House) -> String? {
        let ls = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if rec.roomNo != house.roomNo { return "roomNo「\(rec.roomNo)」vs「\(house.roomNo)」" }
        if rec.tower != house.tower { return "tower \(rec.tower) vs \(house.tower)" }
        if ls(rec.landlord) != ls(house.landlord) { return "landlord「\(rec.landlord)」vs「\(house.landlord)」" }
        if ls(rec.layout) != ls(house.layout) { return "layout「\(rec.layout)」vs「\(house.layout)」" }
        if rec.price != house.price { return "price \(rec.price) vs \(house.price)" }
        if ls(rec.password) != ls(house.password) { return "password 不同" }
        if ls(rec.remark) != ls(house.remark) { return "remark「\(rec.remark)」vs「\(house.remark)」" }
        if ls(rec.status) != ls(house.statusRaw) { return "status「\(rec.status)」vs「\(house.statusRaw)」" }
        let exempt = exemptPendingKeys(roomKey: house.mediaRoomKey)
        let localMedia = Set(house.mediaItems.map { Self.mediaNormKey($0.fileName) }).subtracting(exempt)
        let cloudMedia = Set(rec.mediaNames.map { Self.mediaNormKey($0) })
        if localMedia != cloudMedia {
            let onlyLocal = localMedia.subtracting(cloudMedia)
            let onlyCloud = cloudMedia.subtracting(localMedia)
            return "media 本地独有[\(onlyLocal.joined(separator: ","))] 云端独有[\(onlyCloud.joined(separator: ","))]"
        }
        return nil
    }

    /// 从云端拉取房源账本并同步到本地（下拉刷新 / 左上角手动同步同效果）。
    /// v1.19 补全「增减逻辑」：
    ///  - 增：云端新增 → 完整下载到本地（文字 + 媒体），标双端、可编辑
    ///  - 改：云端比本地新 → 覆盖文字字段；本地媒体缺失但云端有 → 自动下载媒体
    ///  - 减：本地房源在云端账本已不存在 → 若它来自云端（双端/云端）则跟随删除；纯本地未上传的保留并补传云端
    ///  - 无任何变化 → 提示「已刷新，无变化」，不写入操作日志
    /// v1.41：
    ///  - 「更新」判定改为字段级对比（cloudRecordDiffers），不再依赖时间戳（时间戳精度/恢复备份导致误判）
    ///  - 媒体差异双向识别：云端有本地缺（要下载）与 本地有云端缺（要跟随删除）都算变化并弹确认
    /// v1.63：下拉刷新 = 本地刷新（媒体补全检测）：
    /// 磁盘有而记录没有 → 自动补建媒体记录；记录有而磁盘没有 → 提示待云端回补；
    /// 无对应房源的目录 → 提示可扫描补录。有变化列明细，无变化提示「已刷新，无变化」。
    private func localRefreshWithMediaCheck() async {
        // v2.63：重入保护——连续下拉两次时不并发跑两份本地对账，避免同一文件被重复插入媒体记录
        guard !isSyncing else { return }
        isSyncing = true   // v1.72（#5）：本地刷新同样给出「正在刷新」反馈
        defer { isSyncing = false }
        guard let ctx = houseModelContext else { return }
        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        let active = all.filter { !$0.isTrashed }
        var addedLines: [String] = []
        var missingLines: [String] = []
        var addedCount = 0
        var addedFiles = 0
        await MainActor.run {
            var inserted: [MediaItem] = []
            for house in active {
                // v1.69：目录名强制带前缀（mediaRoomKey），不再做无前缀迁移
                let dir = MediaStore.houseDirectory(roomKey: house.mediaRoomKey)
                let disk = Set(MediaStore.mediaFileNames(in: dir))
                let recorded = Set(house.mediaItems.map { $0.fileName })
                let toAdd = disk.subtracting(recorded)
                let missing = recorded.subtracting(disk)
                if !toAdd.isEmpty {
                    for f in toAdd.sorted() {
                        let lower = f.lowercased()
                        let media = MediaItem(fileName: f, kind: (lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? "video" : "image")
                        media.house = house
                        ctx.insert(media)
                        inserted.append(media)
                        addedFiles += 1
                    }
                    addedCount += 1
                    addedLines.append("\(house.displayRoomNo)：补全 \(toAdd.count) 个媒体")
                }
                if !missing.isEmpty {
                    missingLines.append("\(house.displayRoomNo)：本地缺 \(missing.count) 个文件（云端回补）")
                }
            }
            if !inserted.isEmpty { try? ctx.save() }
            // 未收录目录：media 下有目录但无对应房源
            let keys = MediaStore.scanMediaDirectoryKeys()
            let orphanKeys = keys.filter { key in
                let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
                guard !roomNo.isEmpty else { return true }
                return !active.contains { $0.tower == tower && $0.roomNo == roomNo }
            }
            var lines: [String] = []
            if addedCount > 0 {
                lines.append("媒体补全 \(addedCount) 间（\(addedFiles) 个文件）：")
                lines.append(contentsOf: addedLines)
            }
            if !missingLines.isEmpty {
                lines.append("待云端回补：" + missingLines.joined(separator: "；"))
            }
            if !orphanKeys.isEmpty {
                lines.append("未收录目录 \(orphanKeys.count) 个：\(orphanKeys.prefix(5).joined(separator: "、"))（可去批量录入-扫描补录导入）")
            }
            if lines.isEmpty {
                showToast(RemoteConfig.tip("refreshNoChange", "已刷新，无变化"))
            } else {
                showToast(lines.joined(separator: "\n"))
            }
            // v1.77：下拉刷新（本地刷新）不再重建本地账本镜像——重建只在左上角云端同步后执行
            NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
        }
    }

    /// v1.76：重建/刷新本地账本镜像（media/<房号>/info.json），保证与本地房源记录一致。
    /// v1.77：仅由「左上角云端同步」触发（下拉刷新不再调用）。
    /// v1.78：改为增量——每套与现有账本对比，有差异才写盘，无差异跳过。
    /// v1.79：增量对比改为「语义字段」判断（v1.78 的字节全等对比太脆弱：媒体清单顺序/元数据微变都会
    /// 判为有差异，导致每次同步仍全量重写）。现只对比业务字段 + 排序后的媒体清单，
    /// updatedAt/updatedBy 不参与判断；真正无变化的套数零写入。返回(实际写入套数, 已校验套数)。
    /// 判断「账本是否已是当前状态」：业务字段一致且媒体清单（排序后）一致 → 视为无变化
    private func ledgerIsCurrent(_ h: House, existing: CloudHouseRecord?) -> Bool {
        guard let existing else { return false }
        return existing.roomKey == h.mediaRoomKey
            && existing.roomNo == h.roomNo
            && existing.tower == h.tower
            && existing.landlord == h.landlord
            && existing.layout == h.layout
            && existing.price == h.price
            && existing.password == h.password
            && existing.remark == h.remark
            && existing.status == h.statusRaw
            && existing.mediaNames.sorted() == h.mediaItems.map { $0.fileName }.sorted()
    }

    @discardableResult
    private func rebuildLocalLedgers() -> (written: Int, checked: Int) {
        guard let ctx = houseModelContext else { return (0, 0) }
        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        var written = 0
        var checked = 0
        for h in all where !h.isTrashed {
            checked += 1
            let url = MediaStore.houseDirectory(roomKey: h.mediaRoomKey).appendingPathComponent("info.json")
            let existing = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CloudHouseRecord.self, from: $0) }
            if ledgerIsCurrent(h, existing: existing) {
                continue   // 账本已是最新，跳过写入
            }
            LocalHouseLedger.save(h)
            written += 1
        }
        return (written, checked)
    }

    /// v1.83：同步失败自动重试一次——网络瞬断/弱网（如电梯信号切换）时第一次失败会在 1 秒后自动重跑，
    /// 第二次仍失败才提示。retriedOnce 防止重试套娃无限递归。
    @discardableResult
    /// 服务器模式同步：增量拉取权威库并直接应用到本地（服务器已做合并，无需本地 diff 预览）
    private func runServerSync(context ctx: ModelContext) async -> CloudPullRunOutcome {
        let progressID = syncCenter.beginTransient(kind: .cloudPull, title: "同步房源", total: 1)
        do {
            let changed = try await HouseSyncEngine.shared.pull(context: ctx)
            showToast(changed > 0 ? "已同步 \(changed) 套房源" : "房源已是最新")
            syncCenter.endTransient(id: progressID)
            return .finished
        } catch {
            let msg = "服务器同步失败：\(error.localizedDescription)"
            showToast(msg, isError: true)
            syncCenter.endTransient(id: progressID)
            return .failed(msg)
        }
    }

    private func syncCloudHouses(retriedOnce: Bool = false, retryTaskID: UUID? = nil, deep: Bool = false) async -> CloudPullRunOutcome {
        // v2.63：重入保护——连点/长按两次不再并发跑两份云端同步（并发会重复拉清单、进度互相覆盖）
        guard !isSyncing else { return .failed("正在同步中，请稍候") }
        isSyncing = true   // v1.72（#5）：点击立即反馈「正在刷新」
        isDeepSyncing = deep   // v2.65：长按（deep）显示「正在深度核对…」，普通点按仍是「正在刷新…」
        defer {
            isSyncing = false
            isDeepSyncing = false
        }
        // v2.63：标记「手动云端同步进行中」——自动检测看到这个标记直接跳过，两边不会同时拉清单
        await MainActor.run { CloudDetectActivity.shared.beginManualSync() }
        defer { DispatchQueue.main.async { CloudDetectActivity.shared.endManualSync() } }
        // 服务器模式：房源读写走 8082 house-keeper 权威接口，短路旧 COS 直连链路
        if HouseServerMode.ready, let ctx = houseModelContext {
            return await runServerSync(context: ctx)
        }
        let config = CosConfig.load()
        guard let config else {
            let message = RemoteConfig.tip("noCloudConfig", "未配置云存储，无法同步云端房源")
            showToast(message, isError: true)
            return .failed(message)
        }
        guard let ctx = houseModelContext else {
            return .failed("房源数据未就绪，请重新进入房源页再试")
        }
        // 总刷新只显示顶部临时进度条，**不写任务中心**（用户明确：点一次一条太占地方）
        let progressID = syncCenter.beginTransient(kind: .cloudPull, title: "同步云端房源", total: 1)
        do {
            // v2.62（B3）：先把积压的清单改动补写，保证后面「按清单跳过」可信
            await CloudManifestUpdater.shared.flush()
            // v2.62（B1）：主线程读 SwiftData 生成纯值摘要，后台只做网络与比对
            let locals: [String: LocalHouseSummary] = await MainActor.run {
                let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                var out: [String: LocalHouseSummary] = [:]
                for h in local where !h.isTrashed {
                    // 待上传队列里的媒体还没传完，不算「本地已有」——与检测侧同一口径，避免每刷都判 suspect
                    let pending = Self.exemptPendingKeys(roomKey: h.mediaRoomKey)
                    out[h.mediaRoomKey] = LocalHouseSummary(
                        roomKey: h.mediaRoomKey, roomNo: h.roomNo, tower: h.tower,
                        landlord: h.landlord, layout: h.layout, price: h.price,
                        password: h.password, remark: h.remark, statusRaw: h.statusRaw,
                        mediaKeys: Set(h.mediaItems.map { Self.mediaNormKey($0.fileName) }).subtracting(pending)
                    )
                }
                return out
            }
            // v2.62（B1~B8）：增量拉取——只有清单判「有变化」和本地没有的房才拉 info.json
            let fetched = try await CloudHouseSync.fetchIncremental(
                config: config, locals: locals, seen: CloudRevisionStore.all(), deep: deep)
            let recs = fetched.records
            // v1.80：云端同步成功 → 顺带拉取远程配置（公告/文案/开关/参数），失败不影响同步
            Task { await RemoteConfig.refresh() }
            // v1.40 第11点：先算 diff 弹确认，确认后才应用（此前直接执行后才弹结果，用户无法拦截误覆盖）
            // v1.42：新增/更新/删除/补传/媒体差异全部带具体房号（用户要求：只要对比有差别就列出房号）
            var added: [(roomNo: String, roomKey: String, mediaNames: [String])] = []
            var updated: [(roomNo: String, byUser: String)] = []
            var deleted: [(roomKey: String, roomNo: String)] = []
            var pushed: [(roomKey: String, roomNo: String)] = []
            // v2.58（#5）：媒体差异候选先收集，之后对 24h 宽限期内、确实要下载的记录做一次
            // 「桶里是否真存在」校验：账本有、桶里没有的引用从差异里静音（不弹框、不下载，只记日志）。
            var mediaCandidates: [(roomKey: String, roomNo: String, rec: CloudHouseRecord,
                                   localNorm: Set<String>, diskNorm: Set<String>,
                                   needDownload: Bool, needRemove: Bool)] = []
            var mediaRoomKeys: [(roomKey: String, roomNo: String)] = []
            await MainActor.run {
                pendingSyncMediaDiff = []   // v1.43：每次同步前重置媒体差异收集
                let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                var localByKey: [String: House] = [:]
                for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
                // v2.62（B1）：云端权威房号集合来自目录列举（不是本次拉明细的集合）
                let cloudKeys = fetched.cloudKeys
                for rec in recs {
                    if let h = localByKey[rec.roomKey] {
                        if Self.cloudRecordDiffers(rec, from: h) != nil {
                            // v1.40 B1：多人冲突提示——云端由他人更新时展示修改者
                            // v1.69：房号一律真实引用带前缀（rec.roomKey），不做去前缀简化
                            updated.append((rec.roomKey, rec.updatedBy))
                        }
                        // v1.43：媒体差异三名单对账（账本 / 本地记录 / 磁盘真实文件），归一化等价比较：
                        //   - 账本有、本地记录或磁盘缺 → 需要下载（含用户手删 media 文件后刷新刷回）
                        //   - 本地记录或磁盘有、账本没有 → 需要跟随删除（多余/旧残留收敛）
                        //   - 视频 .mov/.mp4 视为同一文件（去扩展名比较），消除两套名字互斥导致的循环
                        let exempt = Self.exemptPendingKeys(roomKey: h.mediaRoomKey)
                        let localNorm = Set(h.mediaItems.map { Self.mediaNormKey($0.fileName) }).subtracting(exempt)
                        let cloudNorm = Set(rec.mediaNames.map { Self.mediaNormKey($0) })
                        let diskNorm = Set(MediaStore.existingFileNames(roomKey: h.mediaRoomKey).map { Self.mediaNormKey($0) }).subtracting(exempt)
                        let needDownload = !cloudNorm.isSubset(of: localNorm) || !cloudNorm.isSubset(of: diskNorm)
                        let needRemove = !localNorm.isSubset(of: cloudNorm) || !diskNorm.isSubset(of: cloudNorm)
                        if needDownload || needRemove {
                            mediaCandidates.append((h.mediaRoomKey, h.displayRoomNo, rec,
                                                    localNorm, diskNorm, needDownload, needRemove))
                        }
                    } else {
                        // v1.69：新增列表与媒体差异的房号一律带前缀真实引用
                        added.append((rec.roomKey, rec.roomKey, rec.mediaNames))
                        if !rec.mediaNames.isEmpty {
                            // 新房：本地无记录/无磁盘文件，媒体全从云端下载
                            mediaCandidates.append((rec.roomKey, rec.roomKey, rec, [], [], true, false))
                        }
                    }
                }
                for (key, h) in localByKey where !cloudKeys.contains(key) {
                    // v1.71（方案 A）：云端账本为空（首次同步/云端被清空）时一律走「本地→云端」补传，
                    // 不判定「云端已删」——否则本地双端房会被误判为云端已删而提示删本地（v1.42 事故模式）。
                    // v2.62：判空必须用权威云端房号集合（cloudKeys），不能用 recs（recs 只含需明细的房，
                    // 无变化时为空，会把真实删除误判成补传）。
                    if !cloudKeys.isEmpty && (h.cloudStatus == .both || h.cloudStatus == .cloud) {
                        deleted.append((key, h.displayRoomNo))
                    } else {
                        pushed.append((key, h.displayRoomNo))
                    }
                }
            }
            // v2.58（#5）：宽限期内静音「账本引用但桶里不存在」的媒体
            var finalMediaDiffs: [(roomNo: String, missing: Bool)] = []
            for c in mediaCandidates {
                var needDownload = c.needDownload
                if needDownload, Date().timeIntervalSince(c.rec.updatedAt) < 24 * 3600 {
                    do {
                        let missing = try await CloudHouseSync.missingLedgerMedia(
                            roomKey: c.roomKey, expectedNames: c.rec.mediaNames, config: config)
                        if !missing.isEmpty {
                            let cloudNorm = Set(c.rec.mediaNames.map { Self.mediaNormKey($0) })
                            let missingNorm = Set(missing.map { Self.mediaNormKey($0) })
                            let effectiveCloud = cloudNorm.subtracting(missingNorm)
                            needDownload = !effectiveCloud.isSubset(of: c.localNorm)
                                || !effectiveCloud.isSubset(of: c.diskNorm)
                            BackupLogStore.log(category: "同步", action: "宽限期静音桶内缺失媒体", result: "跳过",
                                               detail: "\(c.roomKey)：账本引用但桶里不存在的 \(missing.count) 个文件（\(missing.prefix(3).joined(separator: "、"))），24 小时内不提示、不下载；等另一台设备补传成功后自动恢复",
                                               room: c.roomKey, cloud: false)
                        }
                    } catch {
                        // 列桶失败（网络/权限）：保持原差异，绝不把网络失败当成「桶里不存在」
                    }
                }
                if needDownload || c.needRemove {
                    mediaRoomKeys.append((c.roomKey, c.roomNo))
                    finalMediaDiffs.append((c.roomNo, needDownload))
                }
            }
            await MainActor.run {
                pendingSyncMediaDiff = finalMediaDiffs
            }
            let hasChange = !added.isEmpty || !updated.isEmpty || !deleted.isEmpty || !pushed.isEmpty || !mediaRoomKeys.isEmpty
            guard hasChange else {
                // v1.65：账本无变化时做「云端媒体对账」——本地有媒体但云端 h/<房号>/ 缺对象 → 补齐媒体。
                // v1.68：改为先「干跑」列桶比对（只查不传），得出待补列表 → 弹确认框，确认后才开始上传。
                // 不再静默后台跑（用户看不到过程以为没反应）；上传过程走全局同步任务中心：
                // 房源页顶部进度条 + 可最小化收起到「设置 → 待补传媒体」随时查看进度。
                // v2.62（B5）：媒体对账也要列整桶（最慢的一段），日常刷新不再每次都跑——
                // 只在「本次走全量」或「距上次对账 ≥ 24 小时」时做一次；其余情况靠上传失败进任务中心兜底。
                let lastMediaAudit = UserDefaults.standard.double(forKey: "cloudMediaAuditLastAt")
                let auditDue = fetched.usedFullScan
                    || lastMediaAudit <= 0
                    || Date().timeIntervalSince1970 - lastMediaAudit >= 24 * 3600
                let pending: [PendingMediaHouseSnapshot]
                if auditDue {
                    pending = await preflightMediaSnapshots(config: config, ctx: ctx)
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cloudMediaAuditLastAt")
                } else {
                    pending = []
                }
                if pending.isEmpty {
                    // v1.77：无变化也同步本地账本镜像；v1.78：增量写，只报实际写入套数
                    let ledger = rebuildLocalLedgers()
                    if ledger.written > 0 {
                        showToast(RemoteConfig.tip("refreshNoChangeLedger", "已刷新，无变化\n本地账本已同步 {n} 套").replacingOccurrences(of: "{n}", with: String(ledger.written)))
                        BackupLogStore.log(category: "同步", action: "云端同步完成", result: "成功", detail: "无变化；本地数据刷新 \(ledger.written) 套", cloud: false)
                    } else {
                        showToast(RemoteConfig.tip("refreshNoChange", "已刷新，无变化"))
                    }
                    // 已同步成功：云端更新提示自动收起（不用用户再手动关）
                    cloudUpdateBannerVisible = false
                    // v2.55（恢复 v2.47 口径，修复进板块反复误报）：无变化也要回写修订号基线，
                    // 让下次进板块的增量检测基线与云端对齐，不再因基线错位而每次误报「检测到云端有更新」
                    // v2.62：基线来自本次清单（增量时不必再拉一遍所有明细）
                    CloudRevisionStore.remember(fetched.revisions)
                    syncCenter.endTransient(id: progressID)
                    return .finished
                }
                pendingMediaSnaps = pending
                pendingMediaSyncRetryTaskID = retryTaskID
                showMediaSyncConfirm = true
                // 等用户确认，真正上传在确认后另建任务：这里先收掉临时进度
                syncCenter.endTransient(id: progressID)
                return retryTaskID == nil ? .finished : .needsConfirmation
            }
            pendingSyncRecs = recs
            // v2.62（B1）：执行侧必须用「云端权威房号集合」判断云端是否存在，
            // 不能用 recs（recs 只含本次需要明细的房）——否则未变化的房会被当成「云端已删」。
            pendingSyncCloudKeys = fetched.cloudKeys
            pendingSyncAdded = added
            pendingSyncUpdated = updated
            pendingSyncDeleted = deleted
            pendingSyncPushed = pushed
            // v2.58（#3）：这次同步若来自任务中心重试，记下任务 id——确认框点「确认同步」
            // 执行完才结算成功，点「取消」直接丢弃任务；不能在这里提前报成功
            pendingSyncRetryTaskID = retryTaskID
            showSyncConfirm = true
            // 等用户确认后由 applySyncPreview 执行：这里先收掉临时进度
            syncCenter.endTransient(id: progressID)
            return .needsConfirmation
        } catch {
            syncCenter.endTransient(id: progressID)
            // 回到 b174 规则：失败自动重试 1 次（弱网瞬断常见），第二次仍失败才提示
            if !retriedOnce {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return await syncCloudHouses(retriedOnce: true, retryTaskID: retryTaskID, deep: deep)
            }
            let message = "云端同步没完成：\(error.localizedDescription)，点重试重跑整次同步"
            showToast("网络断开，待网络恢复后重试", isError: true)
            BackupLogStore.log(category: "同步", action: "云端同步", result: "失败", detail: error.localizedDescription, cloud: false)
            // v2.58（#3）：预览阶段失败也挂任务，不再只弹一条 toast 就结束；
            // 任务中心重试进来的这次由 retry(id:) 按返回值结算原任务，不重复建任务
            if retryTaskID == nil {
                syncCenter.reportFailure(kind: .cloudPull, title: "从云端拉下来",
                                         roomKeys: [], failure: message)
            }
            return .failed(message)
        }
    }

    /// v1.67：在主线程把 House 的可跨线程数据提取成值快照（后台线程安全）
    private func makePendingSnapshot(from h: House) -> PendingMediaHouseSnapshot {
        let files = h.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
        let profile = CosUploader.loadShareProfile()
        let info = ShareHouseInfo(
            displayRoomNo: h.displayRoomNo, towerLabel: h.towerLabel,
            layout: h.layout, statusLabel: h.status.label, priceText: h.priceText,
            landlord: h.landlord, password: h.password, remark: h.remark,
            name: profile.name, phone: profile.phone
        )
        return PendingMediaHouseSnapshot(roomKey: h.mediaRoomKey, displayRoomNo: h.displayRoomNo, files: files, info: info)
    }

    /// v1.68：云端媒体对账「干跑」——只列桶比对，不传任何东西，返回「云端缺媒体」的房源快照列表。
    /// 供同步无变化时弹确认框前预检；列桶失败视为待补（确认后可重试，不丢数据）。
    /// v1.83：一次递归列桶替代逐房号串行列桶——房源多时不再每次刷新发起 N 次 COS 请求。
    /// 整桶 h/ 平铺拉回（自动分页），按房号前缀分组比对；仅命中差异的房号进入待补列表。
    private func preflightMediaSnapshots(config: CosConfig, ctx: ModelContext) async -> [PendingMediaHouseSnapshot] {
        var snapshots: [PendingMediaHouseSnapshot] = []
        await MainActor.run {
            let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
            snapshots = local.filter { !$0.isTrashed && $0.cloudStatus != .cloud && !$0.mediaItems.isEmpty }.map { makePendingSnapshot(from: $0) }
        }
        guard !snapshots.isEmpty else { return [] }
        // 一次列桶拉回 h/ 全部对象（自动分页），按「h/<房号>/」前缀归组
        var cloudByRoom: [String: Set<String>] = [:]
        do {
            let objs = try await CosUploader.listObjects(prefix: "h/", config: config)
            let prefixLen = "h/".count
            for obj in objs {
                var name = obj.name
                guard name.hasPrefix("h/") else { continue }
                name.removeFirst(prefixLen)
                // 只处理 h/<房号>/ 下的对象（目录子项/根散文件跳过）
                guard let slash = name.firstIndex(of: "/") else { continue }
                let roomKey = String(name[..<slash])
                guard !roomKey.isEmpty, !roomKey.hasPrefix("_") else { continue }
                let file = String(name[name.index(after: slash)...])
                guard !file.isEmpty else { continue }
                cloudByRoom[roomKey, default: []].insert(Self.mediaNormKey(file))
            }
        } catch {
            // 整桶列桶失败（网络/限流）：退回逐房号列桶（原逻辑），仍失败则视为待补（不丢数据）
            var pending: [PendingMediaHouseSnapshot] = []
            for snap in snapshots {
                do {
                    let objs = try await CosUploader.listObjects(prefix: "h/\(snap.roomKey)/", config: config)
                    let cloudNames = Set(objs.map { Self.mediaNormKey(($0.name as NSString).lastPathComponent) })
                    let localNames = Set(snap.files.map { Self.mediaNormKey($0.name) })
                    if !localNames.isSubset(of: cloudNames) { pending.append(snap) }
                } catch {
                    pending.append(snap)
                }
            }
            return pending
        }
        var pending: [PendingMediaHouseSnapshot] = []
        for snap in snapshots {
            let cloudNames = cloudByRoom[snap.roomKey] ?? []
            let localNames = Set(snap.files.map { Self.mediaNormKey($0.name) })
            if !localNames.isSubset(of: cloudNames) { pending.append(snap) }
        }
        return pending
    }

    /// v1.68：按确认后的快照列表执行媒体补传，走全局同步任务中心（进度条 / 最小化 / 待补传页可见）。
    /// 幂等覆盖+刷新分享页（与批量导入同机制）；失败保留在补传队列，下次刷新对账再补。
    private func runMediaUpload(snaps: [PendingMediaHouseSnapshot], config: CosConfig?, ctx: ModelContext?, cloudPullTaskID: UUID? = nil) async {
        guard !snaps.isEmpty, let config else {
            if let cloudPullTaskID {
                syncCenter.finish(id: cloudPullTaskID, success: false, failure: "云存储配置未就绪，请重新同步")
            }
            return
        }
        await MediaActivityGate.shared.beginUpload()
        defer { Task { await MediaActivityGate.shared.endUpload() } }
        let total = snaps.reduce(0) { $0 + $1.files.count }
        let taskID = syncCenter.begin(kind: .media, title: "补齐云端媒体",
                                     roomKeys: snaps.map { $0.displayRoomNo }, total: total)
        var uploaded: [String] = []
        var failed: [String] = []
        var done = 0
        for snap in snaps {
            syncCenter.advance(id: taskID, done: done, note: "正在处理 \(snap.displayRoomNo)")
            let fileCount = snap.files.count
            do {
                _ = try await CosUploader.autoRegenerateMaskedShare(mediaFiles: snap.files, roomKey: snap.roomKey, info: snap.info, config: config)
                uploaded.append(snap.displayRoomNo)
                // v2.45：补齐云端媒体写账本；v2.62：只记数量，不拼文件名
                let fillSplit = HouseLedgerFormat.split(snap.files.map { (name: $0.name, kind: $0.kind) })
                HouseLedgerStore.append(
                    roomKey: snap.roomKey,
                    action: "补齐云端媒体",
                    detail: HouseLedgerFormat.mediaParts(images: fillSplit.images, videos: fillSplit.videos, includeNames: false).joined(separator: "；"))
            } catch {
                failed.append(snap.displayRoomNo)
            }
            done += fileCount
            syncCenter.advance(id: taskID, done: done)
        }
        if failed.isEmpty {
            syncCenter.finish(id: taskID, success: true, note: "已补齐 \(uploaded.count) 套")
        } else {
            // 失败挂任务中心，手动点重试；不自动跑
            syncCenter.finish(id: taskID, success: false,
                             failure: "这几套媒体没传上：\(failed.joined(separator: "、"))，点重试")
        }
        var lines: [String] = []
        if !uploaded.isEmpty { lines.append("已补齐云端媒体 \(uploaded.count) 套：" + uploaded.joined(separator: "，")) }
        if !failed.isEmpty { lines.append("补传失败（可稍后再刷新重试）：" + failed.joined(separator: "，")) }
        showToast(lines.isEmpty ? "没有需要补传的媒体" : lines.joined(separator: "\n"))
        // v2.44：媒体补传结果系统通知
        if !failed.isEmpty {
            let failedFiles = snaps.filter { failed.contains($0.displayRoomNo) }.reduce(0) { $0 + $1.files.count }
            HouseActionNotifier.shared.send(
                key: "media.fill",
                title: "媒体补传未完成",
                body: "还剩 \(failedFiles) 个没传上，已挂任务中心，可手动重试",
                silent: true
            )
        } else if total > 0 {
            HouseActionNotifier.shared.send(
                key: "media.fill",
                title: "媒体补传完成",
                body: "\(snaps.count) 套房、\(total) 个媒体已全部传完"
            )
        }
        if !uploaded.isEmpty {
            // v2.16：补齐云端媒体属于云端侧动作，只写云端日志区，本机区不再出现
            CloudOps.log(category: "同步", action: "补齐云端媒体（本地→云端）", result: "成功", detail: "已补齐 \(uploaded.count) 套：" + uploaded.joined(separator: "，"))
        }
        if !failed.isEmpty {
            CloudOps.log(category: "同步", action: "补齐云端媒体（本地→云端）", result: "失败", detail: "补齐失败：" + failed.joined(separator: "，"))
        }
        // v2.58（#3）：由 cloudPull 重试进入的媒体补齐，按真实结果结算原任务（不提前报成功）
        if let cloudPullTaskID {
            if failed.isEmpty {
                syncCenter.finish(id: cloudPullTaskID, success: true, note: "媒体已补齐，同步完成")
            } else {
                syncCenter.finish(id: cloudPullTaskID, success: false,
                                  failure: "云端同步没完成：\(failed.count) 套媒体没补齐，点重试")
            }
        }
    }

    /// v1.68：媒体对账确认框详情——列出每套缺几个媒体
    private func mediaSyncConfirmSummary() -> String {
        guard !pendingMediaSnaps.isEmpty else { return "" }
        var lines = ["云端缺失媒体 \(pendingMediaSnaps.count) 套，确认后开始补齐："]
        lines += pendingMediaSnaps.map { "\($0.displayRoomNo)（缺 \($0.files.count) 个媒体）" }
        return lines.joined(separator: "\n")
    }

    /// v1.40 第11点：确认弹窗里的变化详情
    /// v1.42：所有差异（新增/更新/云端已删/本地补传/媒体差异）一律列出具体房号
    private func syncChangeSummary() -> String {
        var parts: [String] = []
        if !pendingSyncAdded.isEmpty { parts.append("新增\(pendingSyncAdded.count)套：\(pendingSyncAdded.map { $0.roomNo }.prefix(8).joined(separator: "，"))") }
        if !pendingSyncUpdated.isEmpty {
            let upd = pendingSyncUpdated.prefix(8).map { "\($0.roomNo)（\($0.byUser.isEmpty ? "他人" : $0.byUser)改）" }.joined(separator: "，")
            parts.append("更新\(pendingSyncUpdated.count)套：\(upd)")
        }
        if !pendingSyncDeleted.isEmpty { parts.append("云端已删\(pendingSyncDeleted.count)套：\(pendingSyncDeleted.map { $0.roomNo }.prefix(8).joined(separator: "，"))，本地跟随删除") }
        if !pendingSyncPushed.isEmpty { parts.append("本地新增\(pendingSyncPushed.count)套将补传云端：\(pendingSyncPushed.map { $0.roomNo }.prefix(8).joined(separator: "，"))") }
        // v1.43：媒体差异独立列出房号，并标注「缺（将从云端补齐）」与「多（将跟随删除）」，不重复计入更新数
        if !pendingSyncMediaDiff.isEmpty {
            let missing = Set(pendingSyncMediaDiff.filter { $0.missing }.map { $0.roomNo })
            let extra = Set(pendingSyncMediaDiff.filter { !$0.missing }.map { $0.roomNo })
            var mediaParts: [String] = []
            if !missing.isEmpty { mediaParts.append("本地缺媒体将从云端补齐：\(Array(missing).prefix(8).joined(separator: "，"))") }
            if !extra.isEmpty { mediaParts.append("本地多余媒体将跟随删除：\(Array(extra).prefix(8).joined(separator: "，"))") }
            parts.append(contentsOf: mediaParts)
        }
        return parts.joined(separator: "\n") + "\n\n确认后才会同步；取消则本次不动任何数据。"
    }

    /// v1.40 第11点：确认后应用同步（原执行逻辑）
    /// v1.41：更新判定改字段级对比；新增媒体 reconcile——跟随云端删除本地多余媒体（账本已删、本地残留）
    private func applySyncPreview(retryTaskID: UUID? = nil) async {
        guard let config = CosConfig.load(), let ctx = houseModelContext else {
            if let retryTaskID {
                syncCenter.finish(id: retryTaskID, success: false,
                                  failure: "云存储配置或房源数据未就绪，请到房源页重新同步")
            }
            return
        }
        let recs = pendingSyncRecs
        // v2.62（B1）：recs 只含需要明细的房，不能再用它判「云端是否为空」。
        // 空集保护改用权威云端房号集合——云端真的没有房源时仍然阻止同步，保护本地数据。
        guard !pendingSyncCloudKeys.isEmpty else {
            showToast("云端账本为空，已停止本次同步以保护本地数据", isError: true)
            BackupLogStore.log(category: "同步", action: "云端同步", result: "失败",
                              detail: "云端账本返回空集，已阻止空集同步", cloud: false)
            if let retryTaskID {
                syncCenter.finish(id: retryTaskID, success: false,
                                  failure: "云端账本为空，已停止同步以保护本地数据")
            }
            return
        }
        // 总同步只显示顶部临时进度条，不写任务中心（成功/失败都不记录）
        let applyID = syncCenter.beginTransient(kind: .cloudPull, title: "同步云端房源",
                                               total: max(1, recs.count))
        do {
            var addedCount = 0, updatedCount = 0, deletedCount = 0, pushedCount = 0
            var removedMediaCount = 0
            var unreadRoomKeys: [String] = []   // v2.20：本次同步新增/被云端覆盖的房源，标红待看
            var addedRoomNo: [String] = []
            var updatedRoomNo: [String] = []
            var deletedRoomNo: [String] = []
            var pushedRoomNo: [String] = []
            var pushedRecords: [CloudHouseRecord] = []   // v1.64：补传聚合
            var pushedMediaHouses: [PendingMediaHouseSnapshot] = []   // v1.67：补传后需上传媒体的快照（主线程提取，后台只传值）
            var mediaDiffRoomNo: [String] = []
            var mediaRoomKeys: [(roomKey: String, roomNo: String)] = []   // v1.42：带房号
            var conflictRoomNo: [String] = []   // v2.36（#7）：本地有未同步改动、跳过云端覆盖的房号
            await MainActor.run {
                let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                var localByKey: [String: House] = [:]
                for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
                // v2.62（B1）：云端权威房号集合（目录列举结果），不是本次拉明细的集合
                let cloudKeys = pendingSyncCloudKeys
                // v2.37（#2/#35）：还在待上传队列里（等待/正在补传）的文件一律豁免——
                // 按房间收集其规范键，下面动手删时名单内的不删、也不清排队任务，等它传完离开队列，下次同步再处理。
                var exemptByRoom: [String: Set<String>] = [:]
                for q in HouseMediaUploadQueue.pendingItems() {
                    exemptByRoom[q.roomKey, default: []].insert(Self.mediaNormKey(q.fileName))
                }
                for rec in recs {
                    if let h = localByKey[rec.roomKey] {
                        // v2.36（#7）：本地有未同步成功的改动（SyncFail 标记），说明本地与云端已分叉。
                        // 跳过云端覆盖整段（含媒体对账），保留本地改动，避免把用户本地修改冲掉。
                        if SyncFailStore.isFailed(rec.roomKey) {
                            conflictRoomNo.append(h.displayRoomNo)
                            continue
                        }
                        // v2.36（#33）：执行侧与预览侧用同一份计划——只覆盖预览判定为「更新」的房源
                        if let diff = Self.cloudRecordDiffers(rec, from: h),
                           pendingSyncUpdated.contains(where: { $0.roomNo == rec.roomKey }) {
                            // b116：记录具体差异，定位 1-711 这类死循环根因
                            BackupLogStore.log(category: "同步", action: "云端更新本机", result: "成功",
                                               detail: "\(rec.roomKey) 按云端更新：\(diff)", cloud: false)
                            h.roomNo = rec.roomNo; h.tower = rec.tower; h.landlord = rec.landlord
                            h.layout = rec.layout; h.price = rec.price; h.password = rec.password
                            h.remark = rec.remark; h.statusRaw = rec.status
                            h.lastUpdatedAt = rec.updatedAt
                            updatedCount += 1
                            updatedRoomNo.append(rec.roomKey)   // v1.69：带前缀真实引用
                            unreadRoomKeys.append(h.mediaRoomKey)   // v2.20：被云端覆盖 → 标红
                            LocalHouseLedger.save(h)   // v1.72（#6）：本地一房一账本镜像随更新同步
                        }
                        // v1.43：媒体差异双向 reconcile（归一化等价，.mov/.mp4 视为同一文件）——
                        //  ① 账本有、本地记录或磁盘缺 → 下载（mediaRoomKeys；含用户手删文件后刷回）
                        //  ② 本地记录有、账本已无 → 跟随删除（文件 + 记录）
                        //  ③ 磁盘上有、账本已无的孤儿残留（旧首帧图/分享页等）→ 只删文件
                        let exempt = exemptByRoom[h.mediaRoomKey] ?? []
                        let cloudNorm = Set(rec.mediaNames.map { Self.mediaNormKey($0) })
                        let localNorm = Set(h.mediaItems.map { Self.mediaNormKey($0.fileName) }).subtracting(exempt)
                        let diskNorm = Set(MediaStore.existingFileNames(roomKey: h.mediaRoomKey).map { Self.mediaNormKey($0) }).subtracting(exempt)
                        let needDownload = !cloudNorm.isSubset(of: localNorm) || !cloudNorm.isSubset(of: diskNorm)
                        let needRemove = !localNorm.isSubset(of: cloudNorm) || !diskNorm.isSubset(of: cloudNorm)
                        if needDownload {
                            mediaRoomKeys.append((h.mediaRoomKey, h.displayRoomNo))
                            mediaDiffRoomNo.append(h.displayRoomNo)
                        }
                        // v2.23：媒体有增删（云端换图/删视频）也算「有变化」，一并标红待看
                        if needDownload || needRemove {
                            unreadRoomKeys.append(h.mediaRoomKey)
                        }
                        if needRemove {
                            let exempt = exemptByRoom[h.mediaRoomKey] ?? []
                            for item in Array(h.mediaItems) where !cloudNorm.contains(Self.mediaNormKey(item.fileName)) {
                                // v2.37（#2/#35）：待上传豁免——名单内不删、不清队列，传完下次再处理
                                if exempt.contains(Self.mediaNormKey(item.fileName)) { continue }
                                MediaStore.delete(fileName: item.fileName, roomKey: h.mediaRoomKey)
                                ctx.delete(item)
                                HouseMediaUploadQueue.remove(roomKey: h.mediaRoomKey, fileName: item.fileName)
                                removedMediaCount += 1
                            }
                            for dname in MediaStore.existingFileNames(roomKey: h.mediaRoomKey) where !cloudNorm.contains(Self.mediaNormKey(dname)) {
                                // 待上传豁免：磁盘上的排队文件同样保留
                                if exempt.contains(Self.mediaNormKey(dname)) { continue }
                                MediaStore.delete(fileName: dname, roomKey: h.mediaRoomKey)
                                removedMediaCount += 1
                            }
                        }
                        h.cloudStatus = .both
                    } else if pendingSyncAdded.contains(where: { $0.roomKey == rec.roomKey }) {
                        // v2.36（#33）：只新增预览判定为「新增」的房源
                        let h = House(
                            roomNo: rec.roomNo, tower: rec.tower, landlord: rec.landlord,
                            layout: rec.layout, price: rec.price, password: rec.password,
                            remark: rec.remark, status: HouseStatus(rawValue: rec.status) ?? .available
                        )
                        h.lastUpdatedAt = rec.updatedAt
                        h.cloudStatus = .cloud
                        ctx.insert(h)
                        LocalHouseLedger.save(h)   // v1.72（#6）：本地一房一账本镜像
                        addedCount += 1
                        addedRoomNo.append(rec.roomKey)   // v1.69：带前缀真实引用
                        unreadRoomKeys.append(h.mediaRoomKey)   // v2.20：新增 → 标红
                        if !rec.mediaNames.isEmpty {
                            mediaRoomKeys.append((h.mediaRoomKey, rec.roomKey))
                            mediaDiffRoomNo.append(rec.roomKey)
                        }
                    }
                }
                for (key, h) in localByKey where !cloudKeys.contains(key) {
                    // v2.36（#33）：执行侧只处理预览计划里的「删除/补传」，计划外的一律跳过，不再凭 cloudStatus 临时推导
                    let inDeleted = pendingSyncDeleted.contains(where: { $0.roomKey == key })
                    let inPushed = pendingSyncPushed.contains(where: { $0.roomKey == key })
                    if inDeleted, h.cloudStatus == .both || h.cloudStatus == .cloud {
                        MediaStore.deleteHouseDirectory(roomKey: key)
                        SyncFailStore.clear(key)
                        UnreadCloudHouseStore.clear(key)
                        // v2.57（P1-5）：队列残留一并清，防待传任务把已删的房又传回云端（幽灵任务）
                        HouseMediaUploadQueue.removeRoom(key)
                        ctx.delete(h)
                        deletedCount += 1
                        deletedRoomNo.append(h.displayRoomNo)
                    } else if inPushed {
                        // v1.64：不再逐个并发 pushHouseToCloud（并发读改写同一账本文件会互相覆盖、
                        // 云端丢失房源）——先收集，同步完成后一次性聚合写回云端账本
                        pushedRecords.append(CloudHouseSync.record(from: h, username: CloudUser.username))
                        pushedCount += 1
                        pushedRoomNo.append(h.displayRoomNo)
                    }
                }
                try? ctx.save()
                reloadHouses()
                UnreadCloudHouseStore.mark(unreadRoomKeys)   // v2.20：同步新增/修改的房源标红，点开详情后消失
            }
            // v2.36（#7）：被跳过的冲突房源提示给用户，明确这些房没有被云端覆盖
            if !conflictRoomNo.isEmpty {
                await MainActor.run {
                    showToast("本机有未同步的修改，已保留：\(conflictRoomNo.joined(separator: "，"))", isError: true)
                }
                BackupLogStore.log(category: "同步", action: "保留本机修改", result: "成功",
                                  detail: "本机未同步的修改已保留：\(conflictRoomNo.joined(separator: "，"))", cloud: false)
            }
            // v1.64：本地补传聚合为一次全量账本写入（串行）——此前 7 个异步 Task 并发对 h/_houses.json
            // 做「读改写」，最后一次写回会覆盖其他并发任务的结果，导致云端只剩最后一条（实测只剩 2309）。
            // 聚合写 + 成功后统一把补传房源标「双端」，失败保持「仅本地」并提示，可下次重试。
            if !pushedRecords.isEmpty {
                do {
                    // v1.72（#8）：补传账本也显示卡片进度条（本地→云端同步动作）；v2.4：begin/end 计数
                    if let first = pushedRecords.first {
                        HouseSyncProgress.shared.begin(roomKey: first.roomKey, direction: .upload, progress: 0.1, label: "补传账本")
                    }
                    // v2.7（P1⑪ 补传合并写）：逐套 uploadGuarded 合并写——
                    // 此前 uploadRecords 全量覆盖写，若另一用户刚在云端加了同号房（带媒体），
                    // 本地空媒体名单会覆盖云端媒体名单，把云端媒体删掉。
                    // uploadGuarded 写前先读云端 info.json，合并 mediaNames = 云端∪本地−本次删除，
                    // revision+1，避免覆盖他人数据。
                    for rec in pushedRecords {
                        _ = try await CloudHouseSync.uploadGuarded(record: rec, config: config)
                    }
                    HouseSyncProgress.shared.end()
                    await MainActor.run {
                        let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                        var snapshots: [PendingMediaHouseSnapshot] = []
                        for h in local where !h.isTrashed && pushedRecords.contains(where: { $0.roomKey == h.mediaRoomKey }) {
                            h.cloudStatus = .both
                            LocalHouseLedger.save(h)   // v1.72（#6）：本地一房一账本镜像
                            if !h.mediaItems.isEmpty {
                                snapshots.append(makePendingSnapshot(from: h))
                            }
                        }
                        pushedMediaHouses = snapshots
                        try? ctx.save()
                        reloadHouses()
                    }
                    // v1.65：补传账本后同步上传本地媒体（幂等覆盖+刷新分享页，与批量导入同机制）。
                    // 此前同步只写账本不传媒体，恢复/导入后媒体永远上不了云，「双端」名不副实；
                    // 上传失败的媒体下次「已刷新无变化」会走云端媒体对账再补。
                    // v1.67：只用主线程提取的值快照，后台不再访问 SwiftData 模型。
                    // v1.68：上传纳入全局同步任务中心（房源页进度条 + 可最小化到待补传媒体页查看）。
                    if !pushedMediaHouses.isEmpty {
                        Task { await runMediaUpload(snaps: pushedMediaHouses, config: config, ctx: ctx) }
                    }
                    BackupLogStore.log(category: "同步", action: "补传房源（本地→云端）", result: "成功", detail: pushedRoomNo.joined(separator: "，"), cloud: false)
                } catch {
                    HouseSyncProgress.shared.end()   // v2.4：失败也归还计数，避免进度条残留
                    await MainActor.run {
                        showToast(RemoteConfig.tip("backfillFail", "补传云端失败：{error}。本地房源保持「仅本地」，可稍后重新同步补传").replacingOccurrences(of: "{error}", with: error.localizedDescription), isError: true)
                    }
                    BackupLogStore.log(category: "同步", action: "补传房源（本地→云端）", result: "失败", detail: error.localizedDescription, cloud: false)
                }
            }
            var mediaSaved = 0
            if !mediaRoomKeys.isEmpty {
                for (idx, roomKeyInfo) in mediaRoomKeys.enumerated() {
                    let (roomKey, _) = roomKeyInfo
                    // 总进度条推进到当前房号（临时进度，不进任务中心）
                    syncCenter.advanceTransient(id: applyID, done: idx, total: max(1, mediaRoomKeys.count),
                                                note: "正在处理 \(roomKey)")
                    // v1.42：同步下载进度 → 卡片底部进度条（云端 → 本机）
                    HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: 0)
                    // v1.43：只下载云端账本名单（expectedNames）内的媒体，落盘名与账本一致 →
                    // 同步完成后本地记录/磁盘 = 账本名单，下次同步零差异（根治「下载N删N」循环）
                    guard let rec = recs.first(where: { $0.roomKey == roomKey }) else {
                        HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: 1)
                        continue
                    }
                    let recordAge = Date().timeIntervalSince(rec.updatedAt)
                    // v2.58（#5）：24h 宽限期内先剔除「账本引用但桶里不存在」的名字——
                    // 只按真实存在的对象下载，不再对必然失败的名字发请求；只记日志，不弹框、不剔除账本。
                    var expectedNames = rec.mediaNames
                    if recordAge < 24 * 3600 {
                        do {
                            let missing = try await CloudHouseSync.missingLedgerMedia(
                                roomKey: roomKey, expectedNames: rec.mediaNames, config: config)
                            if !missing.isEmpty {
                                let dropNorm = Set(missing.map { MediaNaming.canonicalKey($0) })
                                expectedNames = rec.mediaNames.filter { !dropNorm.contains(MediaNaming.canonicalKey($0)) }
                                BackupLogStore.log(category: "同步", action: "宽限期静音桶内缺失媒体", result: "跳过",
                                                   detail: "\(roomKey)：账本引用但桶里不存在的 \(missing.count) 个文件（\(missing.prefix(3).joined(separator: "、"))），24 小时内不下载、不剔除；等另一台设备补传成功后自动恢复",
                                                   room: roomKey, cloud: false)
                            }
                        } catch {
                            // 列桶失败（网络/权限）：照旧按账本名单下载（下载器会跳过桶里没有的对象），不做静音
                        }
                    }
                    let files = (try? await CosUploader.downloadHouseMedia(roomKey: roomKey, expectedNames: expectedNames, config: config, progress: { p in
                        HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: p)
                    })) ?? []
                    HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: 1)
                    // b118（1-711 死循环收敛）：账本名单里有、桶里没有等价对象的失效媒体引用
                    // （下载永远失败 → 本地永远缺 → 每次同步都判「云端独有」→ 无限循环，实测 1-711-mov-2b237b6b-1）。
                    // 超过 24 小时仍缺才从云端账本剔除写回；24h 内已在下载前静音，这里不再重复列桶/剔除，
                    // 避免把「另一台设备还没补传上来」的引用误删。
                    let missingLedger: [String]
                    if recordAge < 24 * 3600 {
                        missingLedger = []
                    } else {
                        do {
                            missingLedger = try await CloudHouseSync.missingLedgerMedia(roomKey: roomKey, expectedNames: rec.mediaNames, config: config)
                        } catch {
                            missingLedger = []
                        }
                    }
                    if !missingLedger.isEmpty {
                        var pruned = rec
                        let dropNorm = Set(missingLedger.map { MediaNaming.canonicalKey($0) })
                        pruned.mediaNames = rec.mediaNames.filter { !dropNorm.contains(MediaNaming.canonicalKey($0)) }
                        if pruned.mediaNames.count != rec.mediaNames.count {
                            _ = try? await CloudHouseSync.uploadGuarded(record: pruned, removedMedia: Set(missingLedger), config: config)
                            BackupLogStore.log(category: "同步", action: "清理失效媒体记录", result: "成功",
                                               detail: "\(roomKey)：云端已不存在的 \(missingLedger.joined(separator: "，")) 已从名单剔除", cloud: false)
                        }
                    }
                    mediaSaved += files.count
                    await MainActor.run {
                        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                        if let h = all.first(where: { $0.mediaRoomKey == roomKey && !$0.isTrashed }) {
                            // 下载返回的文件名 = 账本名 → 插入记录后本地记录与账本零差异
                            for f in files where !h.mediaItems.contains(where: { $0.fileName == f.fileName }) {
                                let item = MediaItem(fileName: f.fileName, kind: f.kind)
                                item.house = h
                                ctx.insert(item)
                            }
                            // v1.41：按账本补记录——磁盘已有但记录缺失（如恢复快速备份后，
                            // 备份只有记录引用没有媒体本体），补建 MediaItem 记录，详情页才能打开视频
                            if let rec = recs.first(where: { $0.roomKey == roomKey }) {
                                let recorded = Set(h.mediaItems.map { $0.fileName })
                                let disk = MediaStore.existingFileNames(roomKey: roomKey)
                                for name in rec.mediaNames where !recorded.contains(name) && disk.contains(name) {
                                    let lower = name.lowercased()
                                    let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
                                    let item = MediaItem(fileName: name, kind: isVideo ? "video" : "image")
                                    item.house = h
                                    ctx.insert(item)
                                }
                            }
                            h.cloudStatus = .both
                            try? ctx.save()
                        }
                    }
                }
            }
            // v1.42：完成提示一律列出具体房号（用户要求：只要对比有差别就列出房号）
            // v1.43：媒体方向标注（云端→本地 / 本地→云端）
            var parts: [String] = []
            if addedCount > 0 { parts.append("新增\(addedCount)套：\(addedRoomNo.joined(separator: "，"))") }
            if updatedCount > 0 { parts.append("更新\(updatedCount)套：\(updatedRoomNo.joined(separator: "，"))") }
            if deletedCount > 0 { parts.append("云端已删\(deletedCount)套：\(deletedRoomNo.joined(separator: "，"))") }
            if pushedCount > 0 { parts.append("补传\(pushedCount)套：\(pushedRoomNo.joined(separator: "，"))") }
            if mediaSaved > 0 { parts.append("下载媒体\(mediaSaved)个（云端→本地）") }
            if removedMediaCount > 0 { parts.append("删除媒体\(removedMediaCount)个（本地多余跟随删）") }
            if !mediaDiffRoomNo.isEmpty { parts.append("媒体同步：\(Array(Set(mediaDiffRoomNo)).joined(separator: "，"))") }
            let msg = "已同步：\(parts.joined(separator: "，"))"
            // v1.77：同步完成后重建本地账本镜像；v1.78：增量写，只报实际写入套数
            let ledger = rebuildLocalLedgers()
            if ledger.written > 0 {
                showToast(msg + "\n本地账本已同步 \(ledger.written) 套")
            } else {
                showToast(msg)
            }
            // v2.44：总同步完成系统通知，正文即上面带房号明细的 msg
            HouseActionNotifier.shared.send(
                key: "sync.done",
                title: "房源同步完成",
                body: ledger.written > 0 ? msg + "；本地账本 \(ledger.written) 套" : msg
            )
            // v2.46：合并成一条——本地数据刷新套数并进明细，不再单独写「重建本地账本镜像」
            let syncDetail = msg + (ledger.written > 0 ? "；本地数据刷新 \(ledger.written) 套" : "")
            BackupLogStore.log(category: "同步", action: "云端同步完成", result: "成功", detail: syncDetail, cloud: false)
            HouseSyncProgress.shared.end()
            // 已同步成功：云端更新横幅自动收起
            cloudUpdateBannerVisible = false
            // 总进度条完成（只关临时进度，不写「最近完成」）
            syncCenter.endTransient(id: applyID)
            // v2.58（#3）：任务中心重试进来的这次同步，执行成功才结算为成功
            if let retryTaskID {
                syncCenter.finish(id: retryTaskID, success: true, note: "同步完成")
            }
            // v2.37（#34）：同步成功后刷新本地修订号基线，并强制把总清单积压改动落盘，
            // 保证下次进页面的增量检测基线准确，不再误报「有更新」
            var seenRev: [String: Int64] = [:]
            for r in recs { seenRev[r.roomKey] = r.revision ?? 0 }
            CloudRevisionStore.remember(seenRev)
            Task { await CloudManifestUpdater.shared.flush() }
            // v2.45：同步收尾——把各房云端账本（别人的操作）拉到本地，再合并上传所有待同步账本
            Task {
                for rec in recs {
                    try? await HouseLedgerStore.pull(roomKey: rec.roomKey, config: config)
                }
                await HouseLedgerStore.syncAll(roomKeys: HouseLedgerStore.dirtyRoomKeys(), config: config)
            }
            // v2.28：按用户要求移除「同步成功后自动清理孤儿」——自动删云端对象风险高（账本读取失败会整目录误删），
            // 只保留设置页「清理桶孤儿媒体」手动按钮（先扫描列清单、确认后才删）
        } catch {
            // v2.57（P3-14）：总同步失败不再只 toast——挂任务中心 cloudPull 任务，点重试即重跑整次同步
            // （云端配置无效等永久错误除外：重试也没意义，仍只提示）。
            var permanent = false
            if case CosUploader.CosError.invalidConfig = error { permanent = true }
            showToast("云端同步失败：\(error.localizedDescription)。已挂任务中心，可点重试", isError: true)
            HouseActionNotifier.shared.send(
                key: "sync.fail",
                title: "同步失败",
                body: "\(error.localizedDescription)，已挂任务中心可重试",
                silent: true
            )
            if let retryTaskID {
                // v2.58（#3）：原任务直接按真实失败结算，不再另建一条重复任务
                syncCenter.finish(id: retryTaskID, success: false,
                                  failure: "云端同步没完成：\(error.localizedDescription)，点重试重跑整次同步")
            } else if !permanent {
                syncCenter.finish(id: syncCenter.begin(kind: .cloudPull, title: "从云端拉下来", roomKeys: [], total: 1),
                                  success: false,
                                  failure: "云端同步没完成：\(error.localizedDescription)，点重试重跑整次同步")
            }
            BackupLogStore.log(category: "同步", action: "云端同步", result: "失败", detail: String(describing: error), cloud: false)
            HouseSyncProgress.shared.end()
            syncCenter.endTransient(id: applyID)
        }
    }

    /// v2.7（P2⑯ 桶孤儿清理）：同步完成后后台清理桶里的孤儿媒体对象。
    /// 规则：
    /// 1) 列 h/ 整桶对象，按「h/<房号>/」前缀分组；
    /// 2) 对每个房号目录，读 info.json 账本拿到 mediaNames；
    /// 3) 删除目录下不在 mediaNames 里的媒体对象（图片/视频）——这些是改名/删媒体后残留的孤儿；
    /// 4) 没有 info.json（或账本读取失败）的房号目录 → v2.28 起保守跳过、一个不删
    ///    （旧注释写“整目录全删”与实现不符：账本读取失败可能是网络抖动，删了无法恢复；孤儿留给设置页手动清）；
    /// 5) 只删媒体对象（.jpg/.jpeg/.png/.heic/.webp/.gif/.mp4/.mov），不动 info.json 与其他系统对象。
    /// 失败静默（不打断用户），下次同步再清。
    /// b117：孤儿媒体清单项
    struct OrphanMedia {
        let roomKey: String   // 房号（如 1-711上 / 2-1418下）
        let fileName: String  // 孤儿文件名
        var path: String { "h/\(roomKey)/\(fileName)" }
    }

    /// b117：干跑扫描——列出桶里所有孤儿媒体对象，不删。
    /// v2.47：onProgress 逐房回报扫描进度（done/total/当前房号）
    /// 取消令牌：设置页「取消本次」置位后，扫描循环立即停止，一个文件都不删
    actor OrphanScanControl {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    static func scanOrphanMedia(config: CosConfig,
                                control: OrphanScanControl? = nil,
                                onProgress: ((_ done: Int, _ total: Int, _ roomKey: String) -> Void)? = nil) async throws -> [OrphanMedia] {
        let objs = try await CosUploader.listObjects(prefix: "h/", config: config)
        var byRoom: [String: [String]] = [:]
        for obj in objs {
            let name = obj.name
            guard name.hasPrefix("h/") else { continue }
            let rest = String(name.dropFirst(2))
            guard let slash = rest.firstIndex(of: "/") else { continue }
            let roomKey = String(rest[..<slash])
            guard !roomKey.isEmpty, !roomKey.hasPrefix("_") else { continue }
            let file = String(rest[rest.index(after: slash)...])
            guard !file.isEmpty else { continue }
            byRoom[roomKey, default: []].append(file)
        }
        let roomKeys = byRoom.keys.sorted()
        let total = roomKeys.count
        onProgress?(0, max(total, 1), "")
        var orphans: [OrphanMedia] = []
        var done = 0
        for roomKey in roomKeys {
            if await control?.isCancelled == true { break }
            let files = byRoom[roomKey] ?? []
            // 安全规则：读取该房云端账本失败（网络错误/超时）时，绝不按空名单处理——
            // 否则整间房的媒体都会被误判成孤儿而删除。直接跳过该房间，本次不清理。
            // 无账本（无 info.json）同样整间跳过。
            let rec: CloudHouseRecord?
            do {
                rec = try await CloudHouseSync.fetchOne(roomKey: roomKey, config: config)
            } catch {
                rec = nil
            }
            if let rec {
                let ledgerKeys = Set(rec.mediaNames.map { MediaNaming.canonicalKey($0) })
                for file in files {
                    guard file != "info.json" else { continue }
                    let lower = file.lowercased()
                    let isMedia = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif", ".mp4", ".mov"].contains { lower.hasSuffix($0) }
                    guard isMedia else { continue }
                    // v2.37（#11）：按规范键判断账本是否引用——视频 mov/mp4 等价、图片保留后缀
                    let fileKey = MediaNaming.canonicalKey(file)
                    if !ledgerKeys.contains(fileKey) {
                        orphans.append(OrphanMedia(roomKey: roomKey, fileName: file))
                    }
                }
            }
            done += 1
            onProgress?(done, max(total, 1), roomKey)
        }
        return orphans
    }

    /// b117：实际删除指定孤儿清单，返回删除成功数。
    /// v2.37（#19）：点「确认删除」那一刻对每个文件重新实时核对——重拉该房账本确认它现在仍无主、
    /// 再确认对象还在；凡是现在有主/有变化/账本或列桶失败的一律剔除，只删核对后确实还是孤儿的，
    /// 哪怕确认弹窗放了很久，也不会误删别人刚传的同名文件。
    static func deleteOrphanMedia(_ orphans: [OrphanMedia], config: CosConfig) async -> Int {
        var byRoom: [String: [OrphanMedia]] = [:]
        for o in orphans { byRoom[o.roomKey, default: []].append(o) }
        var deleted = 0
        for (roomKey, items) in byRoom {
            // ① 重拉账本：失败/无账本（整间可能已被改动）→ 保守起见本间全部跳过，不删
            let rec: CloudHouseRecord
            do {
                guard let fetched = try await CloudHouseSync.fetchOne(roomKey: roomKey, config: config) else { continue }
                rec = fetched
            } catch {
                continue
            }
            let ledgerKeys = Set(rec.mediaNames.map { MediaNaming.canonicalKey($0) })
            // ② 列当前桶内对象确认还在；列桶失败（网络）绝不当成空，本间跳过
            let currentObjs: Set<String>
            do {
                let objs = try await CosUploader.listObjects(prefix: "h/\(roomKey)/", config: config)
                currentObjs = Set(objs.map { $0.name })
            } catch {
                continue
            }
            for o in items {
                // 现在已被账本引用 → 剔除，不删
                if ledgerKeys.contains(MediaNaming.canonicalKey(o.fileName)) { continue }
                // 对象已不存在 → 无需删
                guard currentObjs.contains(o.path) else { continue }
                do {
                    try await CloudBackupService.deleteRemoteObject(name: o.path, config: config)
                    deleted += 1
                } catch {
                    // 单个失败跳过
                }
            }
        }
        return deleted
    }

    // v2.33：自动孤儿清理的残留函数 cleanupOrphanMedia 已删除——自动触发点 v2.28 已移除，
    // 云端媒体只允许设置页「清理桶孤儿媒体」手动扫描+确认后删除（scanOrphanMedia/deleteOrphanMedia）。

    // MARK: - v1.12 多选批量操作（批量已租 / 批量删除）

    /// 批量已租：选中的待租房源全部标为已租（已租的保持不变），完成后自动退出多选
    private func batchSetRented() {
        guard !selectedHouseIDs.isEmpty, let ctx = houseModelContext else { return }
        var changed = 0
        var rentedHouses: [House] = []
        for house in houses where selectedHouseIDs.contains(house.id) && house.status == .available {
            house.status = .rented
            house.lastUpdatedAt = Date()
            // v2.45：批量已租逐房写账本
            HouseLedgerStore.append(
                roomKey: house.mediaRoomKey,
                action: "批量标记已租",
                detail: "状态：\(HouseStatus.available.label) → \(HouseStatus.rented.label)",
                fieldChanges: [HouseLedgerFieldChange(field: "状态", oldValue: HouseStatus.available.label, newValue: HouseStatus.rented.label)])
            rentedHouses.append(house)
            changed += 1
        }
        try? ctx.save()
        // v2.24：批量已租也要推云端（此前只改本地，下次同步被云端旧状态回滚回去）
        if let config = CosConfig.load(), config.isValid, !rentedHouses.isEmpty {
            let toPush = rentedHouses
            Task {
                var okRooms: [String] = []
                var failRooms: [String] = []
                for house in toPush {
                    let record = CloudHouseSync.record(from: house, username: CloudUser.username)
                    LocalHouseLedger.save(house)
                    let roomKey = house.mediaRoomKey
                    let roomNo = house.displayRoomNo
                    HouseSyncProgress.shared.begin(roomKey: roomKey, direction: .upload, progress: 0.2, label: "同步账本")
                    do {
                        // v2.36（#6）：批量已租改走 uploadGuarded 合并写，避免裸覆盖
                        _ = try await CloudHouseSync.uploadGuarded(record: record, config: config)
                        HouseSyncProgress.shared.end()
                        await MainActor.run {
                            house.cloudStatus = .both
                            SyncFailStore.clear(roomKey)
                            try? houseModelContext?.save()
                        }
                        okRooms.append(roomNo)
                        BackupLogStore.log(category: "房源", action: "批量标记已租", result: "成功", detail: "状态：待租 → 已租", room: roomNo, cloud: true)
                    } catch {
                        HouseSyncProgress.shared.end()
                        await MainActor.run { SyncFailStore.mark(roomKey) }
                        failRooms.append(roomNo)
                        BackupLogStore.log(category: "房源", action: "批量标记已租", result: "失败", detail: "云端更新失败：\(error.localizedDescription)", room: roomNo, cloud: true)
                    }
                }
                await MainActor.run {
                    if failRooms.isEmpty {
                        HouseActionNotifier.shared.send(
                            key: "batch.rented",
                            title: "批量改已租完成",
                            body: "\(okRooms.count) 套已改为已租，云端同步 \(okRooms.count)/\(okRooms.count)"
                        )
                    } else {
                        HouseActionNotifier.shared.send(
                            key: "batch.rented",
                            title: "部分房源没传上",
                            body: "\(okRooms.count) 套同步成功，\(failRooms.count) 套失败（\(failRooms.joined(separator: "、"))），联网后自动重试",
                            silent: true
                        )
                    }
                }
            }
        }
        NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
        let total = selectedHouseIDs.count
        exitMultiSelect()
        showToast(RemoteConfig.tip("bulkRentDone", "已将 {changed} 套标记为已租（共选中 {total} 套）").replacingOccurrences(of: "{changed}", with: String(changed)).replacingOccurrences(of: "{total}", with: String(total)))
    }

    /// v1.7：卡片左滑「分享」→ 单套分享卡片（脱敏 / 完整），生成链接后弹系统分享面板
    /// 注意：Task 内只传值类型，绝不直接访问 SwiftData @Model（跨线程读取模型会闪退）
    /// v2.17：列表页单套 → 只分享视频（不走云端卡片，不需要 COS 配置）
    private func generateSingleVideoShare() {
        guard let house = singleShareHouse else { return }
        let urls = house.videos
            .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            infoMessage = "这套房源没有可分享的视频；视频若还在云端，先下载到本地再分享"
            showInfoAlert = true
            singleShareHouse = nil
            return
        }
        isGenerating = true
        generateTip = "正在准备视频…"
        generateProgress = 0
        Task {
            do {
                let files = try await VideoOnlyShare.prepareFiles(from: urls)
                await MainActor.run {
                    isGenerating = false
                    singleShareHouse = nil
                    guard !files.isEmpty else {
                        infoMessage = "视频文件缺失，无法分享"
                        showInfoAlert = true
                        return
                    }
                    // v2.26：微信扩展单次只认 1 个视频，按「每个视频一次面板」排队
                    var batches: [[Any]] = []
                    for file in files {
                        batches.append(VideoOnlyShare.movieItems(from: [file]))
                    }
                    shareQueue = batches
                    shareIndex = 0
                    presentShareStep(batches[0])
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    singleShareHouse = nil
                    infoMessage = error.localizedDescription
                    showInfoAlert = true
                }
            }
        }
    }

    private func generateSingleShare(mode: ShareMode) {
        guard let house = singleShareHouse else { return }
        guard let config = CosConfig.load(), config.isValid else {
            infoMessage = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"; showInfoAlert = true
            return
        }
        guard !house.mediaItems.isEmpty else {
            infoMessage = "这套房源还没有照片或视频，先编辑添加素材再分享"; showInfoAlert = true
            return
        }
        let files = house.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
        let roomKey = house.mediaRoomKey
        let profile = CosUploader.loadShareProfile()
        let info = ShareHouseInfo(
            displayRoomNo: house.displayRoomNo,
            towerLabel: house.towerLabel,
            layout: house.layout,
            statusLabel: house.status.label,
            priceText: house.priceText,
            landlord: house.landlord,
            password: house.password,
            remark: house.remark,
            name: profile.name,
            phone: profile.phone
        )
        isGenerating = true
        generateTip = "正在上传照片和视频…"
        generateProgress = 0
        Task {
            do {
                let url = try await CosUploader.shareCard(mediaFiles: files, roomKey: roomKey, info: info, mode: mode, config: config) { p in
                    Task { @MainActor in self.generateProgress = p }
                }
                await MainActor.run {
                    isGenerating = false
                    shareQueue = [[url]]
                    shareIndex = 0
                    presentShareStep([url])
                    singleShareHouse = nil
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    infoMessage = error.localizedDescription; showInfoAlert = true
                    singleShareHouse = nil
                }
            }
        }
    }

    private func startMultiShare() {
        guard !selectedHouseIDs.isEmpty else { return }
        guard let config = CosConfig.load(), config.isValid else {
            infoMessage = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"; showInfoAlert = true
            return
        }
        // 过滤出有素材的房源（无照片视频的无法生成卡片）
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            infoMessage = "选中的房源都没有照片或视频，先编辑添加素材再分享"; showInfoAlert = true
            return
        }
        activeDialog = .multiShare; showShareModeAlert = true
    }

    /// v1.22：生成【合集分享卡片】（一次选 N 套 → 一个链接 → 好友点开看全部），生成后弹一次系统分享面板
    /// 注意：值类型（ShareCollectionItem）在主线程构建完成，Task 内只传递值，绝不直接访问 SwiftData @Model（跨线程读取模型会闪退）
    private func generateShareQueue(mode: ShareMode) {
        guard let config = CosConfig.load(), config.isValid else {
            infoMessage = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"; showInfoAlert = true
            return
        }
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            infoMessage = "选中的房源都没有照片或视频，先编辑添加素材再分享"; showInfoAlert = true
            return
        }
        let sortedShareable = shareable.sorted { a, b in
            if a.tower != b.tower { return a.tower < b.tower }
            if a.floorNumber != b.floorNumber { return a.floorNumber < b.floorNumber }
            if a.roomNumber != b.roomNumber { return a.roomNumber < b.roomNumber }
            return a.roomNo < b.roomNo
        }

        // 主线程先构建值类型数组（Task 闭包内不触碰 @Model）
        let rooms = sortedShareable.map { house -> ShareCollectionItem in
            ShareCollectionItem(
                roomKey: house.mediaRoomKey,
                displayRoomNo: house.displayRoomNo,
                towerLabel: house.towerLabel,
                layout: house.layout,
                statusLabel: house.status.label,
                priceText: house.priceText,
                landlord: house.landlord,
                password: house.password,
                remark: house.remark,
                mediaFiles: house.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
            )
        }

        isGenerating = true
        generateTip = "正在生成合集分享卡片（共 \(sortedShareable.count) 套）…"
        generateProgress = 0

        Task {
            do {
                let url = try await CosUploader.shareCollection(rooms: rooms, mode: mode, config: config) { p in
                    Task { @MainActor in self.generateProgress = p }
                }
                await MainActor.run {
                    isGenerating = false
                    shareQueue = [[url]]
                    shareIndex = 0
                    presentShareStep([url])
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    infoMessage = error.localizedDescription; showInfoAlert = true
                    exitMultiSelect()
                }
            }
        }
    }

    private func showSaveToast(_ msg: String) {
        withAnimation { saveToast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation { if saveToast == msg { saveToast = nil } }
        }
    }

    /// v2.17：多选 → 批量把选中房源的视频存进相册（拍摄时间改成当前，图库最上面能直接看到）。
    /// 之后到微信聊天里点 + → 相册，多选一次发完，不用一套一套弹分享面板。
    private func saveSelectedVideos() {
        let selected = houses.filter { selectedHouseIDs.contains($0.id) }
        let urls = selected.flatMap { house in
            house.videos
                .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard !urls.isEmpty else {
            showSaveToast("选中的房源没有可保存的视频")
            exitMultiSelect()
            return
        }
        isGenerating = true
        generateTip = "正在保存视频到相册（共 \(urls.count) 个）…"
        generateProgress = 0
        Task {
            await VideoOnlyShare.saveToAlbumQuietly(urls)
            await MainActor.run {
                isGenerating = false
                showSaveToast("已保存 \(urls.count) 个视频到相册，微信里点 + → 相册多选发完")
                exitMultiSelect()
            }
        }
    }

    /// v2.17：多选 → 只分享视频，一次面板发完（微信端连续收到多条视频消息）。
    /// 微信单次最多接 9 条视频，超过 9 个自动拆成 2 次面板，避免整批发不出去。
    private func generateVideoOnlyShare() {
        let selected = houses.filter { selectedHouseIDs.contains($0.id) }
        let sortedSelected = selected.sorted { a, b in
            if a.tower != b.tower { return a.tower < b.tower }
            if a.floorNumber != b.floorNumber { return a.floorNumber < b.floorNumber }
            if a.roomNumber != b.roomNumber { return a.roomNumber < b.roomNumber }
            return a.roomNo < b.roomNo
        }
        // 主线程先按排序收集视频地址（Task 内不再触碰 SwiftData 模型）
        let videoURLs: [[URL]] = sortedSelected.map { house in
            house.videos
                .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }.filter { !$0.isEmpty }
        let flat = videoURLs.flatMap { $0 }
        guard !flat.isEmpty else {
            infoMessage = "选中的房源没有可分享的视频；视频若还在云端，先下载到本地再分享"
            showInfoAlert = true
            return
        }
        isGenerating = true
        generateTip = "正在准备视频（\(videoURLs.count) 套 / \(flat.count) 个）…"
        generateProgress = 0
        Task {
            do {
                let files = try await VideoOnlyShare.prepareFiles(from: flat)
                await MainActor.run {
                    isGenerating = false
                    guard !files.isEmpty else {
                        infoMessage = "视频文件缺失，无法分享"
                        showInfoAlert = true
                        return
                    }
                    // 微信分享扩展单次只认 1 个视频：一次塞多个它整条消失，所以按「每个视频一次面板」排队，
                    // 关掉一个自动弹下一个（不用退出重选多套）
                    var batches: [[Any]] = []
                    for file in files {
                        batches.append(VideoOnlyShare.movieItems(from: [file]))
                    }
                    shareQueue = batches
                    shareIndex = 0
                    presentShareStep(batches[0])
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    infoMessage = error.localizedDescription
                    showInfoAlert = true
                }
            }
        }
    }
}

// MARK: - 多选分享步骤（sheet(item:) 依次弹分享面板）

struct ShareStep: Identifiable {
    let id = UUID()
    // v2.17：卡片分享塞链接、只分享视频塞视频素材，统一走同一个系统分享面板
    let items: [Any]
    init(items: [Any]) { self.items = items }
    init(url: URL) { self.items = [url] }
}

// MARK: - List 滚动偏移监听（b106：房源列表下滑折叠头部、上滑展开）

/// 挂到 List 的 background 上，通过 KVO 监听底层 UIScrollView 的 contentOffset，
/// 回调主线程偏移值，供折叠/展开判断。
struct ListScrollOffsetReader: UIViewRepresentable {
    var onOffset: (CGFloat) -> Void

    func makeUIView(context: Context) -> OffsetProbeView {
        let v = OffsetProbeView()
        v.onOffset = onOffset
        return v
    }

    func updateUIView(_ uiView: OffsetProbeView, context: Context) {
        uiView.onOffset = onOffset
        uiView.attachIfNeeded()
    }
}

final class OffsetProbeView: UIView {
    var onOffset: (CGFloat) -> Void = { _ in }
    private weak var scrollView: UIScrollView?
    private var observer: NSKeyValueObservation?
    private var attachAttempts = 0
    private static let maxAttachAttempts = 10

    func attachIfNeeded() {
        guard scrollView == nil else { return }
        attachAttempts += 1
        var v: UIView? = superview
        while let u = v {
            if let sv = u as? UIScrollView {
                scrollView = sv
                break
            }
            v = u.superview
        }
        guard let sv = scrollView else {
            // v2.2（需求②修复）：SwiftUI List 在 iOS16+ 由 UICollectionView 承载，
            // 首帧时列表内部结构可能尚未挂载（superview 链里还没有 UIScrollView）。
            // 之前这里直接 return，首帧失败后再也不重试 → 折叠头部 b106 实现无效。
            // 修复：延迟重试，最多 10 次（约 1.5 秒内都能挂上）。
            if attachAttempts < Self.maxAttachAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.attachIfNeeded()
                }
            }
            return
        }
        observer = sv.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            DispatchQueue.main.async {
                self?.onOffset(scroll.contentOffset.y)
            }
        }
    }
}

#Preview {
    HouseListView()
        .modelContainer(for: [House.self, MediaItem.self], inMemory: true)
}
