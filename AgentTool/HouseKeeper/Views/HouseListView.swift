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
    case hasUpdate       // 云端有更新，提示用户点左上角刷新确认后同步
    case detectFailed    // 检测失败（断网/超时/未配置云），不再静默
}

/// 手动云端同步的全局指示状态。
/// 约定：本类所有方法只从主线程调用（异步入口用 MainActor.run 包一层）。
final class CloudDetectActivity: ObservableObject {
    static let shared = CloudDetectActivity()

    /// 手动云端同步进行中——并发拉清单时跳过重复动作，避免两边结论互相打架
    @Published private(set) var isManualSyncing = false

    private var manualDepth = 0

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
    /// 点左上角刷新时的确认弹窗：有本地隐藏房源时先问“恢复还是保持隐藏”，
    /// 没有隐藏房源时确认“是否从服务器同步”，避免点一下就直接拉取。
    @State private var refreshPrompt: RefreshPrompt?
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
    // v1.72（#1/#5）：刷新/同步进行中状态——点刷新立即反馈「正在刷新…」，比对完成才收起
    @State private var isSyncing = false
    /// v2.65：长按触发的深度核对与普通刷新分开提示（否则长按后只显示「正在刷新…」，看不出走的是哪条路）
    @State private var isDeepSyncing = false
    /// v2.50：云端有更新 → 顶栏常驻横幅，只有手动点 ✕ 才收起（此前 toast 不到 1 秒就消失，容易错过）
    @State private var cloudUpdateBannerVisible = false
    @ObservedObject private var syncCenter = SyncTaskCenter.shared
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
    enum RefreshPrompt: Identifiable {
        case confirm(deep: Bool)
        case hidden(count: Int, deep: Bool)
        var id: String {
            switch self {
            case .confirm: return "confirm"
            case .hidden: return "hidden"
            }
        }
    }

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
                        // v1.19：左上角手动同步（已取消下拉刷新，这里是唯一手动入口）
                        Button {
                            requestManualSync(deep: false)
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
                                requestManualSync(deep: true)
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
                Button("仅删除本地（服务器保留）") { startDelete(both: false) }
                Button("删除本地与服务器（推荐）", role: .destructive) { startDelete(both: true) }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteConfirmMessage)
            }
            // 点左上角总刷新才触发；自动对账（进页/45 秒）不弹，避免打断当前操作。
            .alert(item: $refreshPrompt) { prompt in
                switch prompt {
                case .confirm(let deep):
                    return Alert(
                        title: Text("从服务器同步房源？"),
                        message: Text("会先补传本机尚未上传的改动，再拉取服务器最新清单。其他设备刚改的房源会同步到本机。"),
                        primaryButton: .default(Text("开始同步")) {
                            Task { await syncCloudHouses(deep: deep) }
                        },
                        secondaryButton: .cancel(Text("取消")))
                case .hidden(let count, let deep):
                    return Alert(
                        title: Text("有 \(count) 套仅删了本地的房源"),
                        message: Text("服务器上仍保留这些房源。直接同步不会自动带回；要恢复显示，还是保持隐藏？"),
                        primaryButton: .default(Text("恢复显示并同步")) {
                            HouseLocalDeletionStore.clearAll()
                            Task { await syncCloudHouses(deep: deep) }
                        },
                        secondaryButton: .default(Text("保持隐藏并同步")) {
                            Task { await syncCloudHouses(deep: deep) }
                        })
                }
            }
        }
        .onAppear {
            reloadHouses()
            // 服务器模式：进页面静默增量拉取权威库（小 JSON，失败不打扰、不打断操作）
            if HouseServerMode.ready, let ctx = houseModelContext {
                Task {
                    // 进页先补传离线未提交的改动，再全量对账权威库（弱网改动不丢）
                    _ = await HousePendingUploader.shared.flush(context: ctx)
                    let n = try? await HouseSyncEngine.shared.pull(context: ctx)
                    if (n ?? 0) > 0 {
                        reloadHouses()
                    }
                }
            }
            // v2.58（#3）：整次云端同步的重试入口——页面必须回报真实结果（成功/失败/等确认）
            TaskRetryPerformer.shared.cloudPull = { retryTaskID in
                await syncCloudHouses(retryTaskID: retryTaskID)
            }
            // v2.62（A3）：进板块不再每次检测——从详情页返回、从编辑页返回、切 tab 回来都不再触发，
            // 只消费「App 启动 / 回前台」写下的 pending 标记；没有标记就不发请求。
            let pending = UserDefaults.standard.bool(forKey: "cloudLedgerPendingHint")
            UserDefaults.standard.set(false, forKey: "cloudLedgerPendingHint")
            if pending && !HouseServerMode.ready { showCloudChangeHint() }
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
        // 房源卡片上的「本地 / 云端 / 双端」不是本地持久化的假标识：
        // 停留在房源板块时每 45 秒按服务器权威清单对账一次，后台删房/改房后无需杀 App 或反复进出。
        .task {
            guard HouseServerMode.ready else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard let ctx = houseModelContext, !isSyncing else { continue }
                if let n = try? await HouseSyncEngine.shared.pull(context: ctx), n > 0 {
                    reloadHouses()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.houseStoreChanged)) { _ in
            reloadHouses()
        }
        // b118（清单12：打开 App 轻量变更感知）：App 启动/回前台探测到云端账本有变化 →
        // 顶部横幅轻提示「云端有更新」，用户点左上角刷新确认后同步（不自动拉取，省流量、不打断当前操作）
        // b119（清单1 重做）：文案改为「检测到云端有更新，请同步」；本页收到通知直接提示
        // b120：通知到达也走统一提示入口（showCloudChangeHint 防抖），并消费 pendingHint
        .onReceive(NotificationCenter.default.publisher(for: Self.cloudLedgerChangedLight)) { _ in
            UserDefaults.standard.set(false, forKey: "cloudLedgerPendingHint")
            if !HouseServerMode.ready { showCloudChangeHint() }
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

    /// 旧 COS 清单变更感知已下线：服务器模式下权威库由 HouseSyncEngine.pull 增量对账，本方法恒返回无变化。
    static func detectCloudLedgerChange(houseContext _: ModelContext?) async -> CloudChangeState {
        .noChange
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
        case .some(.local): scope = "这套房源仅在本机，服务器上没有"
        case .some(.cloud): scope = "这套房源本机无媒体、服务器上有"
        default: scope = "这套房源本机和服务器上都有"
        }
        let head = isBatchDelete ? "共 \(count) 套，\(scope)。" : "\(scope)。"
        return head + "\n\n仅删除本地：只清本机缓存和照片视频，服务器继续保留，其他设备不受影响。之后点左上角刷新会先问是否恢复，不会自动带回。\n删除本地与服务器（推荐）：本机照片视频、数据库记录，以及服务器上的房源、账本和实拍图片/视频一并永久删除，不可恢复。"
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

        // 仅删本地：服务器不动，但必须留下“本地隐藏”墓碑——否则下一次总刷新
        // 看到服务器还有这套房，就会不声不响地按云端数据重新 insert（用户看到的“自动带回”）。
        if !both {
            let targets = houses.filter { keys.contains($0.mediaRoomKey) }
            for h in targets {
                if h.cloudStatus != .local {
                    HouseLocalDeletionStore.mark(h.mediaRoomKey)
                }
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
            for key in keys where HouseLocalDeletionStore.contains(key) {
                CloudOps.log(category: "房源", action: "仅删本地房源", result: "成功",
                             detail: "本机删除，服务器保留；刷新时需手动确认恢复", room: key)
            }
            showToast("已从本机删除 \(keys.count) 套；服务器仍保留。之后点左上角刷新会先问是否恢复，不会自动带回。")
            return
        }

        // 服务器模式：双端删除走服务器硬删（永久，不进回收站），逐套同步
        if HouseServerMode.ready {
            runServerDelete(keys: keys, ctx: ctx)
            return
        }

        // 未接入服务器：旧桶删除编排已下线，双端删除仅删本地（目录/状态标记/待传队列/记录）
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
        showToast("已删除本地 \(keys.count) 套")
    }

    /// v2.57（P1-2）：双端删除执行体——先逐套删云端，成功一套删一套本地；全部云端成功的房本地立即清、
    /// 界面马上见效；云端失败的房本地保留（同步不会把它拉回来，因为云端已删/在删），挂任务中心
    /// 「删云端」任务标注失败环节，retryCloudDelete 成功后自动清掉本地残留。
    /// 服务器模式双端硬删：逐套删服务器权威库，成功一套删一套本地；不进回收站；失败的房本地保留可重试
    private func runServerDelete(keys: [String], ctx: ModelContext) {
        deleteTotal = keys.count
        deleteDone = 0
        deleteRunning = true
        deleteCurrentRoom = ""
        Task {
            var ok = 0
            var localDeleted: [House] = []
            for key in keys {
                await MainActor.run { deleteCurrentRoom = key }
                if let h = houses.first(where: { $0.mediaRoomKey == key }) {
                    do {
                        try await HouseSyncEngine.shared.pushDelete(h)
                        HouseLocalDeletionStore.remove(key)
                        CloudOps.log(category: "房源", action: "删除双端房源", result: "成功",
                                     detail: "服务器与本地永久删除，不可恢复", room: key)
                        ok += 1
                        localDeleted.append(h)
                    } catch {
                        CloudOps.log(category: "房源", action: "删除双端房源", result: "失败",
                                     detail: "服务器删除失败：\(error.localizedDescription)，本机记录保留",
                                     room: key)
                        showToast("删除失败 \(key)：\(error.localizedDescription)", isError: true)
                    }
                }
                await MainActor.run { deleteDone += 1 }
            }
            await MainActor.run {
                for h in localDeleted {
                    MediaStore.deleteHouseDirectory(roomKey: h.mediaRoomKey)
                    SyncFailStore.clear(h.mediaRoomKey)
                    UnreadCloudHouseStore.clear(h.mediaRoomKey)
                    HouseMediaUploadQueue.removeRoom(h.mediaRoomKey)
                    ctx.delete(h)
                }
                try? ctx.save()
                deleteRunning = false
                deleteCurrentRoom = ""
                deleteTarget = nil
                if isBatchDelete { exitMultiSelect() }
                isBatchDelete = false
                for key in keys { HouseMediaUploadQueue.removeRoom(key) }
                NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
                if ok > 0 { showToast("已删除 \(ok) 套（服务器与本地）") }
            }
        }
    }

    /// 服务器删除进度浮层（只负责进行中展示；失败进任务中心，不再在浮层里放重试）
    @ViewBuilder private var deleteOverlayCard: some View {
        if deleteRunning {
            VStack(spacing: 12) {
                Text("正在同步删除服务器副本")
                    .font(.headline)
                ProgressView(value: deleteTotal == 0 ? 0 : Double(deleteDone) / Double(deleteTotal))
                    .progressViewStyle(.linear)
                    .frame(width: 210)
                Text("\(deleteDone)/\(deleteTotal)" + (deleteCurrentRoom.isEmpty ? "" : " · 房号 \(deleteCurrentRoom)"))
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

    /// 状态切换上行：服务器模式推服务器权威库（失败入待补传队列）；旧 COS 账本/媒体上行已下线，非服务器模式仅本机落库。
    private func pushHouseToCloud(_ house: House, action: String = "同步房源（本地→云端）", changeText: String = "") {
        // 服务器模式：状态切换直接推服务器权威库，不走旧 COS 账本链路；失败入待补传队列
        if HouseServerMode.ready {
            let roomKey = house.mediaRoomKey
            let roomNo = house.displayRoomNo
            Task {
                do {
                    _ = try await HouseSyncEngine.shared.pushHouse(house)
                    await MainActor.run {
                        HouseActionNotifier.shared.send(
                            key: "status.\(roomKey)",
                            title: "状态已同步",
                            body: "\(roomNo) 已改为\(house.status.label)，服务器已更新")
                    }
                } catch {
                    await MainActor.run {
                        HousePendingUploader.shared.markPending(roomKey)
                        HouseActionNotifier.shared.send(
                            key: "statusfail.\(roomKey)",
                            title: "状态同步失败",
                            body: "\(roomNo) 已改本机，服务器没同步上：\(error.localizedDescription)",
                            silent: true)
                    }
                }
            }
            return
        }
        // 旧桶账本上行已下线：非服务器模式仅本机落库，不再上传旧 COS 账本/媒体
    }

    /// v2.50：云端有更新横幅——常驻顶栏，只有点右侧 ✕ 才收起；同步成功后自动收起。
    @ViewBuilder
    private var cloudUpdateBanner: some View {
        Group {
            if cloudUpdateBannerVisible {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.down").font(.footnote)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("检测到服务器有更新")
                            .font(.footnote.weight(.semibold))
                        Text("点左上角刷新按钮同步")
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
                    .accessibilityLabel("关闭服务器更新提示")
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

    /// v2.62：当前是否有房源上传任务正在跑（决定要不要跳过整次检测）
    @MainActor
    private static func hasRunningHouseUpload() -> Bool {
        SyncTaskCenter.shared.running.contains { $0.isHouseUpload == true }
    }

    /// v1.83：同步失败自动重试一次——网络瞬断/弱网（如电梯信号切换）时第一次失败会在 1 秒后自动重跑，
    /// 第二次仍失败才提示。retriedOnce 防止重试套娃无限递归。
    @discardableResult
    /// 服务器模式同步：增量拉取权威库并直接应用到本地（服务器已做合并，无需本地 diff 预览）
    private func runServerSync(context ctx: ModelContext) async -> CloudPullRunOutcome {
        let progressID = syncCenter.beginTransient(kind: .cloudPull, title: "同步房源", total: 1)
        do {
            // 先补传本地离线写，再拉取服务器全量清单对账，保证两端最终一致
            _ = await HousePendingUploader.shared.flush(context: ctx)
            let changed = try await HouseSyncEngine.shared.pull(context: ctx)
            let hidden = HouseSyncEngine.shared.hiddenCloudCount
            let pending = HousePendingUploader.shared.pendingKeys.count
            let tail = (hidden > 0 ? "；\(hidden) 套仅删本地，仍保持隐藏" : "")
                + (pending > 0 ? "；\(pending) 套本机改动未同步，已保留本地，请点重试" : "")
            if changed > 0 {
                showToast("已从服务器同步 \(changed) 套房源" + tail)
            } else {
                showToast("服务器上房源已是最新" + tail)
            }
            syncCenter.endTransient(id: progressID)
            return .finished
        } catch {
            let msg = "服务器同步失败：\(error.localizedDescription)"
            showToast(msg, isError: true)
            syncCenter.endTransient(id: progressID)
            return .failed(msg)
        }
    }

    /// 唯一手动刷新入口：先确认，再同步；有“仅删本地”隐藏房源时先问是否恢复。
    private func requestManualSync(deep: Bool) {
        guard !isSyncing else {
            showToast("正在同步中，请稍候")
            return
        }
        let hidden = HouseLocalDeletionStore.count()
        refreshPrompt = hidden > 0 ? .hidden(count: hidden, deep: deep) : .confirm(deep: deep)
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
        // 旧 COS 直连兜底链路已下线：未连接服务器时仅返回失败，本地数据可离线查看
        return .failed("服务器未连接，请检查网络后重试")
    }


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
        // 服务器模式：逐套推服务器权威库，失败入待补传；旧 COS 链路仅在非服务器模式走
        if HouseServerMode.ready, !rentedHouses.isEmpty {
            let toPush = rentedHouses
            Task {
                var okRooms: [String] = []
                var failRooms: [String] = []
                for house in toPush {
                    let roomKey = house.mediaRoomKey
                    let roomNo = house.displayRoomNo
                    do {
                        _ = try await HouseSyncEngine.shared.pushHouse(house)
                        okRooms.append(roomNo)
                    } catch {
                        await MainActor.run { HousePendingUploader.shared.markPending(roomKey) }
                        failRooms.append(roomNo)
                    }
                }
                await MainActor.run {
                    if failRooms.isEmpty {
                        HouseActionNotifier.shared.send(
                            key: "batch.rented",
                            title: "批量改已租完成",
                            body: "\(okRooms.count) 套已改为已租，服务器同步 \(okRooms.count)/\(okRooms.count)")
                    } else {
                        HouseActionNotifier.shared.send(
                            key: "batch.rented",
                            title: "部分房源没传上",
                            body: "\(okRooms.count) 套同步成功，\(failRooms.count) 套失败（\(failRooms.joined(separator: "、"))），联网后自动重试",
                            silent: true)
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
            infoMessage = "这套房源没有可分享的视频；视频若还在服务器，先下载到本地再分享"
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
        // 服务器模式：App 内分享——本地媒体 + 服务器 H5 链接 + 纯文字，直接系统面板
        if HouseServerMode.ready {
            let urls: [URL] = files.compactMap { f in
                let u = MediaStore.url(for: f.name, roomKey: roomKey)
                return FileManager.default.fileExists(atPath: u.path) ? u : nil
            }
            var items: [Any] = urls
            if let h5 = HouseRemoteClient.h5URL(roomKey: roomKey) { items.append(h5) }
            items.append(info.shareText)
            shareQueue = [items]
            shareIndex = 0
            presentShareStep(items)
            singleShareHouse = nil
            Task { try? await HouseRemoteClient.shared.addShareRecord(roomKey: roomKey, channel: "app内分享", summary: info.shareText) }
            return
        }
        // 旧桶卡片链接已下线：未接入服务器回退本地媒体 + 纯文字系统分享
        let localUrls = files.compactMap { f in
            let u = MediaStore.url(for: f.name, roomKey: roomKey)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        let items: [Any] = localUrls + [info.shareText]
        shareQueue = [items]
        shareIndex = 0
        presentShareStep(items)
        singleShareHouse = nil
    }

    private func startMultiShare() {
        guard !selectedHouseIDs.isEmpty else { return }
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

        // 服务器模式：App 内分享——每套一批（本地媒体 + 该套纯文字），依次弹系统面板；不生成合集 H5 链接
        if HouseServerMode.ready {
            var batches: [[Any]] = []
            var records: [(roomKey: String, summary: String)] = []
            for house in sortedShareable {
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
                let urls = house.mediaItems.compactMap { item -> URL? in
                    let u = MediaStore.url(for: item.fileName, roomKey: roomKey)
                    return FileManager.default.fileExists(atPath: u.path) ? u : nil
                }
                var batch: [Any] = urls
                if let h5 = HouseRemoteClient.h5URL() { batch.append(h5) }
                batch.append(info.shareText)
                batches.append(batch)
                records.append((roomKey, info.shareText))
            }
            shareQueue = batches
            shareIndex = 0
            presentShareStep(batches[0])
            Task {
                for rec in records {
                    try? await HouseRemoteClient.shared.addShareRecord(roomKey: rec.roomKey, channel: "app内分享", summary: rec.summary)
                }
            }
            return
        }

        // 旧桶合集卡片已下线：未接入服务器按套分批本地媒体 + 纯文字依次系统分享
        var localBatches: [[Any]] = []
        for house in sortedShareable {
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
            let urls = house.mediaItems.compactMap { item -> URL? in
                let u = MediaStore.url(for: item.fileName, roomKey: roomKey)
                return FileManager.default.fileExists(atPath: u.path) ? u : nil
            }
            localBatches.append(urls + [info.shareText])
        }
        shareQueue = localBatches
        shareIndex = 0
        presentShareStep(localBatches[0])
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
            infoMessage = "选中的房源没有可分享的视频；视频若还在服务器，先下载到本地再分享"
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
