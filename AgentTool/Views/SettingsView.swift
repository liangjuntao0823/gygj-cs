import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

// v1.9：设置页滚动偏移监听——用 UIKit KVO 观察 Form 滚动容器的 contentOffset（不再往 Form 里塞标记行，
// 之前 v1.7/v1.8 用 Color.clear 行做滚动标记，即使行高压到 0 仍残留系统行占位，导致设置页顶部一大块空白）
private struct SettingsScrollViewReader: UIViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.backgroundColor = .clear
        DispatchQueue.main.async {
            // 沿 superview 链找到 Form 的滚动容器（UITableView/UICollectionView 均为 UIScrollView 子类）
            var view: UIView? = probe
            while let current = view {
                if let scroll = current as? UIScrollView {
                    context.coordinator.attach(scroll, onScroll: onScroll)
                    break
                }
                view = current.superview
            }
        }
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onScroll: ((CGFloat) -> Void)?
        private var observation: NSKeyValueObservation?

        func attach(_ scrollView: UIScrollView, onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            observation = scrollView.observe(\.contentOffset, options: [.new, .initial]) { [weak self] scrollView, _ in
                self?.onScroll?(scrollView.contentOffset.y)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.houseModelContext) private var houseModelContext
    @State private var showMessage = ""
    @State private var showAlert = false
    @State private var showClearSheet = false
    @State private var clearType: DataBackupManager.BackupType? = nil
    @State private var showClearConfirm = false
    @State private var showVersionHistory = false
    @State private var showMigration = false
    @State private var showBillTemplate = false
    @State private var showTrash = false   // v1.3：回收站入口从工作台移至设置页
    @State private var showTaskCenter = false   // 左上角常显按钮 → 任务中心
    // v2.21：在线更新（检查 / 自动检查开关 / 更新详情）
    @ObservedObject private var updateCenter = UpdateCenter.shared
    @State private var showUpdateDetail = false
    // v1.12：备份体系重构——统一备份/恢复入口（替代旧分板块备份/恢复；旧 JSON 备份在查看器中保留）
    @State private var showBackupKindSheet = false   // 备份方式选择（快速/全量）
    @State private var showOfflineRestoreConfirm = false   // v1.75：离线重建房源二次确认
    @State private var showBackupCenterBrowse = false // 备份文件查看器
    @State private var showBackupCenterRestore = false // 恢复选择器
    @State private var showLogsView = false           // 操作日志
    @State private var showCrashLogsView = false      // v1.17 需求2：崩溃日志查看器（内置，右上角导出 txt）
    // v2.7（P2⑯）：手动触发桶孤儿媒体清理
    @State private var showOrphanCleanConfirm = false
    @State private var orphanCleanResult: String?
    @State private var orphanCleaning = false
    @State private var orphanList: [HouseListView.OrphanMedia] = []   // b117：扫描到的孤儿清单
    @State private var showOrphanListConfirm = false                    // b117：列出清单后二次确认
    // v2.47：扫描进度弹窗
    @State private var scanFraction = 0.0
    @State private var scanStageText = ""
    @State private var orphanControl: HouseListView.OrphanScanControl?
    @State private var orphanScanBackgrounded = false
    @State private var orphanTaskID: UUID?
    @AppStorage("autoBackupRetentionDays") private var backupRetentionDays = 7   // 自动备份保留天数（默认7天，可调）
    @State private var autoBackupEnabled = false
    @State private var backupFrequency = "day"
    @State private var backupHour = 23
    @State private var settingsScrollY: CGFloat = 0   // v1.7：设置页滚动检测（顶部标题横线动态显示）
    // v1.6：房源分享设置合并进主设置（原房源板块独立设置页取消）
    @State private var showHouseCacheConfirm = false
    /// v1.98：AI 产物清空二级确认（设置页「AI对话缓存」行）
    @State private var showAICacheConfirm = false
    @State private var houseCacheTip: String?
    @State private var roomsLinkExpiry = 2   // v1.55：选房链接有效期（天），默认 2，onAppear 从 UserDefaults 读取
    @State private var compressOnShare = true   // v2.18 补：压缩开关改用显式状态，避免拨动后界面不刷新
    @State private var watermarkSubtitle = ""   // v1.41：分享水印入口副标题（onAppear 刷新，返回设置页即显示最新开关状态）
    // v1.84：电表监控设置（链接/数据源/阈值/定时刷新/提醒）
    @EnvironmentObject private var meterStore: MeterStore
    @State private var meterLinkInput = ""
    @State private var meterLinkTip: String?
    /// v2.18：全量备份进度（0~1）；nil = 没在跑。此前只有一句「正在生成全量备份…」，几十秒没反馈像卡死
    @ObservedObject private var backupProgress = FullBackupProgressHub.shared
    // b206：一级菜单「云端推送」副标题实时反映绑定账号、设备数与电表通知开关
    @ObservedObject private var notifyHub = NotifyHub.shared

    /// v1.41：刷新分享水印入口副标题（返回设置页 / 页面出现时读取最新 store，立即反映开关状态）
    private func refreshWatermarkSubtitle() {
        let wm = WatermarkSettingsStore.current
        watermarkSubtitle = wm.enabled ? "已开启 · \(wm.text)" : "已关闭"
    }
    @AppStorage("defaultElectricPrice") private var defaultElectricPrice = "0.8"
    @AppStorage("defaultWaterPrice") private var defaultWaterPrice = "5.5"
    @AppStorage("defaultUtilityPrepayment") private var defaultUtilityPrepayment = "0"

    private let backupManager = DataBackupManager.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// v2.21：检查更新右侧状态文案
    private func updateStatusText() -> String {
        switch updateCenter.checkState {
        case .checking: return "检查中…"
        case .failed: return "连不上云端"
        case .upToDate: return "已是最新"
        case .idle: return updateCenter.available == nil ? "" : "有新版本"
        }
    }

    /// v2.18：崩溃日志占用（入口右侧直接显示，不用点进去才知道占多大）
    private var crashLogBytes: Int {
        CrashLogCollector.totalBytes()
    }

    // MARK: - 组 1：账号与云端（v2.18 设置页重排）

    private var accountSection: some View {
        Section {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("我的用户名")
                        Text("操作日志 / 分享 / 统计都带这个名字；在「云端配置」里可下拉选云端已有的用户名")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.fill")
                }
                Spacer()
                Text(CloudUser.username.isEmpty ? "未设置" : CloudUser.username)
                    .font(.footnote)
                    .foregroundColor(CloudUser.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .red : .secondary)
            }
            NavigationLink {
                CosConfigView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("云端配置")
                        Text("COS 存储桶 / 密钥 / 自定义域名 / 云函数地址")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "server.rack")
                }
            }
            NavigationLink {
                AdminPasswordView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("管理后台口令")
                        Text("网页版登录用 · App 内自动免登录")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                }
            }
        } header: {
            Text("账号与云端")
        } footer: {
            Text("云端配置决定房源图片/视频传到哪个桶、分享卡片用哪个域名；配好后可导出部署包给别的房东自建后台。")
        }
    }

    // MARK: - 组 2：分享与展示

    private static let shareSectionFooter = "这一组只决定「分享出去的东西长什么样、有效期多久、要不要水印和压缩」。桶、密钥、域名在上一组「账号与云端」里。"
    private var shareSection: some View {
        Section {
            NavigationLink {
                ShareProfileView()
            } label: {
                Label("名片信息", systemImage: "person.crop.circle")
            }
            // v1.47：公开选房 H5——复制/分享给租客的实时选房链接（只显示户型，实时读云端账本）
            NavigationLink {
                RoomsShareView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("公开选房链接")
                        Text("实时读云端账本，租客自己挑房；有效期在下一行设")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "globe.asia.australia")
                }
            }
            // v1.55：选房链接有效期（默认 2 天，可动态调整）——到期后旧链接失效，需重新生成
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("选房链接有效期")
                        Text("只管「公开选房链接」；到期后旧链接失效，要重新生成")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.badge.xmark")
                }
                Spacer()
                Picker("", selection: $roomsLinkExpiry) {
                    Text("1 天").tag(1)
                    Text("2 天").tag(2)
                    Text("3 天").tag(3)
                    Text("7 天").tag(7)
                    Text("15 天").tag(15)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: roomsLinkExpiry) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "roomsLinkExpiryDays")
                    showMessage = "已设为 \(newValue) 天：下次「重新生成链接」按新有效期生效"
                    showAlert = true
                }
            }
            // v1.36 需求3：分享水印设置（开关/文本/字号/透明度/位置/预览/保存/清除）
            // v1.41：入口副标题改为 onAppear 刷新——从水印页返回设置页时立即显示最新开关状态
            NavigationLink {
                WatermarkSettingsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("分享水印")
                        Text(watermarkSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "camera.aperture")
                }
            }
            .onAppear { refreshWatermarkSubtitle() }
            // v2.18：压缩参数与实现对齐——图片长边 1600 + JPEG 0.8；视频长边 960、约 1 Mbps（v2.15 起）
            Toggle(isOn: Binding(
                get: { compressOnShare },
                set: { newValue in
                    compressOnShare = newValue
                    UserDefaults.standard.set(newValue, forKey: "compressOnShare")
                    // v2.68：压缩开关即时镜像给分享扩展（与 App 内上传同口径）
                    SharedBridge.defaults.set(newValue, forKey: SharedBridge.kCompress)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("压缩上传媒体（房源+分享）")
                    Text("图片长边压到 1600（JPEG 0.8）；视频长边压到 960、约 1 Mbps。只影响之后新上传的文件，已上传的不变。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // v2.18：从「刷新分享缓存」改名——实际是全量删除云端分享页后逐间重建
            Button {
                showHouseCacheConfirm = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重建全部分享链接")
                        Text("清掉云端旧分享页后逐间重建；已经发出去的旧链接会立即失效")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise.circle")
                }
            }
        } header: {
            Text("分享与展示")
        } footer: {
            Text(RemoteConfig.help("shareSectionFooter2", Self.shareSectionFooter))
        }
    }

    // MARK: - 组 6：存储与清理

    private var storageSection: some View {
        Section {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("数据文件夹大小")
                        Text("房源照片视频与备份都在这；整个文件夹拷走就是一份完整备份")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "externaldrive")
                }
                Spacer()
                Text(houseDocumentsSizeText())
                    .foregroundColor(.secondary)
            }
            // v1.98：AI 产物统一存沙盒根目录「AI产物」文件夹；单击二级确认后清空
            Button {
                showAICacheConfirm = true
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 产物（可清理）")
                            Text("AI 生成的账单图片、导出表格等；清空不影响对话记录与 App 数据")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles.rectangle.stack")
                    }
                    Spacer()
                    Text(aiCacheSizeText())
                        .foregroundColor(.secondary)
                }
            }
            // v2.7（P2⑯）：手动触发桶孤儿媒体清理——b117：先扫描列清单，用户确认后再删
            Button {
                startOrphanScan()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(orphanCleaning ? "正在扫描云端…" : "清理桶孤儿媒体")
                        Text("先列出孤儿名单+详细路径，确认后再删除；操作日志会记录")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "trash.circle")
                }
            }
            .disabled(orphanCleaning)

            // b117：列出孤儿清单的确认弹窗
            .alert("发现 \(orphanList.count) 个孤儿媒体", isPresented: $showOrphanListConfirm) {
                Button("取消", role: .cancel) { orphanList = [] }
                Button("确认删除", role: .destructive) {
                    orphanCleaning = true
                    Task {
                    await MediaActivityGate.shared.beginCleanup()
                    defer { Task { await MediaActivityGate.shared.endCleanup() } }
                        do {
                            guard let config = CosConfig.load() else {
                                orphanCleanResult = "请先在「云端配置」填写 COS 配置"
                                return
                            }
                            let list = orphanList
                            let deleted = await HouseListView.deleteOrphanMedia(list, config: config)
                            let paths = list.prefix(20).map { $0.path }.joined(separator: "\n")
                            let more = list.count > 20 ? "\n…等共 \(list.count) 个" : ""
                            BackupLogStore.log(category: "同步", action: "桶孤儿清理（手动）", result: deleted == list.count ? "成功" : "部分成功",
                                               detail: "删除 \(deleted)/\(list.count) 个：\n\(paths)\(more)", cloud: true)
                            orphanCleanResult = "已删除 \(deleted)/\(list.count) 个孤儿媒体（详见操作日志）"
                        } catch {
                            orphanCleanResult = "清理失败：\(error.localizedDescription)"
                        }
                        orphanList = []
                        orphanCleaning = false
                    }
                }
            } message: {
                let preview = orphanList.prefix(15).map { $0.path }.joined(separator: "\n")
                let more = orphanList.count > 15 ? "\n…等共 \(orphanList.count) 个" : ""
                Text("以下文件不在任何房源账本名单里，将被删除：\n\(preview)\(more)")
            }
            .alert("桶孤儿清理", isPresented: Binding(
                get: { orphanCleanResult != nil },
                set: { if !$0 { orphanCleanResult = nil } }
            )) {
                Button("好", role: .cancel) { orphanCleanResult = nil }
            } message: {
                Text(orphanCleanResult ?? "")
            }
            Button {
                openHouseDataFolder()
            } label: {
                Label("打开「文件」App 查看数据文件夹", systemImage: "folder")
            }
        } header: {
            Text("存储与清理")
        } footer: {
            Text("数据存放在「公寓管家」文件夹内的 backups / media 两个子文件夹；换机或重装时整个文件夹拷回原位即可还原。")
        }
    }

    // MARK: - 设置页 Section 分组（v1.6 拆分，避免 Form 表达式 type-check 超时）
    // v1.7：备份/恢复仅针对租房数据（成交/收租/包租/汇总/待办），房源数据走「房源分享 → 数据文件夹」整文件夹备份
    /// v1.11：打开「文件」App 直达房源数据 media 文件夹（Documents/备份/Media）。
    /// 优先直接打开该目录的 file:// URL（配合 LSSupportsOpeningDocumentsInPlace，iOS 会定位到该文件夹）；
    /// 个别系统版本不支持定位子目录时兜底打开文件 App 根目录。
    private func openHouseDataFolder() {
        let mediaURL = MediaStore.mediaDirectory()
        UIApplication.shared.open(mediaURL) { success in
            if !success, let root = URL(string: "shareddocuments://") {
                UIApplication.shared.open(root)
            }
        }
    }
    // MARK: - 组 3：备份与安全（v2.18 重排：备份/恢复/自动备份/迁移/日志/清空 归一处）

    private var backupSection: some View {
        Section {
            Button { showBackupKindSheet = true } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("备份数据")
                        Text("快速 = 账本 + 媒体清单（自动传云端）；全量 = 额外含全部房源与照片视频")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            Button { showBackupCenterRestore = true } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("恢复数据")
                        Text("从本机或云端备份还原，会覆盖当前数据；恢复前自动留一份安全备份")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用自动备份")
                        Text("到点自动存一份快速备份并传云端；错过会等下次打开 App 补做")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock")
                }
                Spacer()
                // v1.42：显式 Binding——set 时立即更新 @State 并落盘（与分享水印开关同款修法）
                Toggle("", isOn: Binding(
                    get: { autoBackupEnabled },
                    set: { newValue in
                        autoBackupEnabled = newValue
                        saveAutoSettings()
                    }
                ))
                .labelsHidden()
            }
            if autoBackupEnabled {
                HStack {
                    Label("备份频率", systemImage: "calendar")
                    Spacer()
                    Picker("", selection: $backupFrequency) {
                        Text("每天").tag("day")
                        Text("每周").tag("week")
                        Text("每月").tag("month")
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                    .labelsHidden()
                    .onChange(of: backupFrequency) { _, _ in saveAutoSettings() }
                }
                HStack {
                    Label("备份时间", systemImage: "timer")
                    Spacer()
                    Button { if backupHour > 0 { backupHour -= 1 } } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text(String(format: "%02d:00", backupHour))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(minWidth: 58)
                        .multilineTextAlignment(.center)
                    Button { if backupHour < 23 { backupHour += 1 } } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: backupHour) { _, _ in saveAutoSettings() }
                // v1.12：自动备份保留天数可配置（默认 7 天）；v1.13 需求9：天数放在 - + 号中间
                HStack {
                    Label("保留天数", systemImage: "archivebox")
                    Spacer()
                    Button { if backupRetentionDays > 1 { backupRetentionDays -= 1 } } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text("\(backupRetentionDays) 天")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(minWidth: 58)
                        .multilineTextAlignment(.center)
                    Button { if backupRetentionDays < 60 { backupRetentionDays += 1 } } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: backupRetentionDays) { _, _ in saveAutoSettings() }
            }
            // v1.12：备份文件查看器（快速/全量 zip + 云端 + 旧版 JSON）
            Button { showBackupCenterBrowse = true } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("备份文件管理")
                        Text("查看本机 / 云端备份，可上传、下载、删除；要恢复到手机请点上面「恢复数据」。旧版 JSON 备份也在这里")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                }
            }
            Button { showMigration = true } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("换机迁移")
                        Text("导出 .zfgj 迁移包拷到新手机，一次性复制；不是日常同步")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone.and.arrow.forward")
                }
            }
            NavigationLink {
                MediaPendingView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待补传媒体")
                        Text("上传失败的图片视频排在这里，逐个重试")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise.icloud")
                }
            }
            // v1.75：离线重建房源——无需联网，从本地账本（media/<房号>/info.json）重建房源记录
            // v1.80：入口显隐由云端远程配置控制（features.showOfflineRestore），小字说明也可云端改
            if RemoteConfig.feature("showOfflineRestore", true) {
                VStack(alignment: .leading, spacing: 3) {
                    Button { showOfflineRestoreConfirm = true } label: {
                        Label("离线重建房源", systemImage: "arrow.clockwise.circle")
                    }
                    Text(RemoteConfig.help("offlineRestoreIntro", "无需联网：从本机 media 文件夹的账本（每套 info.json）重建房源记录，数据库丢失或断网时可用，不删除现有数据。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // v1.12：操作日志（备份/恢复/上传/删除/同步）
            Button { showLogsView = true } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("操作日志")
                            Text("备份 / 恢复 / 上传 / 删除 / 同步的流水，本机区 + 云端区")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(BackupLogStore.sizeBytes()), countStyle: .file))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            // v1.12：崩溃日志（自建日志文件，不依赖第三方）v1.17 需求2：内置查看器 + 右上角导出
            // v2.18：入口右侧显示占用；查看器里新增「清理全部」
            Button { showCrashLogsView = true } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("崩溃日志")
                            Text("App 异常退出时自动记录，可查看、导出、清理")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "ladybug")
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(crashLogBytes), countStyle: .file))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            // v1.14 需求7：清空数据放在本组末位（危险操作始终在组末、红字）
            Button { showClearSheet = true } label: {
                HStack {
                    Label("清空数据", systemImage: "trash")
                        .foregroundColor(.red)
                    Spacer()
                    Text("按板块清空")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("备份与安全")
        } footer: {
            Text(RemoteConfig.help("backupIntro2", "快速备份只含账本 + 媒体清单（不含房源记录与照片视频文件，自动传云端）；全量备份才含全部房源与照片视频（体积大，需在备份文件管理里手动传云端）。恢复会覆盖当前数据，恢复前自动打包当前数据做安全备份，失败自动还原。自动备份固定走快速备份。"))
        }
    }

    // MARK: - 组 4：账单与默认值

    private var defaultsSection: some View {
        Section {
            HStack {
                Label("电费单价", systemImage: "bolt")
                Spacer()
                TextField("0.8", text: $defaultElectricPrice)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            HStack {
                Label("水费单价", systemImage: "drop")
                Spacer()
                TextField("5.5", text: $defaultWaterPrice)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            HStack {
                Label("默认总预存", systemImage: "wallet.pass")
                Spacer()
                TextField("0", text: $defaultUtilityPrepayment)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            Button { showBillTemplate = true } label: {
                HStack {
                    Label("账单模板设置", systemImage: "textformat.alt")
                    Spacer()
                    Text("文本/收款码/预览")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("账单与默认值")
        } footer: {
            Text("这三个默认值是「水电结算」页的默认单价与预存，打开结算页自动填入；不影响已生成的结算记录，也不影响房源租金。")
        }
    }

    // MARK: - 组 5：外部服务（电表监控 / 安居客后台 / AI 助手）

    private var servicesSection: some View {
        Section {
            NavigationLink {
                NotifyHubSettingsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("云端推送通道")
                        Text("账号隔离 · 多设备 Bark · 电表/到期/收租")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bell.badge.fill")
                }
            }
            NavigationLink {
                MeterSettingsDetailView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("电表监控")
                        Text(meterStore.settings.openId.isEmpty ? "未配置链接" : (meterStore.settings.provider == .webView ? "网页抓取" : "直连接口"))
                            .font(.caption2)
                            .foregroundStyle(meterStore.settings.openId.isEmpty ? Color.red : Color.secondary)
                    }
                } icon: {
                    Image(systemName: "bolt.batteryblock.fill")
                }
            }
            NavigationLink {
                AjkSettingsDetailView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安居客后台")
                        Text("推广房源抓取 · 实地核验 / 下架预警")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "building.2.fill")
                }
            }
            NavigationLink {
                AIAssistantSettingsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 助手")
                        Text(KeychainHelper.exists(key: "ai.volcengine.apiKey") ? "已配置 API Key" : "未配置 Key")
                            .font(.caption2)
                            .foregroundStyle(KeychainHelper.exists(key: "ai.volcengine.apiKey") ? Color.secondary : Color.red)
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
        } header: {
            Text("外部服务")
        } footer: {
            Text("电表监控只读取展示电量（充值仍走官方页面）；安居客后台只读抓取推广房源、不做发布；AI 助手走你自己的火山方舟 Key——Key 只存本机钥匙串，不上传、不随备份上传。")
        }
    }


    private var aboutSection: some View {
        Section {
            HStack {
                Label("应用名称", systemImage: "app")
                Spacer()
                Text("公寓管家")
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("版本", systemImage: "number")
                Spacer()
                Text("\(appVersion) (\(UpdateCenter.appBuild))")
                    .foregroundColor(.secondary)
                if let a = updateCenter.available {
                    Text("可更新 \(a.version)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(5)
                }
            }
            Button {
                Task { await updateCenter.checkManually() }
            } label: {
                HStack {
                    Label("检查更新", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(updateStatusText())
                        .font(.footnote)
                        .foregroundColor(updateCenter.checkState == .failed ? .red : .secondary)
                }
            }
            .disabled(updateCenter.checkState == .checking)
            if let a = updateCenter.available {
                Button {
                    showUpdateDetail = true
                } label: {
                    HStack {
                        Label("发现新版本 v\(a.version)", systemImage: "sparkles")
                            .foregroundColor(.orange)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Toggle(isOn: Binding(
                get: { UpdateCenter.autoCheckEnabled },
                set: { UpdateCenter.autoCheckEnabled = $0 }
            )) {
                Label("启动时自动检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            HStack {
                Label("开发者", systemImage: "person")
                Spacer()
                Text("豆包And涛哥")
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("软件说明", systemImage: "doc.text")
                Spacer()
                Text("公寓出租与招租管理平台")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Label("数据安全", systemImage: "lock.shield")
                Spacer()
                Text("房源与账本默认只在本机；只有你主动同步、备份、生成分享链接时才联网")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button { showVersionHistory = true } label: {
                HStack {
                    Label("版本更新介绍", systemImage: "doc.plaintext")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            settingsFormFull
        }
        .overlay {
            if orphanCleaning && !orphanScanBackgrounded {
                OrphanScanProgressOverlay(
                    fraction: scanFraction, stage: scanStageText,
                    onBackground: { orphanScanBackgrounded = true },
                    onCancel: { Task { await orphanControl?.cancel() } })
            }
        }
    }

    /// v1.6：设置页主体拆为独立属性（避免 body 表达式 type-check 超时）
    /// v1.7：tint 改为 iOS 原生蓝（房源管家风格设置页配色）；顶部横线随滚动动态显示
    /// v2.18：再拆三层——分组 / 视觉层 / 导航与弹窗。7 组内容叠在一条表达式上会让编译器 type-check 超时
    private var settingsForm: some View {
        settingsFormChrome
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(showMessage)
            }
            // v1.12：备份方式选择（快速备份=账本+媒体清单自动传云端；全量备份=含照片视频）
            .confirmationDialog("选择备份方式", isPresented: $showBackupKindSheet, titleVisibility: .visible) {
                Button("快速备份（推荐）") { performNewBackup(kind: .fast) }
                Button("全量备份（含照片视频）") { performNewBackup(kind: .full) }
                Button("取消", role: .cancel) { }
            } message: {
                Text("快速备份：账本 + 媒体清单（不含房源与照片视频文件），备份后自动上传云端；房源从云端同步恢复。\n全量备份：账本 + 房源 + 全部照片视频，备份后可在「备份文件管理」中手动上传云端。")
            }
            .alert("离线重建房源", isPresented: $showOfflineRestoreConfirm) {
                Button("取消", role: .cancel) { }
                Button("开始重建") { runOfflineRestore() }
            } message: {
                Text("将扫描本机 media 文件夹中的所有账本（每套 info.json）并重建房源记录。无需联网；已有房源按账本刷新，缺失房源自动补齐，不删除任何现有数据。")
            }
            .confirmationDialog("选择要清空的板块", isPresented: $showClearSheet, titleVisibility: .visible) {
                Button("清空成交数据") { clearType = .deals; showClearConfirm = true }
                Button("清空收租数据") { clearType = .properties; showClearConfirm = true }
                Button("清空包租数据") { clearType = .payouts; showClearConfirm = true }
                Button("清空全部数据", role: .destructive) { clearType = .total; showClearConfirm = true }
                Button("取消", role: .cancel) { }
            }
            .alert("确认清空", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) { clearType = nil }
                Button("确定清空", role: .destructive) {
                    if let type = clearType {
                        clearData(type: type)
                    }
                    clearType = nil
                }
            } message: {
                if let type = clearType {
                    Text(type == .total ? "确定要清空所有数据吗？此操作不可恢复，建议先备份数据。" : "确定要清空\(type == .deals ? "成交数据" : type == .properties ? "收租数据" : "包租数据")吗？此操作不可恢复。")
                } else {
                    Text("")
                }
            }
    }

    /// 开扫：建控制令牌与中心任务，注册重试入口（重试时整体重新建一套）
    @MainActor
    private func startOrphanScan() {
        orphanCleaning = true
        orphanScanBackgrounded = false
        scanFraction = 0
        let control = HouseListView.OrphanScanControl()
        orphanControl = control
        orphanTaskID = SyncTaskCenter.shared.begin(
            kind: .orphan, title: "清理桶孤儿媒体", total: 1)
        TaskRetryPerformer.shared.orphanScan = {
            await startOrphanScanAndRun()
        }
        Task {
            await MediaActivityGate.shared.beginCleanup()
            defer { Task { await MediaActivityGate.shared.endCleanup() } }
            await runOrphanScan(control: control)
        }
    }

    /// 重试入口：重新建一套令牌与任务再跑
    @MainActor
    private func startOrphanScanAndRun() async {
        orphanCleaning = true
        orphanScanBackgrounded = false
        scanFraction = 0
        let control = HouseListView.OrphanScanControl()
        orphanControl = control
        orphanTaskID = SyncTaskCenter.shared.begin(
            kind: .orphan, title: "清理桶孤儿媒体", total: 1)
        await MediaActivityGate.shared.beginCleanup()
        defer { Task { await MediaActivityGate.shared.endCleanup() } }
        await runOrphanScan(control: control)
    }

    /// 孤儿扫描主流程（手动触发与任务中心重试共用）。
    /// 取消：立即停止扫描，一个文件都不删，进最近完成并写明已取消。
    @MainActor
    private func runOrphanScan(control: HouseListView.OrphanScanControl) async {
        guard let id = orphanTaskID else { return }
        do {
            guard let config = CosConfig.load() else {
                orphanCleanResult = "请先在「云端配置」填写 COS 配置"
                SyncTaskCenter.shared.finish(id: id, success: false,
                                            failure: "没读到 COS 配置，先到「云端配置」填好再重试")
                orphanCleaning = false
                return
            }
            let list = try await HouseListView.scanOrphanMedia(config: config, control: control) { done, total, room in
                Task { @MainActor in
                    scanFraction = Double(done) / Double(max(1, total))
                    scanStageText = room.isEmpty ? "正在列桶…" : "正在核对 \(room)（\(done)/\(total)）"
                    SyncTaskCenter.shared.advance(id: id, done: done, total: max(1, total),
                                                  note: "正在核对 \(room)")
                }
            }
            if await control.isCancelled {
                // 取消本次：停止扫描，不删任何文件
                SyncTaskCenter.shared.cancel(id: id, note: "已取消本次扫描，未删除任何文件")
                orphanCleanResult = "已取消本次扫描，未删除任何文件"
            } else if list.isEmpty {
                orphanCleanResult = "扫描完成：没有发现孤儿媒体"
                SyncTaskCenter.shared.finish(id: id, success: true, note: "没有发现孤儿媒体")
            } else {
                orphanList = list
                SyncTaskCenter.shared.finish(id: id, success: true,
                                            note: "发现 \(list.count) 个孤儿，确认名单后再删")
                showOrphanListConfirm = true
            }
        } catch {
            orphanCleanResult = "扫描失败：\(error.localizedDescription)"
            SyncTaskCenter.shared.finish(id: id, success: false,
                                        failure: "扫描失败：\(error.localizedDescription)，点重试")
        }
        orphanCleaning = false
    }

    /// 导航栏（回收站入口）与进入页面时的初始化
    private var settingsFormChrome: some View {
        settingsFormVisual
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 任务中心：左上角常显按钮（不单独起栏目）
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showTaskCenter = true
                    } label: {
                        Image(systemName: "list.bullet.clipboard")
                    }
                    .accessibilityLabel("同步任务中心")
                }
                // 回收站入口在右上角：只留垃圾桶图标，不显示文字
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTrash = true
                    } label: {
                        Image(systemName: "trash.fill")
                    }
                    .accessibilityLabel("回收站")
                }
            }
            .sheet(isPresented: $showTaskCenter) {
                TaskCenterView()
            }
            .onAppear {
                loadAutoSettings()
                compressOnShare = shareCompressionEnabled   // v2.18：压缩开关初值（进页面读当前设置）
                backupProgress.value = nil   // v2.18：进页面时进度 HUD 一定不残留
                // v1.55：读取选房链接有效期设置（默认 2 天）
                let d = UserDefaults.standard.integer(forKey: "roomsLinkExpiryDays")
                roomsLinkExpiry = d > 0 ? d : Int(RemoteConfig.param("roomsLinkExpiryDays", 2))
            }
    }

    /// v2.23：一级菜单行（图标 + 标题 + 一行说明 + 自带箭头），点进二级页
    private func settingsRow<Destination: View>(_ title: String, icon: String, subtitle: String,
                                                @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon)
            }
        }
    }

    /// 表单本体（7 组）+ 滚动监听 + 主题色 + 顶部两条 overlay
    private var settingsFormVisual: some View {
        Form {
                // v2.23：前 6 组改成一级菜单，内容进二级页；最下面「关于」保持原样
                Section {
                    settingsRow("账号与云端", icon: "person.crop.circle",
                                subtitle: "我的用户名 · 云端配置（桶/密钥/域名）· 管理后台口令") { AccountSettingsPage() }
                    settingsRow("分享与展示", icon: "square.and.arrow.up",
                                subtitle: "名片 · 公开选房链接 · 有效期 · 水印 · 压缩 · 重建分享链接") { ShareSettingsPage() }
                    settingsRow("备份与安全", icon: "externaldrive.badge.checkmark",
                                subtitle: "备份 / 恢复 · 自动备份 · 备份文件管理 · 崩溃日志 · 清空数据") { BackupSettingsPage() }
                    settingsRow("账单与默认值", icon: "yensign.circle",
                                subtitle: "电费 / 水费单价 · 默认预存 · 账单模板") { DefaultsSettingsPage() }
                    settingsRow("外部服务", icon: "antenna.radiowaves.left.and.right",
                                subtitle: "电表监控 · 安居客后台 · AI 助手") { ServicesSettingsPage() }
                    settingsRow("云端推送", icon: "bell.badge.fill",
                                subtitle: notifyHub.isBound
                                    ? "\(notifyHub.username.isEmpty ? "已绑定" : notifyHub.username) · \(notifyHub.devices.count) 台设备 · 电表通知\(notifyHub.channelEnabled && notifyHub.meterModuleEnabled ? "开" : "关")"
                                    : "未绑定 · 电表告警 / 将来到期收租通知") { CloudPushSettingsView() }
                    settingsRow("存储与清理", icon: "internaldrive",
                                subtitle: "数据文件夹 · AI 产物 · 下载的安装包 · 桶孤儿媒体") { StorageSettingsPage() }
                    // v2.51：电梯码（全屏展示 + 更换 + 一键打开方式）
                    settingsRow("电梯码", icon: "qrcode",
                                subtitle: "全屏展示 · 更换二维码 · 一键打开方式") { ElevatorCodeSettingsPage() }
                } header: {
                    Text("设置")
                } footer: {
                    Text("点分组进对应的二级页；最下面「关于」仍是本机版本、检查更新与更新介绍。")
                }
                aboutSection
            }
            .task {
                // 进入设置页静默刷新推送账号档案（开关/设备数/最近投递）；失败保留本机缓存展示
                if NotifyHub.shared.isBound { await NotifyHub.shared.refreshMe() }
            }
            // v1.9：背景挂载滚动监听（不占任何 Form 行/间距，顶部不再有空白行）
            .background(
                SettingsScrollViewReader { y in
                    settingsScrollY = y
                }
            )
            .tint(Color(red: 0.0, green: 0.478, blue: 1.0))   // iOS 系统蓝 #007AFF
            .overlay(alignment: .top) {
                // v1.7：页面在顶部时不显示横线；向下滑动（顶栏固定）才出现分隔线
                Rectangle()
                    .fill(Color.themeBorder)
                    .frame(height: 0.5)
                    .opacity(settingsScrollY < -1 ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: settingsScrollY < -1)
            }
            // v2.18：全量备份进度胶囊（顶部悬浮，百分比实时刷新；结束自动消失）
            .overlay(alignment: .top) {
                if let p = backupProgress.value {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在生成全量备份 \(Int(min(max(p, 0), 1) * 100))%")
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.themeBorder, lineWidth: 0.5))
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                }
            }
    }

    /// v1.12：挂载链拆分（避免单一表达式 type-check 超时）
    private var settingsFormFull: some View {
        settingsForm
            .sheet(isPresented: $showUpdateDetail) {
                if let a = updateCenter.available { UpdateDetailView(update: a) }
            }
            .sheet(isPresented: $showVersionHistory) {
                VersionHistoryView()
            }
            .sheet(isPresented: $showMigration) {
                MigrationView()
            }
            .sheet(isPresented: $showBillTemplate) {
                BillTemplateSettingsView()
            }
            .sheet(isPresented: $showTrash) {
                TrashView()
            }
            // v1.12：备份文件查看器（快速/全量 zip + 云端备份 + 旧版 JSON）
            .sheet(isPresented: $showBackupCenterBrowse) {
                BackupFileBrowseViewV5(mode: .browse)
            }
            // v1.12：恢复选择器（本地 zip / 云端备份 / 旧版 JSON）
            .sheet(isPresented: $showBackupCenterRestore) {
                BackupFileBrowseViewV5(mode: .restore)
            }
            // v1.12：操作日志
            .sheet(isPresented: $showLogsView) {
                BackupLogsView()
            }
            // v1.12：崩溃日志（v1.17 需求2：内置查看器，右上角导出 txt 到 App 根目录）
            .sheet(isPresented: $showCrashLogsView) {
                CrashLogsView()
            }
            // v1.12：备份中心消息通道（查看器/恢复器内的提示复用本页 alert）
            .onReceive(NotificationCenter.default.publisher(for: .backupCenterMessage)) { note in
                if let text = note.userInfo?["message"] as? String {
                    showMessage = text
                    showAlert = true
                }
            }
            // v1.6：房源分享缓存刷新（二级确认，防止误触导致全部链接失效）
            // v1.54：升级为「全量重建」——云端旧分享页全部删除（旧链接立即失效），并给每间房重新生成最新 H5
            .confirmationDialog("重建全部房源分享链接", isPresented: $showHouseCacheConfirm, titleVisibility: .visible) {
                Button("清空并重建全部", role: .destructive) {
                    ShareCacheStore.clearAll()
                    rebuildAllShareH5()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将重建全部房源的分享链接：云端旧分享页全部删除（旧链接立即失效），并为每间房重新生成最新 H5。确定继续吗？")
            }
            .alert("重建全部分享链接", isPresented: Binding(
                get: { houseCacheTip != nil },
                set: { if !$0 { houseCacheTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(houseCacheTip ?? "")
            }
            // v1.98：AI 对话缓存清空（二级确认，删除「AI产物」文件夹全部内容）
            .alert("清空 AI 产物？", isPresented: $showAICacheConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    AIToolExecutor.clearAIArtifacts()
                    showMessage = "AI 产物已清空"
                    showAlert = true
                }
            } message: {
                Text("将删除「AI产物」文件夹里的全部账单图片与导出表格（AI 对话历史与 App 数据不受影响）。确定清空吗？")
            }
    }

    // MARK: - 逻辑

    // v1.54：全量重建全部房源的脱敏版分享 H5——
    // 云端旧分享页全部删除（旧链接立即失效）+ 每间房重新生成最新 H5（无媒体房源只删旧页不生成）
    private func rebuildAllShareH5() {
        guard let ctx = houseModelContext,
              let config = CosConfig.load(), config.isValid else {
            houseCacheTip = "请先到「云端配置」填写 COS 配置并验证通过"
            return
        }
        let houses = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        let active = houses.filter { !($0.isDeleted ?? false) }
        let profile = CosUploader.loadShareProfile()
        // 主线程先拷贝全部值类型，Task 内不再触碰 SwiftData 模型
        let items = active.map { h -> (files: [ShareMediaFile], roomKey: String, info: ShareHouseInfo) in
            (
                h.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) },
                h.mediaRoomKey,
                ShareHouseInfo(
                    displayRoomNo: h.displayRoomNo,
                    towerLabel: h.towerLabel,
                    layout: h.layout,
                    statusLabel: h.status.label,
                    priceText: h.priceText,
                    landlord: h.landlord,
                    password: h.password,
                    remark: h.remark,
                    name: profile.name,
                    phone: profile.phone
                )
            )
        }
        houseCacheTip = "正在重建 \(active.count) 套房源的分享链接…"
        Task {
            var ok = 0, fail = 0
            for it in items {
                do {
                    _ = try await CosUploader.autoRegenerateMaskedShare(mediaFiles: it.files, roomKey: it.roomKey, info: it.info, config: config)
                    ok += 1
                } catch {
                    fail += 1
                }
            }
            await MainActor.run {
                houseCacheTip = "分享链接已全部重建：\(ok) 间成功" + (fail > 0 ? "，\(fail) 间失败（可再次刷新重试）" : "") + "\n旧分享链接已全部失效"
            }
        }
    }

    // v1.75：离线重建房源——无需联网，从本机 media 账本（每套 info.json）重建/刷新房源记录
    private func runOfflineRestore() {
        guard let houseCtx = houseModelContext else {
            showMessage = "房源数据容器不可用，请重启 App 后重试"
            showAlert = true
            return
        }
        let n = LocalHouseLedger.restoreAll(houseContext: houseCtx)
        if n > 0 {
            showMessage = "离线重建完成：已从本地账本恢复 \(n) 套房源"
            showAlert = true
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        } else {
            showMessage = "未找到本地账本（media 文件夹中没有 info.json）。请先联网同步一次生成账本，或使用「恢复数据」。"
            showAlert = true
        }
    }

    // v1.12：统一备份（快速/全量），复用备份中心逻辑
    private func performNewBackup(kind: BackupKindV5) {
        guard let houseCtx = houseModelContext else {
            showMessage = "房源数据容器不可用，请重启 App 后重试"
            showAlert = true
            return
        }
        if kind == .fast {
            if let url = BackupV5Manager.createFastBackup(mainContext: modelContext, houseContext: houseCtx) {
                BackupLogStore.log(category: "备份", action: "快速备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                Task {
                    await CloudBackupService.autoUploadFastBackup(zipURL: url, config: nil)
                }
                showMessage = RemoteConfig.tip("quickBackupOk", "快速备份成功：{file}\n已自动上传云端（若网络失败会在下次打开 App 时自动重试）").replacingOccurrences(of: "{file}", with: url.lastPathComponent)
            } else {
                showMessage = "快速备份失败，请检查存储空间"
            }
            showAlert = true
        } else {
            if !BackupV5Manager.hasFreeSpace(needed: BackupV5Manager.collectMediaFileEntries().reduce(0) { $0 + (BackupV5Manager.fileSize(at: $1.fileURL)) }) {
                showMessage = RemoteConfig.tip("fullBackupSpace", "存储空间不足，全量备份至少需要与照片视频等量的剩余空间")
                showAlert = true
                return
            }
            backupProgress.value = 0
            Task {
                let url = await BackupV5Manager.createFullBackup(mainContext: modelContext, houseContext: houseCtx) { p in
                    // createFullBackup 内部已切回主线程回调，这里直接写进度枢纽
                    FullBackupProgressHub.shared.value = p
                }
                await MainActor.run {
                    backupProgress.value = nil
                    if let url = url {
                        BackupLogStore.log(category: "备份", action: "全量备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                        showMessage = RemoteConfig.tip("fullBackupOk2", "全量备份成功：{file}\n可在「备份文件管理」中手动上传到云端").replacingOccurrences(of: "{file}", with: url.lastPathComponent)
                    } else {
                        showMessage = "全量备份失败，请检查存储空间"
                    }
                    showAlert = true
                }
            }
        }
    }

    // v1.17 需求2：崩溃日志改为内置查看器（CrashLogsView），此函数不再使用，删除以避免系统分享表单空白。
    // 原逻辑：无日志时提示；有日志则弹系统分享面板（UIActivityViewController 在部分机型空白）。

    // 清空数据
    private func clearData(type: DataBackupManager.BackupType) {
        let success: Bool
        switch type {
        case .deals: success = backupManager.clearDeals(modelContext: modelContext)
        case .properties: success = backupManager.clearProperties(modelContext: modelContext)
        case .payouts: success = backupManager.clearPayouts(modelContext: modelContext)
        case .total: success = backupManager.clearAll(modelContext: modelContext)
        }
        showMessage = success ? (type == .total ? "全部数据已清空" : "\(type.rawValue)已清空") : "清空失败，原数据已保留，请重试"
        showAlert = true
    }

    private func saveAutoSettings() {
        let previous = UserDefaults.standard.data(forKey: "autoBackupSettings").flatMap { try? JSONDecoder().decode(AutoBackupSettings.self, from: $0) }
        let settings = AutoBackupSettings(enabled: autoBackupEnabled, frequency: backupFrequency, hour: backupHour, minute: 0, lastBackupDate: previous?.lastBackupDate)
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "autoBackupSettings")
            UserDefaults.standard.removeObject(forKey: "autoBackupCompletedSlot")
            UserDefaults.standard.synchronize()
            NotificationCenter.default.post(name: .autoBackupSettingsChanged, object: nil)
        }
    }

    private func loadAutoSettings() {
        if let data = UserDefaults.standard.data(forKey: "autoBackupSettings"),
           let settings = try? JSONDecoder().decode(AutoBackupSettings.self, from: data) {
            autoBackupEnabled = settings.enabled
            backupFrequency = settings.frequency
            backupHour = settings.hour
        }
    }
}

// MARK: - v1.17 需求2 崩溃日志内置查看器（替代系统分享面板；右上角导出 txt 到 App 根目录）

struct CrashLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files = CrashLogCollector.logFiles()
    @State private var exportTip: String?
    /// v2.18：清理功能（此前只增不删，日志会一直堆着）
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    Text("暂无崩溃日志")
                        .foregroundColor(.secondary)
                } else {
                    // v2.18：顶部显示条数与总占用，清理前心里有数
                    Section {
                        HStack {
                            Text("共 \(files.count) 个")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(CrashLogCollector.totalBytes()), countStyle: .file))
                                .foregroundColor(.secondary)
                        }
                        .font(.footnote)
                    }
                    ForEach(files, id: \.self) { file in
                        NavigationLink {
                            CrashLogDetailView(fileURL: file)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Text(firstLine(of: file))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("崩溃日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                // v1.17 需求2：右上角「导出」→ 直接生成崩溃日志 txt 到 App 根目录（Documents）
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        // v2.18：清理全部（二次确认，只删 Crash*.txt，不动操作日志与备份）
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(files.isEmpty)
                        Button("导出") { exportAll() }
                            .disabled(files.isEmpty)
                    }
                }
            }
            .alert("清理全部崩溃日志？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("全部清除", role: .destructive) {
                    let removed = CrashLogCollector.deleteAll()
                    files = CrashLogCollector.logFiles()
                    exportTip = "已清除 \(removed) 个崩溃日志"
                }
            } message: {
                Text("将删除本机全部崩溃日志（\(files.count) 个），不影响操作日志、备份与房源数据。删除后不可恢复。")
            }
            .alert("导出崩溃日志", isPresented: Binding(
                get: { exportTip != nil },
                set: { if !$0 { exportTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportTip ?? "")
            }
        }
    }

    /// 取日志首行摘要（时间/异常标题）
    private func firstLine(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
    }

    /// v1.17 需求2：把所有崩溃日志合并导出为一个 txt，命名「崩溃日志_导出日期.txt」，落盘 App 根目录
    private func exportAll() {
        guard !files.isEmpty else {
            exportTip = "暂无崩溃日志可导出"
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "崩溃日志_\(df.string(from: Date())).txt"
        var lines = ["公寓管家 · 崩溃日志", "导出时间：\(Date())", "共 \(files.count) 份", "=================="]
        for url in files {
            lines.append("")
            lines.append("【\(url.lastPathComponent)】")
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "(读取失败)"
            lines.append(body)
        }
        let fileURL = DataRoot.url().appendingPathComponent(fileName)
        do {
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            exportTip = "已导出到：\n\(fileURL.lastPathComponent)\n\n（App 根目录 / 数据文件夹）"
        } catch {
            exportTip = "导出失败：\(error.localizedDescription)"
        }
    }
}

/// 单份崩溃日志详情（展示完整内容）
struct CrashLogDetailView: View {
    let fileURL: URL
    @State private var content = ""

    var body: some View {
        ScrollView {
            Text(content.isEmpty ? "（内容读取失败或为空）" : content)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }
}

// MARK: - v1.17 需求10 三端互通详细介绍及使用说明

struct InterconnectionInfoView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("你的公寓管家由三个端协同工作：")
                        .font(.subheadline)
                    Text("① 手机 App（本地经营数据 + 房源分享）\n② 腾讯云函数 gongyu-stats（云端统计与后台网关）\n③ 云端后台网页（网页 / App 内打开的后台）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("三端是什么")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 每次生成新的分享 H5 链接，访客点开时页面会自动、静默地向云函数发一次访问记录（房号 + 模式 + 来源）。").font(.footnote)
                    Text("• 云函数把记录追加写入云端桶 statistics/ 下的按日文件，后台的获客统计由这些真实记录聚合而来。").font(.footnote)
                    Text("• 房源文字 + 媒体存云端桶 h/；云端操作记录（带用户名）存 h/_ops.json，同桶多用户可见是谁在操作。").font(.footnote)
                    Text("• 后台可「清空访问统计」一键删除所有埋点记录（含 test101 等测试数据）。").font(.footnote)
                }
            } header: {
                Text("数据是怎么流动的")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• App 内「管理后台」= 云端后台网页，直接用 App 打开，免登录（自动带口令哈希）。").font(.footnote)
                    Text("• 网页版打开同一地址需输入后台口令。口令可在 App 设置里修改，保存后自动同步到云函数与云端后台。").font(.footnote)
                    Text("• 分享记录按用户名隔离存云端桶（h/_share_records_<用户名>.json），各用户只看自己发的分享。").font(.footnote)
                    Text("• 桶文件管理逐级浏览，点进房源文件夹会自动展开 media/ 直接看媒体文件；顶部有「储存用量」卡片显示总占用与分项。").font(.footnote)
                }
            } header: {
                Text("后台怎么打开")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 单用户：填好云函数地址 + 桶配置 + 用户名即可，房源/备份自动上传云端，后台看统计与用量。").font(.footnote)
                    Text("• 多用户：几台手机填同一套桶配置、各自填不同用户名，房源云端共享（一台录入另一台下拉同步可见）；名片/水印/统计/备份按用户名隔离，互不读取。").font(.footnote)
                    Text("• 操作日志分「本机 / 云端」两区：本机操作记本地，本机发起的云端操作记到云端区；云端区显示操作者用户名。").font(.footnote)
                }
            } header: {
                Text("单用户 / 多用户")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 分享 H5 的缓存存在本地，「刷新分享缓存」只清理本机缓存，不影响云端。").font(.footnote)
                    Text("• 房源板块下拉刷新 / 左上角手动同步都是拉取云端房源到本地，效果一致。").font(.footnote)
                    Text("• 云端后台每个板块顶部有「刷新」按钮；操作日志云端区可下拉刷新。").font(.footnote)
                    Text("• 版本更新记录在「设置 → 关于」查看；本说明随 v1.37 提供。").font(.footnote)
                }
            } header: {
                Text("缓存与刷新")
            }
        }
        .navigationTitle("三端互通说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 版本更新介绍
struct VersionHistoryView: View {
    // v2.29：进页面先拉一次云端配置再渲染——此前只在「同步云端房源」和“检查更新”时刷新，
    // 装完新版打开设置看版本记录，看到的还是安装时那份旧缓存，云端新条目要等下次启动才出现。
    // v2.30：去掉 .id(cloudTick) ——刷新完 tick+1 会重建视图、重建又触发 .task，形成无限循环，
    //        界面就一直卡在「正在同步云端更新记录…」；改为把云端条目存进本地 @State 驱动刷新。
    @State private var cloudEntries: [RemoteConfig.ChangelogEntry] = RemoteConfig.changelog ?? []
    @State private var cloudLoading = false
    @State private var cloudFailed = false
    @State private var didLoadCloud = false
    let versions: [(version: String, date: String, changes: [String])] = [
        ("v2.72", "2026-11-22", [
            "修复：【首期晚于当前月的房源，首期打勾后卡片仍挂「待收」、工作台还催上一月】——未收判定和应收期全部改为直接读取收租计划（月度收租记录），计划没覆盖的月份不再被当成欠租：首期之前不催租，首期已交、下期尚远显示已收；同时对齐桌面小组件未收计数、本地推送提醒、AI 欠租清单和导出表的本月状态，口径与收租计划一致",
            "修复：【账单带附加费时首次弹出的分享面板一片空白，关掉重开第二次才正常】——账单分享面板改为从最顶层控制器直呈（与房源分享视频同一套直呈写法），不再套在刚收起的附加费表单弹层上；账单图仍先压成 JPEG 临时文件再交给系统分享，大图不卡死",
            "说明：版本 2.72 / 202，收租计划生成、表单录入、打勾写库、包租付租提醒、租期到期提醒、水电结算口径全部不变",
        ]),
        ("v2.71", "2026-11-21", [
            "优化：【共享面板开场不再拉全量云端房号等十几秒】——打开只给房号输入框（零联网），点「查重」只请求这一个房号、秒回：云端没有→展开与 App 内新增同要素的表单（座号/房号/租金/房东/户型/密码/备注/状态）新增上传；已有→提示有无媒体，无媒体直接补传，有媒体先「调取预览」（图片网格+视频播放）再选保留旧媒体补传或清旧传新",
            "修复：【分享新增只上云、本机没有】——每次分享入库写共享区「本地待写账」，打开 App/切回前台自动收养：建/并房源实体、媒体搬进本机媒体目录、写账本镜像基线、失败挂任务中心，不用手动拉云端",
            "修复：【分享新增/补传的公共日志偶发丢失】——公共日志改「先入共享待补队→发送→成功出队」，分享进程被系统回收也不丢，App 打开自动补推；扩展补云函数地址兜底，镜像没写时日志不再静默跳过。操作人署名随镜像：开一次 App 即恢复你的署名；覆盖安装后从没开过 App 的极端场景仍显示「未设置(iPhone)」",
            "新增：【分享表单支持从剪贴板识别导入】——与 App 内同一套解析规则和确认卡，只填空白字段、不覆盖已输入内容",
            "优化：【共享菜单图标去灰底、房子放大】——改透明底纯黑剪影（双楼+加号徽标），与邻项单色线图标同风格；【桌面中号小组件告别纯白】——适配液态玻璃：主屏幕外观设「透明/着色」时系统铺与文件夹同质的玻璃底，默认全彩外观改磨砂玻璃灰（系统规定默认外观下小组件不能真透明；要整块玻璃请长按桌面→编辑→自定→选透明/着色，整屏含图标一起生效）",
            "说明：版本 2.71 / 201，其余功能与 v2.70 一致；上传/账本/通知口径不变",
        ]),
        ("v2.70", "2026-11-20", [
            "修复：【共享面板报「分享配置未就绪：请先打开一次公寓管家」】——覆盖安装后主 App 没启动过时，共享区镜像还没写，扩展拿不到云函数地址/口令哈希。现扩展内置与 App 默认口径同源的兜底地址/哈希，镜像缺失自动兜底、有镜像仍优先镜像，不再要求先开一次 App；用户名署名仍随镜像，开一次 App 后恢复你的署名",
            "说明：版本 2.70 / 200，其余功能与 v2.69 一致；上传/账本/日志/通知口径不变",
        ]),
        ("v2.69", "2026-11-20", [
            "修复：【共享菜单下方动作列表没有「保存到公寓管家」】——v2.68 把扩展注册成了 Share Extension（只进上方 App 排）；下方动作列表（和「保存到美柚」并排那排）只认 Action Extension。现改为 Action Extension（com.apple.ui-services），入口落在下方动作列表，并可在「编辑操作」里开关/排序；补上扩展图标；激活规则改字典式（图片/视频各最多 50 个）",
            "说明：版本 2.69 / 199，其余功能与 v2.68 一致；选房面板、媒体入库、直传上云、账本/日志/通知口径全部不变。装好后若列表里仍没看到，重启一次手机再开共享菜单（系统扩展注册缓存）",
        ]),
        ("v2.68", "2026-11-20", [
            "新增：【相册共享菜单直接存房，不用打开 App】——系统相册选好照片/视频点共享，下方动作列表里多出「保存到公寓管家」（和「保存到美柚」并排）。点开是小面板：选已有房号追加媒体，或填房号+租金+房东新增房源；保存后媒体当场直传上云，账本、清单、公共日志、系统通知横幅与 App 内新增/编辑完全同一套代码同一口径（压缩开关也跟随设置页「压缩上传媒体」）",
            "新增：【失败不丢文件】——个别媒体没传上去的，自动挂到主 App「同步任务中心」，打开 App 点重试即可；扩展里存的媒体主 App 能直接读取、补传、删除，房号改名也跟着迁移",
            "说明：版本 2.68 / 198，其余功能与 v2.67 一致；本次只新增分享扩展与配套共享通道（App Group 配置镜像/共享队列/共享媒体读取），不改房源同步判定逻辑、单房账本记录规则和页面布局。首次使用请先打开一次 App 完成配置镜像",
        ]),
        ("v2.67", "2026-11-19", [
            "修复：【另一台手机新增/改房，公共日志里查不到这条】——原来写公共日志是「发出去就不管」：网络一抖、App 切后台或云函数一时没响应，这条日志就直接丢掉，本机账本还在、云端日志却没有，别的设备看不到谁动过房。现在对齐电脑端做法：发完会等云端响应、核对状态码和返回结果，失败自动重试 2 次（退避 350ms/700ms）；几次都没上云的先存进本机待补队列，下次启动或回前台自动补推，补成功再从队列移除",
            "说明：版本 2.67 / 197，其余功能与 v2.66 一致；本次只改公共日志的上云可靠性（等待校验 + 重试 + 待补队列 + 启动/回前台补推），不改房源同步判定逻辑、单房账本记录规则和页面布局",
        ]),
        ("v2.66", "2026-11-18", [
            "修复：【云端操作区混入自己拉取的记录】——详情页点「确认同步」把云端最新状态拉到本机时，这条原来也被写成云端公共操作日志，别的设备会看到某人「单房更新 1 项字段」，容易误以为是这个人在云端改了房。现在这种「云端→本机」的拉平动作只记在本机操作区；云端公共区只保留本机→云端的改房、切状态、删房、上传、补传这类真正写上去的动作，和批量同步里「云端更新本机」的口径一致",
            "优化：【同步日志不再只写「更新 1 项字段」】——拉平落地时，字段差异直接写明人话明细（如「租金：1400 元 → 1500 元」），多字段逐条列出，不再只给一个数量",
            "说明：版本 2.66 / 196，其余功能与 v2.65 一致；本次只改单房拉平动作的日志归类（云端→本机不再上公共日志）和同步日志的字段明细展示两处，不改同步判定口径、单房账本记录规则和页面布局",
        ]),
        ("v2.65", "2026-11-14", [
            "新增：【深度核对终于看得出在深度核对】——以前长按刷新按钮 0.6 秒触发的深度核对，顶部胶囊仍显示「正在刷新…」，和普通点按完全一样，没法判断这次到底走的是哪条路。现在长按触发时显示「正在深度核对…」，普通点按仍是「正在刷新…」，两条路的耗时差异一眼能对上：深度核对是忽略清单、逐套全量核对 218 套（6~10 秒），普通刷新只读清单 + 变动房明细（1~3 秒）",
            "优化：【清单请求加 ETag 复用】——拉总清单（h/_manifest.json，37KB）时带上本地缓存的 ETag，云端没变化直接回 304、复用本地副本，不再重复下载整份清单。冷启动第一次检测能省 1~2 秒，之后热连接基本是毫秒级；清单真有变化时照常拉新版本，不影响检测结果",
            "修复：【电脑端上传会抹掉手机端的清单指纹】——电脑端的清单条目原来只有房号/座/修订号/媒体数，缺「媒体指纹 / 字段指纹」两个字段，反序列化再序列化会把不认识的字断丢掉：电脑端每上传一套房，整份清单 218 条的指纹全被清空，手机端下一次检测只能退回全量比对。电脑端 1.2.2 已按同一套算法补上这两个字段（媒体名小写、.mov 归一成 .mp4 后排序取 SHA256 前 16 位；房号/座/房东/户型/租金/密码/备注/状态 trim 后拼接取 SHA256 前 16 位），两端写出的清单从此一致",
            "说明：版本 2.65 / 195，其余功能与 v2.64 一致；本次只改深度核对的进度文案、清单请求的 ETag 复用两处，检测判定口径、同步结果口径和页面布局不变。电脑端同步发布 1.2.2（清单指纹 + 一键清空 + 重复房源提取媒体 + 统计实时刷新 + 应用图标）",
        ]),
        ("v2.64", "2026-11-14", [
            "修复：【自动检测要等 20 秒、手动刷新 15 秒】——根因不在网络：云端总清单是 v2.62 之前写入的旧格式，218 条记录里「媒体指纹 / 字段指纹」全是空的。检测判定「这套要不要拉明细」时，缺指纹一律当「可能有变化」，于是每次检测都把 218 套全部判成嫌疑、逐套下载 info.json；而这段是纯串行，一个等一个，218 趟往返就是 20 秒多。手动走了 16 并发所以 15 秒。现在检测改成同样的 16 并发窗口 + ETag 复用（304 不重复传数据），218 套 2~3 秒拉完",
            "修复：【清单一直修不好，每次都重来】——原来的自动检测拉完明细只记 revision 基线，从不回填清单；带指纹的清单只有在「长按深度刷新」或「距上次全量满 24 小时」时才会重建。v2.62 上线不满一天、又没长按过，指纹机制一次都没生效，所以每次都全量比对。现在检测和手动刷新都会把刚拉到的真实明细回填成带指纹的清单条目（读-改-写一次），下次检测命中指纹就直接跳过——正常无变化时整次检测只剩 1 个清单请求，1 秒级",
            "优化：【升级后第一次仍会慢一次，之后就快】——第一次检测/刷新要先把 218 套明细拉一遍来建立指纹（约 2~3 秒并发下载 + 1 次清单回写），这是数据修复的一次性成本；指纹建立后自动检测回到 1 秒级，手动刷新也降到 3 秒内。若想立刻建好，升级后长按刷新按钮 0.6 秒做一次深度核对即可",
            "说明：版本 2.64 / 194，其余功能与 v2.63 一致；本次只改检测与手动刷新的拉取方式（串行改 16 并发 + ETag）、清单指纹回填两处，不改检测判定口径、同步结果口径和页面布局",
        ]),
        ("v2.63", "2026-11-14", [
            "恢复：【自动检测时的进度提示】——v2.62 把云端检测从房源页搬到 App 启动/回前台后，原来那条「正在检测云端变更…」细进度条没有跟着搬，自动检测变成全程静默：无变化/检测失败时页面上一点反馈都没有，分不清到底查没查。现在恢复到房源页顶部：自动检测一开始就显示胶囊进度条「正在检测云端变更…」，至少停留 0.6 秒（沿用 b121 口径）；无变化/失败仍然不打扰，有变化照旧挂「检测到云端有更新，请同步」横幅",
            "优化：【手动刷新和自动检测不会打架】——手动云端同步（左上角点按 / 长按深度刷新）进行中时，自动检测直接跳过，不再两边同时拉云端清单、检测基于同步中途的中间态也不可信；UI 上手动优先，两条胶囊互斥，不会叠在一起。下拉刷新是纯本地媒体对账、不联网，不受影响，只做位置让位",
            "修复：【连点刷新会并发跑两份同步】——以前 isSyncing 只用来点亮转圈、没有拦住第二次点击，连点左上角或连续下拉会同时跑两份：重复拉清单、进度记录互相覆盖（后一份覆盖前一份，前一份的进度更新失效）、先结束的把灯提前关掉，本地对账还可能把同一个磁盘文件重复插入媒体记录。现在两个入口都加了重入保护（第二次直接返回「正在同步中，请稍候」），刷新按钮在同步期间也禁用（点按与长按都生效）",
            "说明：版本 2.63 / 193，其余功能与 v2.62 一致；本次只改自动检测的进度提示、手动/自动互斥、刷新重入保护三处，不改云端检测判定口径、同步拉取策略和页面布局",
        ]),
        ("v2.62", "2026-11-13", [
            "修复：【新增房源上传到一半就弹「云端有更新」】——以前只要本机有这套房、云端清单还没写上，检测就判「云端有更新」；而新增房源是先建本地记录、再传媒体和账本，上传那几分钟里必然命中。现在本机正在上传/待重试的房号整体不参与差异判定；只要还有房源上传任务在跑，这次检测直接跳过、也不记结论，上传完成后自然恢复正常",
            "调整：【不再每次进房源板块都检测】——原来进板块（onAppear）每次都发一次检测，从详情页返回、从编辑页返回、切 tab 回来都会触发，一天下来请求很多。现在只在「App 冷启动」和「回前台」检测，回前台加了 5 分钟门槛（锁屏解锁这种也会触发 didBecomeActive，不设门槛等于一解锁就查）；进板块只消费启动时留下的提示标记，另外保留一个 30 分钟静默兜底（只在距上次检测超过 30 分钟、且没有上传任务时轻量查一次，失败不弹提示）",
            "修复：【45 秒缓存把旧结论一起复用】——以前 45 秒内重复调用会直接返回上次结果，包括「有更新」；现在只复用「无变化」，有更新/检测失败一律重新判断，不会再拿着旧结论反复弹横幅",
            "优化：【总刷新从 30 多秒降到 1~3 秒】——以前是「先列 h/ 拿到 141 个房号，再逐套 GET info.json」，一次刷新 ≈ 141 个明细请求、8 个一批串行发，光等网络就 15~27 秒。现在改成三层：先列目录拿权威房号（1 次请求），再读云端总清单，只对「清单摘要/指纹对不上、清单里没有、本地没有」的房拉明细；正常无变化时整次刷新只有 5 个请求（列目录 + 清单 + 抽样核对 3 套）。明细拉取并发从 8 个一批改成 16 个滑动窗口（谁先回来立刻补位），失败只重试失败的房号，不再整轮重跑",
            "新增：【三重保障，提速但不漏更新】——①云端总清单每条加了媒体指纹和字段指纹：以前只比媒体「数量」，删 6 个又新增 6 个时数量一样会漏；现在按归一化后的媒体名集合算指纹，换文件也能检出，字段改动能直接在清单层发现；②旧清单没有指纹的一律强制拉明细（升级后第一次刷新会自动把清单重建成带指纹的版本）；③清单写入失败的改动不再丢，会留在补写队列，下次刷新或启动时自动补上",
            "新增：【长按刷新 = 深度核对】——左上角刷新按钮点一下走增量（1~3 秒）；长按 0.6 秒走全量，忽略清单摘要和 24 小时缓存、逐套核对一遍，怀疑漏更新时用这个。另外每 24 小时会自动做一次全量核对，媒体对账（列整桶找缺失）也从每次刷新改成 24 小时一次，避免每次刷新都扫一遍整桶",
            "修复：【先建房、后补媒体还是写两条日志】——补媒体保存后会出现「合并云端更新 媒体 8 个→8 个」+「新增媒体 图片 7 个…」两条，而且媒体条目还逐个列 jpg/mov 文件名。根因是合并判定用数组比较，云端和本地媒体并集后顺序变了就判「不相等」，于是写了一条没有实际合并的「合并云端更新」。现在改成集合差：只有云端真的多出本次没提交的媒体才算合并，且合并提示优先并入本次动作日志，不再单独成条；所有媒体日志（新增/删除/补写/补齐）一律只写「图片 x 个、视频 y 个」，不再出现任何文件名",
            "说明：版本 2.62 / 192，其余功能与 v2.61 一致；本次只改云端检测触发与判定口径、总刷新拉取策略、云端总清单指纹协议、媒体日志口径四处，不改上传链路、删除/改名链路、分享链路和媒体存储结构",
        ]),
        ("v2.61", "2026-11-13", [
            "修复：【删除媒体日志又变一堆】——同一套房同一次操作删掉 3 张图 1 个视频，以前会写出 4 条「删除图片 / 删除视频」日志、每条还带着「1-1034上-JPG-xxxx-1.jpg」这种文件名；现在同一批删除只写一条「删除媒体（本地→云端）」，详情只写「图片 3 个、视频 1 个」，操作日志里不再出现任何文件名，账本明细同样只记数量",
            "修复：【视频很容易转 MP4 失败】——压缩开关打开时，原来只走 App 自己逐帧重编码这一条路，遇到部分 iPhone 拍的 HEVC 视频、带音轨或可变帧率的 .mov 素材会直接失败并报「视频转码 MP4 失败，已取消上传」；现在改成三级兜底：先走原来的逐帧重编码（体积最小），失败立刻回退旧版本的系统导出（AVAssetExportPreset1280x720，就是 v2.15 前后一直在用的稳定方案），再失败才回退原质量转封装；三级都失败才提示失败，视频不会再动不动就传不上去",
            "修复：【取消任务后刷新同步死循环】——视频传失败挂在任务中心，点重试还是失败，点取消之后去刷新就提示「检测到云端有更新」，同步完再刷新还是提示有更新，只能进详情页把这套房的媒体全删掉才停；根因是失败媒体还留在待上传队列里（同步时被豁免、不敢删），但每次对账又把它算成「本地有、云端没有」的差异，两边互相打架；现在待上传队列里的文件在所有对账口径（清单摘要、云端账本对比、预览、真正执行同步、单房检测）里统一豁免，不再被当成差异，循环彻底断掉；真传上来离开队列后，对账恢复正常",
            "新增：【任务中心重试也拉卡片进度条】——以前只有在编辑页保存房源时，房源卡片底部才会跑进度（图片上传 x%、视频转码 x%、实时网速）；在任务中心点重试，只有任务中心自己动，卡片不动。现在任务中心重试会同时驱动房源卡片：阶段文案、视频转码百分比、字节进度、网速一起跑，重试结束自动收掉",
            "说明：版本 2.61 / 191，其余功能与 v2.60 一致；本次只改删除日志聚合、视频转码兜底、待上传队列对账豁免、重试进度联动四处，不改上传并发、同步协议和媒体存储结构",
        ]),
        ("v2.60", "2026-11-13", [
            "调整：【新增房源操作日志只留一条】——新增房源带媒体保存时，不再同一分钟写「新增房源」「新增媒体（本地→云端）」「上传媒体」「补传后补写账本」多条；首次保存若视频转码失败，只写一条「新增房源」失败日志，详情为「图片5个，视频1个，错误原因：因视频转码失败，已挂任务中心，等待重试」；重试成功后只写一条「新增房源」成功日志，详情为「6个媒体补传成功，云端账本已写入」",
            "修复：【任务中心手动重试成功没弹窗】——任务中心点「重试」并成功后，补发系统通知；前台显示横幅、通知中心保留，通知权限被拒时降级为顶部页内光条",
            "新增：【视频转码百分比】——房源卡片底部进度条在「视频转码中」阶段不再是无限滚动条，改为「视频转码中 42%」并随转码进度推进；压缩重编码按视频时间戳回调，原质量转封装按 AVAssetExportSession 进度轮询",
            "说明：版本 2.60 / 190，其余功能与 v2.59 一致；本次只改日志文案、重试通知和转码进度显示",
        ]),
        ("v2.59", "2026-11-13", [
            "新增：【上传实时网速】——新增房源保存后的媒体上传，房源卡片进度条下方和任务中心百分比旁现在会显示实时速度（如「42% · 1.2 MB/s」）；速度按最近 1 秒滑动窗口计算、每 0.5 秒刷新一次；任务中心百分比同时按当前文件字节进度推进（只改显示，不改上传链路）",
            "调整：【上传阶段进度条】——「图片上传中 / 视频上传中」保持确定百分比，只有「视频转码中」显示滚动条；转码阶段不会误显示 0 MB/s",
            "修复：【从剪贴板导入房源闪退】——裸房号后面没有「上/下/上层/下层」时，可选捕获组的范围是 NSNotFound，代码未判空就直接取子串，触发 NSRangeException 闪退；现在先判 NSNotFound 再取子串，没后缀按空串处理，正常识别房号",
            "说明：版本 2.59 / 189，其余功能与 v2.58 一致；本次只加上传实时网速，未改并发上传、逐文件 HEAD、分享页链路、取消/看门狗等慢上传逻辑",
        ]),
        ("v2.58", "2026-11-12", [
            "修复：【任务中心「重试成功」是假的】——整次云端同步重试不再点完就报成功：拉取成功才算成功，失败会留在任务中心显示真实原因；拉到云端变化后任务保持进行中，等你在确认框点「确认同步」执行完才结算，点「取消」直接收掉任务；预览阶段失败也会挂任务（以前只弹一条提示就没下文）",
            "修复：【24 小时内反复弹「媒体更新」、点确认又下载失败】——账本里引用了、但桶里还没传上来的媒体，在房源刚保存/刚同步的 24 小时内不再算差异：不弹框、不下载、只记一条操作日志；等另一台设备补传成功、账本回写后自动恢复；超过 24 小时仍缺的才按原逻辑剔除",
            "修复：【分享链接缓存命中后打开是死链】——复用上次分享链接前先 HEAD 一次页面对象：200 才复用；404 说明页面已被清理，自动清掉本地缓存并重新生成；断网/签名失败判断不了时保留旧链接，不误删缓存",
            "优化：【批量删除 130 套卡顿】——循环内只累计，删除全部结束后统一保存一次、通知列表刷新一次；删除进度浮层仍逐套推进，不会一顿一顿",
            "修复：【两台设备同时改同一套房，账本互相覆盖】——单房账本上传前再读一次云端 revision，发现刚被另一台设备改过就用最新云端重新合并再写；连续两次都变则明确报冲突，不再静默覆盖",
            "改动：【新增房源的操作日志合并成一条】——不再为同一套新增房写「新增房源」+「新增媒体」两条；现在一条「新增房源」，下面房号，再下面只写「图片 x 个、视频 y 个」，不列文件名；没有媒体就不显示第三行",
            "说明：版本 2.58 / 188，其余功能与 v2.57 一致",
        ]),
        ("v2.57", "2026-11-12", [
            "修复：【跨设备丢媒体】——A 设备保存房源时有媒体没传上时，不再把没传上的文件名写进云端账本（旧逻辑另一台设备同步时会把「账本有、桶里没有」的引用当垃圾剔除，导致补传成功后照片视频反而丢了）；现在等补传成功后再把名字补写进账本，两台设备换着用媒体一套不少",
            "修复：【删除房源后「死而复生」】——删除改为先删云端、删成功才删本地；云端删不掉时本地先留着、挂任务中心标明「云端环节失败」，点重试云端删成功后自动清掉本地；删除期间另一台设备同步不会再把已删的房拉回列表",
            "修复：【详情页删除失败没重试】——详情页删除云端失败不再只弹提示，同样挂任务中心可重试，重试成功自动清本地",
            "修复：【删除后残留幽灵任务】——删除房源时一并清掉它待传队列里的残余任务，不会再有已删的房又被当成待传任务悄悄传回云端",
            "新增：【详情页更新前防丢提醒】——本机有改动还没传上云端时，点「确认同步」按云端覆盖前会明确警告，避免没传上的本机改动被一键冲掉",
            "修复：【分享页假增量】——同一套房媒体和房源信息都没变时，重复分享/重新生成直接复用上次链接，零上传零等待；只改租金等文字时只重生成页面、照片视频一个不重传；视频首帧缩略图桶里已有也不再重复生成",
            "修复：【云端总清单更新失败会丢改动】——总清单没写上时改动会记着不丢，下次操作自动补写，不再只留一条日志就丢了",
            "修复：【总同步失败挂任务中心】——整次云端同步失败不再只弹一条提示就完事，挂任务中心可点重试重跑整次同步",
            "改动：【失败原因看得懂】——任务中心失败信息和操作日志里的错误描述改为完整内容（带错误类型），出问题能定位是网络、权限还是别的环节",
            "说明：版本 2.57 / 186，其余功能与 v2.56 一致",
        ]),
        ("v2.56", "2026-11-12", [
            "修复：【进房源板块每次都误报「检测到云端有更新」、总刷新却「无变化」】——真正根因是云端总清单里残留了一条「清单幽灵」（有条目、但实际 info.json 已 404、目录为空），旧逻辑把它误判成有更新；现在检测到这种幽灵会自动从清单摘除自愈、不再误报，且总刷新与进板块两个入口口径已统一，真机反复误报的问题这次从根上解决",
            "重做：【任务中心待处理任务的按钮】——不再把「重试、彻底取消、删除记录」三个按钮挤在一起；现在只保留一个醒目「重试」主按钮，放弃类操作收进右侧「更多」菜单，每个动作写清后果（撤回本次改动=本地+云端恢复 / 仅删除任务记录=保留文件和云端），删除类操作二次确认，且「仅删除任务记录」保证任何情况下都能把任务清掉",
            "数据安全：【删除任务不会误删真实房源】——经核查云端真实房源与本地均为 129 套、一一对应，此前担心「少一套」实为清单幽灵造成的计数错觉，真实房源一套没少；同时给撤回新增物理删除安全闸：只有纯新增任务才允许删除整套，带编辑前快照的任务一律中止删除并记日志，从代码上杜绝误删",
            "留痕：【删除任务记录写入操作日志】——点「仅删除任务记录」会在操作日志里记一条，能看到删了哪条任务、未改动任何文件和云端，不再出现「莫名其妙少东西、日志查不到」",
            "改动：版本 2.56 / 185，其余功能与 v2.55 一致",
        ]),
        ("v2.55", "2026-11-12", [
            "修复：【任务中心媒体上传任务彻底取消无效、删不掉】——此前若先把房源删了再点「彻底取消」，撤回会因本地找不到这套房而失败、任务又弹回待处理，形成死循环；现在房源已删除时，撤回自动改为「清理云端残留 + 移除任务」，已上传的残留媒体和账本事件尽力清掉，数据本就不存在（404）不再算失败，任务能正常移除",
            "新增：【待处理任务都能「删除记录」】——带撤回记录的任务除「彻底取消」外，多一个「删除记录」按钮（二次确认），仅删除这条任务、不碰任何本地文件和云端数据，确保任何情况下卡住的任务都能手动清掉，不再删不掉",
            "修复：【进房源板块反复误报云端有更新、总刷新却无变化】——对比任务中心之前的 v2.47 定位到：总刷新在「无变化」时漏掉了修订号基线回写，基线一直卡旧值、每次进板块都误报；现在无变化也会对齐基线，刷新后下次进板块不再误报，两个入口口径一致",
            "改动：版本 2.55 / 184，其余功能与 v2.54 一致",
        ]),
        ("v2.54", "2026-11-12", [
            "修复：【进房源板块老提示有更新、点总刷新却无变化】——统一两处检测口径：修订号只作「可能有变化」的快速提醒，最终是否真有更新一律看实际内容（字段+媒体清单），不再修订号对不上就误报；每次检测后都刷新本地基线，基线卡住也能自动恢复，不再反复弹「云端有更新」",
            "修复：【同一套房反复同步、一直收不了口】——单房同步时媒体下载若因弱网/超时失败，会明确提示「更新失败」，不再悄悄跳过还标记成已同步；下载后再核对一遍，确认媒体真补齐才算完成，避免没下全却显示成功、过会儿又提示要同步",
            "修复：【待重试任务没有删除按钮】——任务中心待处理区每条任务（失败/已取消）现在都有「重试」和删除类按钮：带撤回记录的显示「彻底取消」走全量撤回；没有撤回记录的显示「删除」，仅删这条任务记录（不碰文件和云端），删除前二次确认防误删",
            "改动：版本 2.54 / 183，其余功能与 v2.53 一致",
        ]),
        ("v2.53", "2026-11-12", [
            "升级：【彻底取消=全量撤回】——已取消的上传任务点「彻底取消」，不再只删条目，而是把本次账本改动和媒体改动全部撤回：已传成功、没传成功、本地、云端一律删除并恢复原样，相当于改动从未发生，不用再手动对账",
            "说明：【撤回只进操作日志】——全量撤回只写一条操作日志，不再往单套房账本留记录；云端因断网没撤干净会留在待处理、可再次点「彻底取消」继续；被删旧媒体云端也已不存在时明确提示无法恢复、不假装成功",
            "修复：【详情页刷新有变化没选项】——右上角刷新没变化时保持轻提示「已是最新」；有变化（含仅媒体变化）弹出详细「本地 vs 云端」差异：逐字段列本地值→云端值，并列出云端有本地无（同步后下载）、本地有云端无（同步后移除）的媒体文件名，底部给「确认同步」「取消」",
            "改动：版本 2.53 / 182，其余功能与 v2.52 一致",
        ]),
        ("v2.52", "2026-11-12", [
            "修复：【视频上传进度条一直不动】——转码阶段卡片底部显示滚动条和「视频转码中」，上传阶段显示真实字节进度和「视频上传中」，不再像卡死；图片同样走字节进度",
            "修复：【断网不提示、干等几分钟才失败】——上传前先检测网络，断网立即失败挂任务中心；请求超时收紧到 30 秒，整体看门狗视频 180 秒、图片 90 秒，超时明确提示可点重试，不再无期限干等",
            "新增：【上传任务进任务中心并可取消】——媒体上传在任务中心显示进行中任务，带「取消上传」按钮，立即中断转码和上传；取消后显示「已取消」，可重试也可彻底取消",
            "调整：【取消自动重试】——媒体上传失败不再自动重试，统一挂任务中心手动点重试（保存房源、批量导入均如此）",
            "修复：【账本同步成功才记录】——账本新增记录先存为待确认，云端同步成功后才写进正式账本并显示；同步失败正式账本不变，不会再误导",
            "改动：版本 2.52 / 181，其余功能与 v2.51 一致",
        ]),
        ("v2.51", "2026-11-11", [
            "新增：【电梯码一键全屏】——支持 gongyuguanjia://elevator 深链，操作按钮 / 控制中心 / 背面轻点 / 快捷指令调用后直接全屏显示电梯二维码，亮度自动拉满，关闭恢复原亮度",
            "新增：【设置页电梯码管理】——设置 → 电梯码：全屏预览、从相册更换、恢复内置默认；自选图只存本机，不上云、不进备份",
            "调整：【桌面小组件直出电梯码】——点中号组件和锁屏组件直接进电梯码全屏页，不再回首页",
            "说明：【相机控制按钮】只对相机类 App 拍摄扩展开放，普通 App 无法占用；用左侧操作按钮绑定同一条快捷指令即可按一下出码",
            "改动：版本 2.51 / 180，其余功能与 v2.50 一致",
        ]),
        ("v2.50", "2026-11-11", [
            "调整：【云端有更新改成常驻横幅】——进入房源板块检测到云端有更新时，不再弹那种不到一秒就消失的提示，改为顶栏挂一条常驻横幅「检测到云端有更新」，一直挂到你手动点右侧 ✕ 关闭；同步成功后会自动收起，不会漏看",
            "调整：【总刷新只留两处转圈】——去掉顶部那条「正在同步云端」的转圈，总刷新时只在右上角刷新按钮和弹出的进度胶囊两处转圈，不再三处同时转",
            "改动：版本 2.50 / 179，其余功能与 v2.49 一致",
        ]),
        ("v2.49", "2026-11-11", [
            "修复：【进房源页自动查云端】——回到原来的做法：每次进入房源板块自动检测一次云端有没有更新，有更新提示「检测到云端有更新，请同步」，没更新不打扰；这次不建任务记录，不再占任务中心位置",
            "修复：【重试成功没有操作日志】——在任务中心点重试并且成功后，会正常写一条操作日志（动作、房号、结果都记），账本里能看到什么时候补传成功的",
            "修复：【断网保存的图片视频没进任务中心】——断网保存房源、点「仅存本机」后，没传上去的媒体现在会立即出现在任务中心待处理里，联网后点重试就能续传；原来会被旧补传队列吞掉、看不到也续不上，已修",
            "调整：【草稿箱取消，统一用任务中心】——房源详情页的「草稿箱」入口去掉，断网时没提交成功的改动统一挂成任务中心的「提交房源改动」，联网后在任务条里点重试即可提交，不再有两套收容失败任务的地方",
            "修复：【断网删除媒体没进任务中心】——本地删了媒体、云端对象没删掉时，以前只写一条日志就结束，别人还能看到旧图；现在会挂到任务中心「删云端媒体」，联网后点重试补删",
            "调整：【总刷新不接入任务中心】——下拉刷新云端房源还是原来的样子：顶部一条临时进度条，跑完就消失，不进任务中心、不占待处理",
            "调整：【总同步失败回旧提示】——整次同步失败不再挂任务中心，恢复成以前的规则：自动重试一次，仍失败就提示「网络断开，待网络恢复后重试」",
            "调整：【批量导入合并一条】——批量导入时不再出现「总任务 + 每套房一堆散记录」，整批只留一条，失败房号直接写在这条任务的文案里",
            "调整：【最近完成不再记总刷新】——点一次刷新不会再往「最近完成」里塞一条记录，那里只留真正的同步任务结果",
        ]),
        ("v2.48", "2026-11-11", [
            "新增：【同步任务中心】——所有同步失败的活都收进任务中心：房源页顶部有任务时才显示任务条，没有任务不占地方；点进去分「进行中 / 待处理 / 最近完成」三段，待处理项挂「重试」按钮，只能手动点，不会自己偷偷跑，重试成功自动进最近完成",
            "新增：【失败记录关 App 不丢】——待处理任务存在本机，关掉 App 再进还在，点重试继续；旧的待补传媒体队列整体搬进任务中心，不再有两套互相打架的补传",
            "优化：【设置页入口】——左上角常显任务中心按钮，不单独起栏目；右上角回收站去掉「回收站」三个字，只留垃圾桶图标",
            "优化：【清理桶孤儿媒体】——进度按真实总数算（真实分母），弹窗新增「后台运行」（收起来继续扫）和「取消本次」（立即停止扫描，一个文件都不删）；删除前仍必须先看名单确认，不会直接删",
        ]),
        ("v2.47", "2026-11-10", [
            "修复：【账本加视频仍出两条记录】——删掉那条明细空白、看不懂的「媒体更新」，现在加一个视频就只留一条「新增视频」（带文件名），加图片、删图片、删视频同理，各自只留一条说人话的记录；以前已经产生的「媒体更新」老记录，打开 App 会自动清掉（本机和云端一起清）",
            "优化：【操作日志三个页签卡片统一】——本机、云端、合并三个页签的日志现在全部用同一套卡片：左边彩色条、动作、时间、房号、明细、操作者，时间格式和颜色规则一致；合并页里同一动作跨来源只显示一条",
            "优化：【房源详情页】——右上角「已租 / 待租」状态胶囊放大更醒目；「账本」按钮还原到「分享」按钮下面，整行宽度显示",
            "新增：【清理桶孤儿媒体加进度弹窗】——扫描时弹出进度框，显示正在核对哪间房、完成几间、百分比，不再像卡住一样没反应",
            "优化：软件说明里去掉「目前用于利保米兰公馆」字样",
            "修复：【最后一个月收租后卡片仍显示待收】——12 个月全部收齐（含最后一个月刚勾上）时，卡片现在正确显示已收，不再明明「已收 12 个月」却还挂着待收",
            "修复：【详情页取消某月收租闪退·这次从根上修掉】——对照了历史不闪退的版本，找出真正原因：编辑房源、编辑收租计划保存时会把这套房的收租记录整批删掉再重建，详情页和收租行手里还拿着被删掉的那批旧对象，点勾那一刻一碰就崩。现在改成：①保存只按「年-月」和记录 id 原地修改，不再删了重建；②收租行只显示数值，点勾只传一个记录 id，真正写库时按 id 去当前记录里找，找不到就跳过，绝不碰已删除对象；③打开、关闭编辑弹窗后都重新取一份最新收租记录",
            "优化：【账本按钮底色】——去掉原来的主题色，与「分享」按钮完全一致（同一套样式、同一个底色）",
            "改动：版本 2.47 / 174，其余功能与 v2.46 一致",
        ]),
        ("v2.46", "2026-11-10", [
            "优化：【一次操作只留一条记录】——只加视频/图片这类纯媒体操作，不再产生明细空白的「修改房源」记录，只留一条直接说明白的媒体记录",
            "优化：【每条记录都看得懂】——媒体分清图片和视频并带文件名，如「新增视频 1 个：1-911_xxx.mov」；字段变化统一「旧值 → 新值」，如「租金 1000 → 1100」",
            "优化：【动作名说人话】——去掉动作名末尾的「同步」二字；「重建本地账本镜像、云端覆盖本地、跳过云端覆盖、冲突合并、清理账本失效媒体引用」等技术词分别改为「本地数据刷新、云端更新本机、保留本机修改、合并云端更新、清理失效媒体记录」",
            "历史迁移升级：自动清掉旧的「历史」标签迁移记录（真实操作不碰），按新文案重新迁移；明细为空的「修改房源」不再迁移",
            "修复：账本里同一动作出现新旧两条（如「新增房源」和「新增房源同步」成对出现）——旧历史记录现在会从云端一并清掉，不再只清本机；云端和本机日志里重复记录的同一动作只保留一条",
            "修复：media 文件夹里多出的畸形目录（名字带括号说明、带 .jpg/.ipa 文件名等，由旧迁移器误解析日志产生）启动时自动清理，真实房源目录不动；以后房号校验不通过的文本不会再建目录",
            "多选模式下执行动作（保存视频、标记已租、删除、分享）完成后自动退出多选，不用再手动点取消",
            "改动：版本 2.46 / 170，其余功能与 v2.45 一致",
        ]),
        ("v2.45", "2026-11-10", [
            "新增：【单套房账本】——房源详情页点「账本」按钮，从这套房建立起的全部操作都在：改房号、改租金、改备注、改密码、改房东、改户型、改状态，以及媒体的新增和删除，一条不漏；每条都列出操作人和时间，并带搜索框，可按动作、操作人、明细、字段新旧值搜",
            "账本云端共享：不管谁在自己手机上操作，事件都会合并到云端账本，所有人打开都能看到；同一事件按唯一标识去重，不会重复；离线时先记本机，联网后自动补传",
            "历史迁移：升级后自动把现有操作日志（含云端公共操作记录）里能识别房号的历史动作，提取到对应房号的账本，带「历史」标签；只跑一次，不重复",
            "调整：取消「同一房源同一动作 10 秒内只提醒一次」，现在改一次就提醒一次，每条通知独立保留，不再互相覆盖",
            "改动：版本 2.45 / 168，其余功能与 v2.44 一致",
        ]),
        ("v2.44", "2026-11-10", [
            "房源板块所有动作接入系统通知：新增上传完成／只存本机、编辑同步、房号迁移、状态切换、批量改已租、删除、下拉同步、媒体补传、云端下载、批量导入、待补传全部重试，共 18 类动作完成后立刻发通知",
            "通知在前台也弹横幅，不用切后台等；同一房源同一动作 10 秒内只提醒一次，不刷屏",
            "下拉刷新「总同步」完成的通知会列出本次具体新增、更新、删除、补传了哪些房号；同步失败、删除失败、补传失败等失败类同样发通知",
            "通知权限被关闭时自动降级为 App 内顶部光条，不会静默无反馈",
            "改动：版本 2.44 / 167，其余功能与 v2.43 一致",
        ]),
        ("v2.43", "2026-11-10", [
            "重写剪贴板识别方案：按真实短格式（「1234 上层 900 12345678」）与带标签长文本（「租金900、密码66668888」）两套写法分段识别，房号、上下层、租金、密码、房东逐项归类；密码没有「密码」两个字也能认（独立 4~12 位数字串，自动排除房号和租金）",
            "房号规则：写了座号前缀就照用，没写默认 1 座并在确认卡标黄提醒；「上层/二层」加「上」、「下层/一层」加「下」；租金没写就留空，不硬凑",
            "房东规则：末尾单字房东固定认「汇、罗、何、康」，带「房东：某某」标签的照认；没识别到房东一律默认「业主」",
            "导入确认卡改成快递识别式界面：顶部加原文本框，可直接修改，改完自动重新识别，下面逐项显示识别结果与「填入」",
            "备注兜底：与房东、户型、租态都不沾边的剩余文本（如「押二付一」「房子很差」）自动写进备注；「包物业」三个字全部忽略，不进任何字段；「已退租」识别为待租",
            "改动：版本 2.43 / 166，其余功能与 v2.42 一致",
        ]),
        ("v2.42", "2026-11-09", [
            "修复：点「从剪贴板导入」弹出空白卡片、里面没有任何内容（确认卡改为按解析结果直接呈现，列表行标识固定，不再每帧换 id 导致白屏）",
            "修复：剪贴板导入后房源状态一律变「待租」——现在识别到「已出租/已租/已签/已定/成交」等说法会正确写为已租，识别不到才保持默认",
            "修复：只要原文出现「业主」两个字就把房东填成「业主」——现在只认「房东：某某」这类带标签的人名，或「业主直租/业主自租」这类明确说法，其余情况房东留空",
            "保持原有口径：只填空白字段、不覆盖已填内容；原文没写座号按当前座号填入并标黄提示；识别不到房源不弹卡、只给 3.5 秒橙色提示",
        ]),
        ("v2.41", "2026-11-09", ["新增：【快捷指令直达】——在微信复制房源文字后，用快捷指令打开 gongyuguanjia://paste，App 直接跳到「新增房源」并自动解析剪贴板，弹出识别确认卡", "复用 v2.40 同一套识别规则（房号/座号/上下层/户型/租金/房东/租态/密码/备注），只填空白字段、不覆盖已填内容", "冷启动也能接住深链：先切到房源板块再自动唤起新增页，不会漏", "识别不到房源时页面内橙色提示 3.5 秒自动消失，不弹空确认卡", "改动：版本 2.41 / 164，其余功能与 v2.40 一致"]),
        ("v2.40", "2026-11-09", ["新增：【从剪贴板导入房源】——在微信里长按复制房源文字，回公寓管家点「新增房源」，页顶出现「从剪贴板导入」，点一下自动识别房号、座号、上/下层、户型、租金、房东、待租/已租、密码、备注，再核对一眼即可保存", "新增：【识别结果确认卡】——逐项标出「识别到 / 未识别」，房号自动补成 1-/2- 前缀并沿用原有查重提示；原文没写座号时按当前座号兜底、在确认卡标黄提醒；没被识别到的短句可选择整体写进备注", "修复/防呆：【只填空白字段，不覆盖你已输入的内容】——已填过的房号、租金、房东一律不动，识别不到的留空手补，避免把人工核对过的数字冲掉", "隐私：【纯本地解析】——识别只在本机做，剪贴板文字不上传云端、不入日志；进入新增页只探测「有没有文字」，点了入口才读取，读取时由系统弹「允许粘贴」", "优化：【入口不打扰】——只在新增房源页出现，编辑页和剪贴板为空时都不占位，识别不出房源（没有房号也没有租金）时只提示一句，不弹表单", "改动：版本 2.40 / 163，其余功能与 v2.39 一致"]),
        ("v2.39", "2026-11-09", ["新增：【电表卡片左滑菜单】——主列表改回系统列表，卡片左滑即出「置顶」「删除」两个按钮；置顶数量不设上限，置顶的永远排在最前，且置顶组内仍按你当前选的排序（余额/用量/房号）排列，不会被排序打散；删除只移除本机电表清单、不动官方账户里的电表数据", "新增：【进房源详情自动查云端更新】——每次点进某套房，只拉这一间房的云端账本（约 1KB，不是整份账本），有更新就弹「更新 / 忽略」，没有更新一个字都不弹；15 秒内反复进出复用上一次结果，不重复费流量", "新增：【详情页右上角单房刷新】——只刷新当前这一间房，其它房源不动；拉不到时明确提示「云端检测失败」并给重试，绝不把检测失败当成「没有更新」", "新增：【保存前强校验，旧数据不许覆盖新数据】——在另一台手机改完并同步后，本机账本还是旧的、直接进编辑页保存，会在点「保存」时被拦下：逐字段比出云端差异（如「租金：800 元 → 900 元」），本次改动不落库、不上传，提示先返回详情页「更新」同步后再编辑", "新增：【弱网/断网保存失败自动存草稿】——校验不了或没网时不写正式数据，本次改动（字段 + 新增/删除的图片视频）整体存进草稿箱；入口在房源详情页「多选」按钮旁，一行一条草稿，点开看改动详情，联网后手动提交；提交时会再比对一次云端，如果这期间别人又改了，弹「仍然覆盖云端 / 取消」由你决定", "修复：【编辑保存时读云端失败被当成「云端没有这套房」】——弱网下写前探测失败，旧代码当成云端无记录，跳过媒体合并、版本号重置为 1 直接覆盖，等于没有保护；现改为只有 404 才算不存在，其余失败一律中止保存并提示"]),
        ("v2.38", "2026-11-09", ["修复：【点「选文件夹」直接闪退】——批量导入选文件夹时，系统文件夹选择器不支持「复制副本(asCopy)」模式，旧代码对所有选择统一用 asCopy，点选文件夹即触发系统断言闪退；现文件夹改为安全作用域直接读取，普通文件仍走复制，两种方式都正常", "修复：【列表/账本偶发闪退（编号强转崩溃）】——恢复备份时旧代码在后台线程另建数据库上下文做「清空→重插」，主界面已加载的旧对象变成指向已删数据的僵尸对象，再访问其编号时强转失败闪退；现恢复统一在主线程、同一上下文完成，杜绝僵尸对象窗口", "修复：【视频保存到相册不排在最前面】——批量保存视频的路径漏写「创建时间」，相册沿用视频原始拍摄时间导致不置顶；现保存时把创建时间设为当前时刻，同批按顺序微增，保存后稳定显示在最前", "优化：【媒体下载真正断点续传】——下载边收边写临时文件，中断后再次下载只补传剩余字节（Range），服务端不支持时自动从头重下，全部收齐并校验大小后再落盘，不再每次整文件重下", "修复：【彻底删除云端账本失败被静默】——详情页删云端账本的错误被 try? 吞掉，可能出现「删了又回来」；现失败如实提示并引导手动清理，账本本就不存在(404)仍算成功"]),
        ("v2.37", "2026-11-09", ["重构：【批量导入】——顶部只留「批量导入」「扫描补全」两个页签，扫描补全逻辑不变；批量导入分「导入全套」「只导入媒体」两个入口，界面加了小字说明", "重构：【导入全套两步走】——第一步导入清单，自动检查云端/本机重复并剔除、列表展示；第二步导入媒体包，清单与媒体按房号合并核对，确认后一次性建房源、挂媒体并同步云端", "新增：【只导入媒体】——逐间核对房号，只有本机已存在的房源才补媒体，本机没有的标注原因不导入，确认后补媒体并同步云端", "优化：【批量导入进度】——两个入口进度都接顶部统一进度条，可最小化、按真实文件推进", "新增：【云端总清单自动维护】——房源信息或媒体一变动总清单自动更新，同步后自动刷新基线，不再逐间拉取、不误报", "修复：【房号双前缀/显示不统一】——房号统一从纯房号生成 1-/2- 前缀，杜绝「2-1-xxxx」，分享文案同步修正", "修复：【媒体命名与真实格式不符】——按真实格式命名，本地 .mov 与云端同名 .mp4 视为同一转码文件防死循环，图片保留完整后缀比较", "修复：【孤儿删除前实时复核】——删除前重拉账本、重列桶确认，网络失败不当空，只删确认仍孤儿的文件", "修复：【待上传文件被误删】——排队/正在传的文件自动豁免，不删不清任务", "优化：【云端推送更稳】——后台任务改值类型快照防崩溃；新增带媒体先传媒体后传账本；改名先校验、先建后删，失败保留旧目录", "清理：【大扫除】——删除桶内空死对象 _houses.json，明确软删除字段语义，核对清理无引用死代码"]),
        ("v2.36", "2026-11-08", ["修复：【云端账本为空时同步会误伤本地】——新增空集保护：拉到的云端账本是空的就停止本次同步并提示，不再把本地房源当成「云端已删」", "修复：【本地有没同步成功的改动会被云端覆盖】——同步前查本地未同步标记，命中的房源整间跳过云端覆盖、保留本地修改，并提示跳过的房号", "修复：【预览和执行两套算法对不上】——执行改为按确认弹窗里的「新增/更新/删除/补传」名单走，计划外不动作", "修复：【切换出租状态/批量已租可能覆盖他人数据】——三处状态切换统一走「先读云端再合并」的安全上传并自动加版本号；详情页同步失败也正确标记待补传", "修复：【编辑保存先删文件后存库、存库失败丢图】——改为先存数据库（失败提示、不碰文件）再删文件、迁移媒体目录", "修复：【AI 改房号/座号云端媒体丢失】——改房号时一并迁移本地媒体目录、新目录媒体加入补传队列，旧云端清理失败留痕", "修复：【只改座号媒体读不到】——新目录 key 改用表单选的座号、统一带 1-/2- 前缀", "修复：【云端删除失败被静默吞掉】——404 算成功，网络/权限等真实失败如实上抛", "优化：【媒体下载】——最多 3 并发、按真实文件大小推进进度，已存在文件自动跳过支持重跑，写入失败明确报错", "优化：【脱敏分享页更新无空窗】——先建新页再删旧页，新页没成功前旧链接始终能打开", "清理：【批量导入云端查重】——导入再查云端，另一台设备已建的同号房不会重复导入；删除两处死代码；租金 0 显示「租金面议」；操作日志新增「全部」合并视图"]),
        ("v2.32", "2026-11-08", ["修复：【设置页「版本更新介绍」读不到最新条目】——版本列表里仍残留旧应用的占位记录，其中 v2.14…v2.0、v1.0 与当前应用版本号完全重复，列表按版本号作唯一标识时重复主键导致行渲染丢失、最新条目不显示；现已删除整段旧应用 v2.x 占位记录，云端更新日志与本地条目合并去重后统一按日期倒序排列，最新版本稳定显示在最前", "修复：【云端突然丢失某一间房的媒体】——根因是清理把网络失败误当成「空结果」：读取某房云端账本失败时，代码把该房媒体名单当成空集，整间房媒体全部误判为孤儿删除；列桶失败时账本内媒体也会被误判「桶里不存在」而连锁剔除。现改为：网络失败一律跳过本次清理、绝不按空结果处理，只有「账本明确存在且明确不含」的对象才删除，读不到账本的房间整间跳过；并新增媒体活动闸门，孤儿清理与上传/转码严格串行，杜绝「文件已上传、账本未写」的对象被误删", "修复：【视频分享隐患】——视频转码失败时，原代码仍把原始 .mov 字节以 .mp4 文件名和 video/mp4 类型上传，产出微信打不开的「假 mp4」；现房源媒体上传与分享卡片两处都改为转码失败直接报错、绝不再传原始 mov，保留本地文件待重试"]),
        ("v2.23", "2026-11-07", ["调整：设置页前 6 个板块改一级菜单，内容全部进二级页 —— 账号与云端 / 分享与展示 / 备份与安全 / 账单与默认值 / 外部服务 / 存储与清理，点进去才是具体设置；最下面「关于」原样留在首页", "新增：「清理下载的安装包」——存储与清理页新增一行，显示 App 内已下载的安装包个数与占用，一键清空（不影响已安装的 App）", "优化：更新包自动只留最新的一个 —— 新包下载并校验通过后，自动删掉 Updates 文件夹里其它旧 .ipa（每版约 10MB，不再越堆越多）", "优化：同步标红补齐媒体变化 —— 云端同步后，字段有变化、图片视频有增删的房源都画红框，点开一次详情才消失（此前只对字段变化标红）", "修正：版本更新介绍与云端同步 —— 云端更新日志此前是空的，界面一直停在 v2.18；本次把 v2.19–v2.23 写进云端，之后新版本随发布自动追加"]),
        ("v2.22", "2026-11-07", ["调整：首页版本号撤掉 —— 工作台标题旁不再显示版本号与橙色更新胶囊，改由启动弹窗提示", "新增：启动更新弹窗 —— 每次启动检查到新版本弹一次，显示新版本号、Build、发布日期、大小与更新内容，底部「立即更新」「下次再说」", "调整：自动检查开关生效 —— 设置页「启动时自动检查更新」关掉后启动不再联网查版本，手动检查仍可用", "说明：同一版本每次启动最多弹一次；没有新版本不弹"]),
        ("v2.21", "2026-11-07", ["新增：在线更新 —— 每次进 App 自动检查云端版本，设置页可手动检查、看更新内容、下载最新安装包", "新增：App 内下载安装包 —— 下载到本机（文件 App → 公寓管家 → Updates），可一键分享给签名工具重签安装", "新增：后台 App 更新配置 —— 远程配置页新增一块表单：版本号 / Build / 对象路径 / 大小 / SHA256 / 更新内容", "调整：不再弹最低版本提示；桶里只保留最新一个安装包"]),
        ("v2.20", "2026-11-06", ["新增：云端同步未读红框 —— 同步下来「新增」或「被云端修改覆盖」的房源，卡片画红框；点开一次详情页就消失", "说明：标记存本机，重启不丢；同步了没点开就一直红；本地自己新增/编辑不标红"]),
        ("v2.19", "2026-11-06", ["修复：录入后工作台不刷新 —— 成交、杂项、收租合同、包租删除与付租保存后统一广播，工作台立即重算", "修复：包租提醒金额没扣免租期 —— 改为直接取付租计划该期应付", "修复：交租日 / 付款日 31 号跨月收敛到当月最后一天", "修复：快捷付租保存失败静默 —— 改为弹窗红字提示", "调整：即将到期不设上限；移除本月应收 / 已收统计"]),
        ("v2.18", "2026-11-06", ["调整：设置页重排为 7 组 —— 账号与云端 / 分享与展示 / 备份与安全 / 账单与默认值 / 外部服务 / 存储与清理 / 关于，11 节打散重组，功能入口一个不少", "修正：文案与实现对齐（自动备份明说只含账本+媒体清单、不含房源；跨端操作会联网；单价只预填账单、房源租金不读这里；压缩写明图片长边1600、视频长边960约1Mbps；选房链接与分享卡片是两套有效期）", "删除：提醒铃声的「自定义音」四个选项 —— 工程内从未打包该音频文件，选它永远回落系统音，等于没功能", "新增：崩溃日志「清理全部」（查看器右上角，二次确认后只删 Crash*.txt）+ 入口右侧显示占用", "新增：全量备份进度（顶部进度胶囊实时显示百分比，此前只有一句「正在生成…」）", "新增：云端配置里的用户名支持下拉选择云端已有的用户名（列 users/ 目录）", "新增：房源管理顶栏加「操作日志」按钮（批量导入旁）；「已收录 N 套」从设置页移到房源统计栏", "改名：「刷新分享缓存」→「重建全部分享链接」，「查看备份文件」→「备份文件管理」，「备份与迁移」→「换机迁移」，AI对话缓存 → AI 产物（可清理）"]),
        ("v2.17", "2026-11-05", ["新增：品牌启动图 —— 系统 LaunchScreen 换成象牙白底 + 墨绿线稿楼宇 + 「公寓管家」，首帧叠同一张图并动态显示版本号（读 CFBundleShortVersionString，以后升版不用重做图），0.5 秒内淡出", "调整：安居客板块改成 58 那种排名看板 —— 概览从「房源/均价/最高」换成「房源(套)/经纪人(位)/上榜经纪人」+ 经纪人 Top5 排名（第一名琥珀色），排序菜单补「按经纪人」", "新增：安居客房源卡片补经纪人姓名 —— 列表先出来、后台逐个打开详情页取经纪人，进度显示「正在补抓经纪人 n/28」，没取到显示「—」", "修复：安居客找房抓不到利保米兰公馆 —— 默认链接从失效的小区精选页换成 m 站关键词搜索，改为优先读 JSON-LD；旧链接自动迁移", "新增：安居客验证码弹窗人工过验证 —— 读取中弹验证码时 App 内弹出可交互窗口，当场点完继续抓", "新增：只分享视频 —— 直接把视频当视频消息发给微信（有缩略图、点开即播），不走云端卡片、不需要备案域名"]),
        ("v2.16", "2026-11-05", ["调整：补齐云端媒体（本地→云端）的成功/失败记录改记到云端操作日志，本机区不再出现这几条；其余同步类日志仍在本机区", "优化：上传中的房源临时置顶 —— 正在上传/云端同步的那套临时排到第一位，进度结束立即回落原排序，批量导入顶部总进度条不受影响"]),
        ("v2.15", "2026-11-05", ["优化：两处分享页图片懒加载 —— 首屏前 3 张 eager、其余 lazy + decoding=async，微信里滚到才下载", "优化：视频压缩改 AVAssetWriter 控码率 —— 旧实现 1280×720 预设只降分辨率不控码率（28 秒素材仍 9.6 Mbps / 34MB）；改为长边 960（横屏 960×540、竖屏 540×960）、H.264 平均码率 1.0 Mbps、AAC 96 kbps、faststart，同素材实测 3.9MB 约原来 1/9；源片不足 960 不放大，失败回退原文件"]),
        ("v2.14", "2026-11-05", ["修复：安居客后台只能读取到第一页 —— 已登录真实经纪人后台抓取分页 DOM 确认：分页是 Ant Design 组件 li.ant-pagination-next > button > span「下一页」，其中 span 的 pointer-events 是 none，真正可点的是上层 button。上一版把 span 判成不可点/最后一页，所以第 1 页之后直接停手。现改为向上找到 button/li 再点；是否最后一页只认 aria-disabled=true 与 ant-pagination-disabled 类，不再用 pointer-events 判定；总页数改从分页器页码读取，避免正文里的“N页”误判。真实页面实测：第 1 页 20 条 + 第 2 页 16 条 = 36 条，与页面「共找到 36 套房源」一致，第 2 页后按钮置灰不再多翻"]),
        ("v2.13", "2026-11-05", ["修复：【安居客后台「正在读取第三页」网络超时】（① 续修）——按 1.98 原文逐行核对后确认代码与 1.98 完全一致，问题在 1.98 自带的翻页判定：它只要页面上有文字为「下一页」的元素就直接点，只有该元素自身 class 含 disabled 才算到底。安居客新版分页把置灰状态放在外层容器/aria-disabled 上，而当前小区列表只有 2 页（约 30 套），第 2 页那次点击等于点了不存在的第 3 页，列表整页跳转把抓取脚本上下文销毁，脚本再也发不出结束信号，只能干等 75 秒后弹「网络超时」。现改为：①点击前检查「下一页」自身及上 6 层祖先的 disabled / aria-disabled / pointer-events:none / 不可见，置灰即视为最后一页不点；②页面出现「共 N 页」或「x/y 页」时按总数到最后一页就停；③只认可见的最内层节点，隐藏模板不算；④万一仍跳到不存在的页导致列表重载，已收集的页面直接正常收尾，不再等 75 秒误报超时。抓取其余逻辑仍与 1.98 一致，逐步进度提示保留"]),
        ("v2.12", "2026-11-05", ["修复：【安居客后台读取】整体恢复 1.98 原实现（b125）——后台抓取这段代码在 1.98 之后被 v2.9/v2.10/v2.11 三次整改误改（加了只留「米兰」的卡片过滤、加了 30 秒看门狗、把页面内点击翻页改成只探测链接），才出现「第 3 页超时」和「能读但没读全」。现按 1.98 的代码逐行恢复：工作台概览 → 房源列表 → 脚本内点击「下一页」连续收集第 1/2/3…页（最多 5 页，每页等 2.5 秒），卡片全量入账不过滤，兜底超时 75 秒；仅保留刷新时的逐步进度提示（打开后台 / 读取概览 / 读取列表 / 正在解析第 N 页）"]),
        ("v2.11", "2026-11-05", ["修复：【安居客后台读取翻页超时】（b124，① 续修）——上一版（v2.10）翻页用 JS 内点击「下一页」：安居客「下一页」是整页跳转链接，点击后脚本执行上下文被页面导航销毁，循环中断、结束信号永不发出，只能靠看门狗 30 秒误报「网络超时」，且每次页面重载又从第 1 页重复收集（进度错乱）。现改为：脚本只收集当前页 + 报告「下一页」链接地址，翻页由 App 直接加载下一页链接（失败立即报错），页码由 App 精确显示（解析第 1/2/3 页），没有下一页或达上限正常结束，不再出现「根本没有第 3 页却卡在第 3 页超时」"]),
        ("v2.10", "2026-11-05", ["修复：【安居客后台读取失败】（①）——后台读取原来页面加载失败/网络异常时不报错，只能干等 75 秒后才弹「页面加载超时，请检查网络后重试」；现改为：导航失败立即提示具体原因（网络异常或平台拦截）、读取进度逐步显示（打开后台→读工作台概览→读房源列表→翻页解析）、超过 30 秒无任何进展才判超时，打开即被跳登录页时直接提示先登录，不再长时间卡在「正在读取页面数据…」", "修复：【房源排名·安居客抓到非米兰房源】（②）——安居客 tab 原用无小区过滤的旧链接，页面混入其他小区房源（如「万科京都荟 950 元」同套重复 7 条）；现默认链接换成带 facet_comm_id=102286650 的利保米兰公馆专用链接（旧链接自动迁移），并按关键词过滤只保留目标小区卡片", "调整：【房源排名双 tab 顶栏联动】（③）——顶栏「读取」按当前 tab 刷新对应抓取（58 tab 刷 58 列表、安居客 tab 刷安居客找房）；顶栏小字「关键词｜上次抓取 xx｜共 N 套」按当前 tab 显示对应数据；移除安居客页内重复的「利保米兰公馆｜上次抓取｜读取」标题行"]),
        ("v2.9", "2026-11-04", ["修复：【58详情页卡死】（新增1）——点抓取房源卡片原来直接把相对路径丢给 URL(string:)（解析失败）+ 详情页用桌面 UA 被 58 反爬拦截，卡住不动；现补全 58 列表页地址 + href、详情页改用手机 UA（与列表抓取一致）、15 秒未完成或加载失败显示「详情加载失败」可一键重试，不再卡死白屏", "修复：【安居客抓取三问题】（新增2）——①抓到非米兰房源：读取后自动只保留「利保米兰公馆」房源（设置页更换 URL 可抓其他小区，不会误删整页）；②同一套房源重复展示：跨页按房源编号全局去重；③缺排名：概览卡新增「按小区展示房源数量排名 Top5」，对齐 58 页经纪人排名", "删除：【手动数据同步】（半成品）——iPhone↔Windows 局域网直连同步整条功能删除（ManualSyncView/SyncCore/SyncDTO/SwiftDataSyncSnapshot 全部移除），设置页「数据同步」入口删除；备份/恢复统一走 zip 格式", "删除：【包租盈亏残留统计】——ProfitCalculation 数据模型及工作台相关字段删除（该功能已下线，属残留代码）；删除旧版示例数据（SampleData）与死代码页面（UserGuideView/PlanEditors）", "移除：【旧版 JSON 备份导入】——备份中心移除旧格式 JSON 备份的导入/恢复入口与遗留列表（v5 起备份/恢复统一 zip 格式）", "优化：【自动备份定时器】——未开启自动备份时不再常驻 30 秒轮询定时器（省电）；开启后每 2 分钟检查一次", "优化：【流式打包/上传防闪退】——备份打包与媒体上传改为 1MB 分块流式读写（媒体原图不再整读进内存），大照片/视频备份、上传不再 OOM 闪退", "优化：【统计失败不静默】——工作台统计读取失败显示橙色提示「统计加载失败，当前数据可能不准确」，不再静默按 0 显示", "优化：【变更感知三态】——检测失败（断网/超时/未配置云）单独提示「云端检测失败：请检查网络或云配置」，不再与「无变化」混淆静默", "修复：【无媒体筛选按钮】——图标删除重建为系统基础符号 photo/photo.fill（未选中浅绿底+绿图标、选中实心绿底+白图标），不再渲染成纯色空白圆点", "优化：【桶孤儿清理】——扫描先列完整名单+详细路径（h/房号/文件名），确认后才删除，删除结果含路径写入操作日志（云端日志）"]),
        ("v2.8", "2026-11-04", ["补丁（b121）：【变更感知直观指示条】——自动轻量感知检测期间，房源列表顶部显示细进度条 + 「正在检测云端变更…」，每次点进去都能看到正在同步对比；检测完成至少停留 0.6 秒再收起（有变化再弹「检测到云端有更新，请同步」横幅），避免一闪而过感知不到", "补丁（b120）：【变更感知机制重做】（清单1 第三版）——上一版（b119）用「云端快照基线」比对：基线更新后云端无新变化就永远不再提示（实测「变更感知无效，点进去没提示」）。现按用户澄清重做：检测「本地 vs 云端」两端差异，判定机制与「同步云端房源」按钮完全一致（云端账本 fetchAll + 字段级对比 + 房号集合差）：云端有本地没有、同房号字段/媒体不一致、本地有云端没有 → 任一命中即提示「检测到云端有更新，请同步」，完全一致不提示；弃用快照基线；每次进入实时检测 + 启动/回前台检测，防抖避免重复提示", "修复：【打开App轻量变更感知】（b119，重做）——上一版启动/回前台只探测一次、提示一次就消失；现改为每次进入房源页都轻量列一次 h/ 桶目录（对象名+大小+修改时间，不下载内容）与本地基线比对：有变化 → 顶部横幅提示「检测到云端有更新，请同步」，无变化不提示。根因修复：COS 修改时间带毫秒（.000Z）、默认 ISO8601 解析失败返回遥远过去时间，基线时间恒同、大小不变时永远检测不到变化——已补 .withFractionalSeconds；探测失败（断网/超时）跳过本次不写空基线、不误报；启动/回前台检测到变化但不在房源页时写入持久化标记，进房源页补横幅不丢提示", "调整：【云端操作日志整理】（b119）——同步类个人动作（同步房源云端→本地、重建本地账本镜像、补齐云端媒体、补传房源本地→云端、清理账本失效媒体引用、自动补传媒体）从云端日志改记本机操作日志；删除类（彻底删除本地+云端）、房源编辑、桶孤儿清理（直接动云端数据库）仍保留云端日志", "优化：【无媒体筛选按钮换方法】（b119）——上一版改主题色浅透明底在设备上仍显灰、无效；改用系统绿色直接着色：未选中浅绿底+绿图标，选中实心绿底+白色图标，一眼区分", "新增：【AI助手停止按钮】（b119）——正在思考/执行工具时气泡尾部出现红色「停止」按钮，点击立即中止当前任务并清空排队消息（已完成的写操作不可回滚，只中止剩余流程；若正弹「确认操作」框视为取消）", "优化：【AI输入框自动换行】（b119）——输入框改为 axis: .vertical + 1~5 行，长指令自动换行不再单行横滚", "优化：【日志操作者移到最右】（b119）——日志查看器（本机区+云端区）每行底部「操作者」从左侧移到最右侧显示，校验和/房号靠左"]),
        ("v2.7", "2026-11-03", ["新增：【跨账号日志公共区】（b114）——云端操作日志不再按自己用户名过滤，拉取全部用户的公共日志；本机日志区同时记录所有操作。另一个用户在另一台手机上的操作，你在日志查看器云端区能看到", "新增：【同步总进度条】（b114）——点「同步云端房源」确认后，整个同步流程走全局任务中心，房源页顶部显示总进度条，样式与批量导入/补传媒体一致，可最小化到「设置→待补传媒体」查看", "优化：【补传合并写】（b114）——本地补传云端的房源从全量覆盖写改为逐套合并写：写前先读云端 info.json，mediaNames = 云端∪本地−本次删除，revision+1，避免另一用户刚加的同号房媒体被本地空名单覆盖", "新增：【桶孤儿清理】（b114）——同步完成后后台列 h/ 整桶，删除不在任何账本 mediaNames 里的孤儿媒体对象（改名/删媒体后残留的旧文件）", "优化：【户型筛选联动】（b114）——户型筛选选项只显示当前座号+状态+搜索+无媒体筛选后实际存在的户型；点了「未租」+「1座」，户型只列 1座未租 有的", "新增：【房东/户型历史下拉】（b114）——新增/编辑房源时，房东、户型输入框旁加下拉按钮，可快速选择已有值，也可手动输入新值（下拉只做辅助）", "优化：【排序图标化+无媒体筛选】（b114）——顶栏排序按钮去掉文字只留图标；旁边新增「无媒体」筛选按钮，一键只看没有实拍图/视频的房源", "补丁（b115）：设置页云端配置区新增「清理桶孤儿媒体」手动按钮——二次确认后全量列 h/ 桶清理孤儿媒体，同步后仍自动后台跑一次", "补丁（b116）：同步差异诊断——同步覆盖时日志记具体哪个字段不同（如 remark「xxx」vs「yyy」/媒体本地独有vs云端独有），定位「每次同步都有变化」死循环根因；字符串比较前 trim 防首尾空格误判", "补丁（b117）：无媒体筛选按钮图标换成 photo.on.rectangle.slash（修复图标渲染成空白圆点）；清理桶孤儿媒体改为先扫描列出全部孤儿文件+详细路径，确认后才删除，删除结果（含完整路径）写入操作日志", "补丁（b118）：修复 1-711 同步无限循环——云端账本引用了桶里不存在的失效媒体（下载永远失败→每次同步都判「云端独有」），同步收尾自动剔除失效引用写回云端，循环终止；新增【打开App轻量变更感知】——启动/回前台轻量探测云端账本变化，房源列表横幅提示「云端有更新」，下拉刷新即同步；新增【先探后写】——新增同房号保存前先查云端，云端已有他人记录弹三选一（同步到本地/仍然覆盖/取消），不再静默覆盖；新增【CAS写前冲突校验】——上传前二次校验 revision，云端刚被其他设备更新则停止覆盖并明确提示；修复【房号改名竞态】——改名保存前先删干净云端旧目录再落盘，旧房号不再被刷新拉回"]),
        ("v2.6", "2026-11-03", ["修复：云端同步【本地空名单覆盖云端媒体】（b113，P0）——A 端新增带媒体房源后，B 端未先同步就添加同房号（不带媒体），B 端 mediaNames=[] 直接覆盖云端 info.json 致云端媒体名单变空；任一端同步时本地媒体被跟随删除、桶内媒体成孤儿。现改为合并写：写前先读云端，mediaNames = 云端∪本地−本次显式删除；字段（租金/状态/备注）仍以本地为准", "新增：【修订号 revision】（b113）——CloudHouseRecord 新增可选 revision 字段，每次成功写单调 +1；旧记录无此字段自动兼容", "新增：【房号改名真正迁移】（b113）——编辑房号保存时，除本地媒体目录迁移外，云端旧房号目录（info.json + 所有媒体对象）一并删除；解决录错房号改回后错误目录残留", "优化：操作日志【字段级 diff】（b113）——从「修改租金同步」升级为「修改租金1100→1200/房东业主→康同步」", "优化：【updatedBy 带设备标识】（b113）——署名从「涛」变为「涛(iPhone)」/「涛(iPad)」", "新增：【冲突合并日志】（b113）——写云端时若检测到该房云端已有记录（多设备/多账号并发），自动记一条冲突合并日志", "修复：编辑页【房号前缀丢失】（b113）——再次编辑时房号输入框从「1238上」恢复为「1-1238上」"]),
        ("v2.5", "2026-11-01", ["修复：房源卡片【底部上传进度条消失】（b112）——根因：保存房源时「媒体上传」与「云端账本同步」两个并发任务共用同一个进度发布器，先完成的账本任务把仍在进行中的媒体上传进度误清，导致进度条一闪而过或直接不显示；现改为活跃任务计数（begin/update/end），全部任务结束才清空，并发任务互不误清", "确认：批量上传【顶部进度条】正常——批量媒体补传/批量删除云端房源仍走全局同步任务中心，房源页顶部进度条＋可最小化收起到「设置→待补传媒体」查看，运行路径完整"]),
        ("v2.4", "2026-11-01", ["对比结论：电表【总刷新机制与 b94 一致】——逐行对比 b94（v1.98返修4）与最新版的总刷新代码，核心机制完全相同：串行 1.5 秒/台、单台查询失败重试一次、12 秒超时、失败户静默跳过。「总有几间刷新失败」根因是机制特性：单台只给两次机会，偶发网络抖动/单户接口异常即被放弃，且失败户无任何反馈", "调整：电表【取消打开 App 自动全刷】（b111）——移除「启动即先补刷一次」：打开 App 不再后台跑一遍全量刷新（设置页「定时自动刷新」开启时仍按间隔自动刷新，不受影响）", "调整：电表【取消进入板块自动刷新】（b111）——进入电表板块不再自动刷新（无数据/无最近刷新记录不再自动触发）；首次使用点「刷新」或「+」进电表管理即可拉取绑定", "新增：电表【总刷新失败户自动重刷】（b111）——手动点「刷新全部」跑完第一遍后自动把失败户号再重刷一遍（串行限速）；自动重刷后仍失败的房间弹窗列出房号，提示手动刷新（原机制失败户静默无提示）"]),
        ("v2.3", "2026-10-31", ["修复：58找房【刷不出来】（b110）——旧版补抓经纪人用信号量在主线程同步等待，40 条详情页全超时时主线程被卡约 78 秒、看起来像卡死；现改为读取完成先立即展示房源列表（标题/价格/位置），经纪人改为后台分批补抓（每批 3 个并发、单请求 4 秒超时、可失败降级显示“—”），带“正在补抓经纪人 x/40”进度", "修复：安居客【刷不出来】（b110）——读取脚本增强：已知卡片容器一个都找不到时，自动降级为全文扫描“含 元/月 的链接”兜底收集（页面改版也能解析）；验证码/反爬文案检测扩充（安全验证/人机验证/滑动验证等）；解析到 0 条时明确提示原因（页面结构变化/需登录等），不再静默显示“还没有数据”", "新增：安居客【顶栏统计】（b110）——概览区新增三列统计：房源(套) / 均价(元/月) / 最高(元/月)", "调整：房源【折叠改按钮式】（b110）——滚动自动折叠方案确认无效，改为按钮式手动收起/展开：统计栏左侧新增「收起」按钮，收起后顶部显示「筛选区已收起，点此展开」提示条（不再随滚动自动收起/展开）", "修复：房源【统计栏删错】（b110）——上一版误删整条统计栏；现恢复原版本（排序 + 1座/2座/待租数量胶囊全部保留），只删除「房源统计」4 字标识", "优化：电表【趋势图坐标刻度】（b110）——竖轴改每 5 度一刻（0/5/10/…，上限自动按 5 取整），横轴改每 1 小时一刻（整点刻度，跨度超 24 小时自动带日期），刻度字号保持原有大小；横坐标改按实际时间线性分布（刷新间隔不均时时间刻度与数据点对得上）", "调整：电表【刷新记录排版】（b110）——「第 x 次刷新」与「刷新时间」位置对调：左边时间、中间剩余电量、右边第x次（剩余电量位置不变）"]),
        ("v2.2", "2026-10-31", ["修复：58找房【标题/租金不准】（b109）——手机站显式取 `.list-item-info-title` 完整标题与 `.list-item-info-price i.strongbox` 单一价格数字，价格加 ≤6 位纯数字过滤（实测曾混入 6478124/20001019 等非价格文本）", "修复：58找房【经纪人恒为 0】（b109）——手机版列表不含经纪人，现于读取后逐个抓详情页补抓经纪人姓名/公司（并发3/6秒超时/可失败降级显示“—”），卡片显示真实经纪人", "调整：58找房【顶栏删均价/广告位，改按经纪人排名】（b109）——概览卡改三列（房源套数/经纪人位数/上榜经纪人）+「按经纪人展示房源数量」Top5 排名（第一名橙色高亮）", "新增：58找房【双 tab：58 + 安居客】（b109）——新增安居客前台找房读取（默认安居客列表页（利保米兰公馆精选页），宽松解析标题/价格/位置/面积，点卡片 Safari 打开；弹验证码自动重试一次仍失败提示；设置页可改链接与关键词）", "调整：快捷工具「58找房」改名「房源排名」（b109）", "修复：房源【滚动折叠头部无效】（b109）——首帧 List 内部未挂载导致找不到 UIScrollView 且不再重试，现延迟重试最多 10 次", "优化：房源卡片【房号不换行 + 租金去“元/月”】（b109）——房号强制单行缩放兜底，租金只显金额（分享文本仍带“元/月”）", "调整：房源【删除顶部“房源统计”标识】（b109）——统计栏删标签与数量胶囊，只留排序", "修复：电表【趋势图末点恒落 0 度】（b109）——曲线基线改与竖轴刻度一致的 0 基线，43.40 度按真实比例落点", "优化：电表【刷新记录 30→200 条 + 可导出】（b109）——保留 200 条，刷新记录 tab 新增导出 CSV 按钮"]),
        ("v2.1", "2026-10-31", ["修复：58找房【抓取弹验证码/抓到0条】（b108）——改为手机站手机版通道（iPhone UA + m 站 URL，自动剥离 reform=pcfront），58 对手机浏览器风控宽松、实测不弹验证码，关键词「利保米兰公馆」精确命中（不再抓到全城房源）", "优化：58 抓取 DOM 双结构兼容（PC 前端/手机站卡片）+ 验证码命中自动重试一次再提示", "说明：58 手机版列表不含经纪人字段（详情页可看），概览「经纪人(位)」显示 0"]),
        ("v2.0", "2026-10-31", ["新增：58同城找房板块（b105）——每次点「读取」抓 58 顺德租房列表第一页约 40 条（标题/缩略图/价格/经纪人），点卡片直开对应 58 详情页（等同浏览器点击，右上角可跳系统浏览器）；概览卡含套数/经纪人/均价/最低/最高/广告位，支持排序与只看带实拍图；缩略图本地缓存；设置可改 URL 与关键词", "优化：房源【滚动折叠头部】（b106）——列表往下滚自动收起卡片以上区域（统计/搜索/筛选），往上滚自动展开", "新增：房源【排序三档】（b106）——默认（座号/楼层/房号）/价格升序/更新时间降序，统计栏旁排序胶囊即时切换", "优化：房源【房号价格胶囊】（b106）——卡片房号与租金改自适应胶囊样式（浅灰底房号+浅绿底价格），字号不变布局不破坏", "优化：电表【趋势图坐标轴】（b106）——左侧竖轴剩余电量刻度（0/25/50/75/100%）+底部横轴时间刻度（最多4档），每个数据点用浅色虚线连到两轴，原折线走势不变", "新增：电表【刷新记录 tab】（b106）——记录页新增「刷新记录」标签：每次刷新记剩余电量+时间（最新在上，最多30条，与趋势图同源）", "优化：电表【搜索跳转卡片】（b106）——点击搜索结果跳到主列表对应户号卡片（定位+绿色高亮1.6秒），自动关搜索框", "优化：电表【卡片字体加大】（b106）——卡片「累计/抄表」字号 11 加大到 13 并加粗", "优化：电表【添加成功提示】（b106）——手动添加电表成功弹「已添加电表xx」，1.2 秒后自动关闭表单", "优化：收租统计【筛选栏一行四按钮+交租日筛选】（b106）——年份/月份/房东/交租日改紧凑胶囊一行不折叠；第4项「已收未收」改为按交租日号数筛选（选中高亮），行内已收/未收保留", "修复：b106 构建 pbxproj 中 F58 组定义嵌套破坏 Ajk 组（14 个源文件 Build input not found），已修复两组独立闭合"]),
        ("v1.99", "2026-10-30", ["新增：AI【抄表精准化】——指定某几个表号/房号抄表时只刷新指定电表（不再误触发全量刷新）；表号不在绑定列表时自动拉取云端绑定、加入清单后再抄，逐台汇报结果", "新增：AI【账单图片多张全发】——一次生成多套房账单时生成几张就在对话里展示几张，每张标对应房号；长按图片可分享到微信或保存相册", "新增：AI【可教学规则】——可用指令一步步教 AI 完成代码里没有的复合操作（操作名+步骤存本地），之后说出操作名 AI 直接展开执行", "新增：AI【历史记录展示图片】——历史列表展示 AI 生成的账单图等产物，单击可放大", "优化：AI【思考过程细化】——「正在思考…」改为展示具体执行步骤（如正在抄表 012030（2/3）、正在生成账单图片、正在整理回复…）", "新增：AI【图片单击放大】——对话与历史中 AI 产物图片单击全屏查看", "新增：AI【产物统一存储+缓存管理】——账单图片/导出表格统一存沙盒根目录「AI产物」文件夹；设置页新增「AI对话缓存」行（样式同数据文件夹大小），显示占用、二级确认清空", "优化：电表【总刷新并发提速】——刷新全部电表由逐台串行（每台间隔1.5秒）改为并发3路+交错启动限速，34台约51秒提速至20秒内完成", "新增：工作台【单月收租统计】——快捷操作新增「收租统计」入口：选择年月列出全部房源（房号+房东+交租日+当月含水电结算标记），多选自动算实收合计，按模板生成「X月份租金合计」文案（无预存/有预存/含水电结算+合计等式），一键复制", "优化：工作台【收租统计口径】——「租金+预存xx元」中 xx 为租金与预存合计金额；「含水电结算」按当月账单是否含水电结算判断（同生成账单口径）；每间标注所选月份已收/未收", "优化：工作台【收租统计】——文案每行改为「房号 X月份租金[+预存]金额」；金额读取收租计划当月实际金额；已收租的排上面、未收排下面", "优化：工作台【收租统计结算标注】——按当月账单实际内容细分：只算水费写「含水费结算」、只算电费写「含电费结算」、都有写「含水电结算」（无预存房间同样标注）", "修复：收租统计顶栏年份按钮窄屏换行；选房列表新增按房东筛选、按已收/未收筛选", "优化：收租统计筛选四选项合并一行；修复页面卡顿（文案缓存式生成+行数据字典复用）", "优化：电表总刷新提速（并发4路实测44秒全成功）并修复全失败——会话过期自动重建+失败表串行慢速补刷", "新增：电表设置总刷新速度四档选择（一台一台刷/标准/快速/极速），实测44秒全成功，选择即时生效", "修复：电表总刷新恢复b94最原始串行机制（1.5s/台单台重试，最稳定）；安居客卡片移除平台标识", "修复：桌面小组件——到期改 30 天内口径、未收租改逾期或 3 天内口径（均对齐看板）；修复租约到期解析漏 yyyy.M.d 格式致到期恒 0；移除示例假数据兜底"]),
        ("v1.98", "2026-11-03", ["新增：AI【历史查看】——AI 助手顶栏新增历史按钮（时钟图标），弹出全部对话历史列表（含执行标签/账单图标记/时间），可一键清空", "修复：工作台【待收租「收」按钮保存无效】——新建月度收租记录未先写入数据容器导致保存被静默丢弃；修复后保存失败会明确报错（红字显示在弹窗内）且弹窗不关闭", "修复：工作台【快捷收租跨月写错期】——1号交租提前几天出现在待收租列表时（如10月显示11月应交），原代码把租金写入当前月导致点收无效；现按提醒应收期（年+月）写入，弹窗明示应收期，提前交下期租也能正确入账", "修复：AI【联网搜索改百度主通道】——主用百度搜索（国内真实可用），必应 RSS、DuckDuckGo 降级为备用，百度搜不到时才切换", "新增：AI【直接生成账单图片】——AI 生成账单时复用收租页手动生成版式渲染高清账单图，直接显示在对话气泡里，长按可保存分享", "优化：AI【回复提速】——云端用量拉取加缓存且超时减半；历史注入精简；回复加长度上限，首字更快", "优化：AI【页面定位与历史】——进入对话页自动定位到最新消息；历史页正序展示、进入后自动滚到最新、支持搜索；历史保留最近 1 年", "修复：工作台【收租后待收租提醒不消失】——当月已收只看下月、不校验下月是否已收导致提前收的下期租仍显示提醒；现滚动找第一个未收期，收完即消失", "新增：AI【历史长消息展开/收起】——长消息默认折叠3行，单击展开全文/再单击收起", "修复：账单分享【点微信卡死+面板不自动关闭】——分享改为先压缩写临时JPEG文件再以文件URL分享，并在分享完成回调强制关闭弹层，三处分享统一生效"]),
        ("v1.97", "2026-11-01", ["新增：AI【安居客全量明细分析】——每套房源明细（今日/累计点击、租金、户型、推广状态、房态）全量注入，支持点击排名/推广/房态按指令分析", "修复：AI【生成账单超时】——请求超时 120s→240s + 新增「生成 XX 房 XX 月账单」工具动作，账单由合同数据直接生成，不再靠模型编长文", "新增：AI【任务后台化】——对话页关闭不中断执行中任务，App 划掉才终止；确认框挂起重开自动弹出", "新增：AI【思考期间可继续发送排队】——发送按钮不再被转圈取代，排队自动发出并显示角标", "修复：AI【房源操作日志改云端】——AI 改房源状态/信息的日志记云端（共享），与手动操作一致", "修复：AI【电表全量列出】——去掉 15 台上限，34 台完整展示，电量从低到高排序", "新增：AI【微信式双气泡】——AI 回复加灰色底气泡，用户绿底白字，双方均有气泡", "新增：AI【生成 Excel/CSV】——可导出电表/安居客/房源/欠租/收租汇总/杂项，保存到沙盒根目录", "新增：AI【回复预选项】——每轮回答给 2-3 个下一指令快捷 chips，点击直接发送", "新增：AI【联网搜索】——支持搜索公开资料返回标题/链接/摘要", "新增：AI【欢迎页 10 分钟冷却重现】——超 10 分钟无对话再次进入自动重展示问候语与场景", "新增：AI【默认偏好模板】——房产中介场景定制模板首次自动写入，设置页可一键填入/修改"]),
        ("v1.96", "2026-10-30", ["新增：AI 助手【工具调用全量接入】——6 大领域工具 34 个动作，AI 可直接操作 App：新增/编辑房源、切换待租已租（支持批量）、移入回收站/还原、标记收租/取消、修改收租设置、记成交、记杂项收支、管理待办、刷新电表/安居客、新建快速/全量备份、设置电表预警与定时刷新、查询欠租/租约到期/收租汇总", "新增：AI 写操作【系统确认框】——执行前弹窗列出全部动作明细（删除/覆盖类按钮标红），点「执行」才落地，点「取消」不执行任何更改", "新增：AI 执行动作【气泡标签】——回复气泡展示实际执行过的动作小标签（如「房源·2334 已租」「收租·2-1006 已收」），一眼可追溯", "新增：AI 操作日志【AI 标识】——AI 执行的写操作动作名带「（AI）」后缀，与手动操作区分留痕", "新增：AI 执行结果【汇报机制】——写操作后 AI 用大白话汇报改了什么（房号/谁）、多少钱、什么时间、结果如何", "新增：工具执行过程【可视化】——思考气泡按阶段显示「思考中/等待你确认/正在执行」，确认框弹起时提示待确认项数"]),
        ("v1.95", "2026-10-29", ["修复：崩溃弹窗只弹一次——只对「新增」的崩溃日志弹，同一日志不再每次启动重复弹", "修复：AI「正在思考」指示改为动态转圈（ProgressView 旋转动画）", "新增：AI 对话文字可长按复制", "新增：AI 助手接入云端用量——发送前实时拉取腾讯云桶占用（文件数/MB），云端监控场景可直接回答", "新增：电表盯防真正落地——全局定时器按设定间隔自动刷新电表（此前开关未接定时器等于没生效）；AI「电表盯防」场景一键开启（每 2 小时 + 低电量通知）"]),
        ("v1.94", "2026-10-29", ["新增：AI 助手【全量数据接入】——系统提示除房源快照外新增 App 经营数据快照：本月应收/已收/未收租金、未结清水电结算、本月杂项收支、未完成待办、电表余量（合闸/拉闸/低电量预警）、安居客统计（今日点击/推广/端口/套餐/神奇分/房产币/全城排名），五大快捷场景（云端监控/用量查询/电表盯防/批量账单/数据问答）均可读取真实数据回答", "修复：设置页 AI 模型列表编译失败——Xcode 26.3 Release 模式 body 类型检查超时，已把设置页 Form 拆分为 4 个独立子视图，编译通过"]),
        ("v1.93", "2026-10-29", ["新增：AI 助手设置页模型列表【开通状态标注】——每个模型后标注「已开通 / 未开通」（火山方舟控制台 2026-10-29 实测核实），模型说明框同步显示状态；当前账号已开通 3 个：turbo / 2.1-lite / Evolving，其余需到控制台「开通管理」页开通后方可调用", "修复：AI 错误提示【中文化】——模型未开通（ModelNotOpen 404）、额度不足（QuotaExhausted/429）、Key 无效（401/403）、服务繁忙、模型不存在等常见错误全部映射为中文提示，不再甩英文 JSON", "修复：AI 输入框【等待回答时不锁死】——发送后仍可继续输入文字/选相册/文件，回答完成后可直接发送"]),
        ("v1.92", "2026-10-29", ["修复：AI 发消息闪退根治——根因是 AI 助手用房源数据时错误地用了主容器 ModelContext（主容器 schema 不含 House 实体，fetch 抛 NSInternalInconsistencyException 直接崩溃），已改为房源专用容器 houseModelContext", "修复：崩溃日志信号处理器彻底去动态分配——信号回调内不再调用任何堆分配（malloc/数组构造），全部改为 install 时预初始化的静态缓冲 + 纯 C 接口，杜绝崩溃现场二次崩溃", "调整：取消安居客页头部固定——概览卡/预警卡/工具行回到 ScrollView 内随列表整体滚动", "调整：取消电表管理页头部固定——统计卡/工具行回到 ScrollView 内随列表整体滚动", "补全设置页版本更新介绍 v1.87-v1.91 条目"]),
        ("v1.91", "2026-10-29", ["修复：AI 发消息闪退——崩溃日志信号处理器本身存在二次崩溃隐患，已改为纯 C 接口写入日志", "调整：安居客概览卡删除「刷新时间」行（数据抓取时间保留在导航栏副标题）", "调整：安居客房源卡片推广状态改为【封面左上角胶囊】——58 同城与安居客推广同步合并，同时含「精选」时只显示精选、否则显示普通推广", "调整：安居客页面【头部固定】——概览卡/预警卡/排序工具行固定，仅房源列表滚动", "调整：电表管理页面【头部固定】——统计卡与工具行固定，仅电表列表滚动", "新增：AI 助手模型列表全量接入火山方舟账号已开通模型（共 22 个对话模型，全部带免费额度）：豆包系列 9 个 + DeepSeek 系列 4 个 + Kimi/GLM/Qwen 系列 9 个，附中文说明，设置页直接切换", "调整：房源卡片字段显示精简——去掉「顺德-龙江」前缀与面积；实地核验只显示「核验成功」；点击量行保留显示"]),
        ("v1.90", "2026-10-29", ["修复：崩溃日志全面升级——信号崩溃（SIGABRT 等）写入【完整调用栈】（信号安全接口 backtrace_symbols_fd）；日志改为【无限记录】（不再删除旧文件，同秒多次崩溃自动加序号各存一份）", "修复：安居客顶栏配色与 AI 助手/电表监控统一（深绿渐变 + 白色按钮），高度收窄（96 → 62）", "新增：安居客概览卡第一栏改为 6 项——今日点击/推广房源/剩余端口/套餐剩余(天)/神奇分/房产币（后两项从后台页面自动抓取）", "新增：安居客房源列表显示【封面图】——抓取时自动收集每套房封面缩略图并下载到本地", "调整：房源卡片点击量行（今日点击加粗深绿/累计/较上次±N 分色 + 平台胶囊 + 维护人）恢复显示；推广状态改为平台锚定精确提取并合并显示"]),
        ("v1.89", "2026-10-29", ["修复：AI 助手顶栏与聊天区连体——顶栏改深绿渐变（与 App 主题一致）、按钮改白色高对比", "修复：AI 助手输入框整体下移贴底（背景延伸到屏幕底部安全区）", "修复：对话内编辑文字闪退风险——附件图片移除按钮越界加固", "修复：安居客后台点「读取」报「执行JavaScript返回结果的类型不受支持」——抓取脚本末尾返回 void，经 messageHandler 异步回传", "修复：安居客后台顶栏配色——深绿渐变改为安居客品牌蓝渐变（主页面与登录页统一）", "新增：AI 助手设置模型列表支持云端扩展——内置已开通模型并附说明，「远程配置 → AI 模型清单」可追加其他已开通模型（含免费）"]),
        ("v1.88", "2026-10-29", ["AI 助手六项升级：①顶栏改浅色配色、高度收窄；②支持多轮对话（自动携带上下文）；③接入 App 本地房源数据——提问自动把房源快照注入系统提示，问「有几套未出租」直接据实回答；④回答前显示「正在思考」气泡；⑤对话历史自动保留（最近 60 条，顶栏可一键清空）；⑥支持发送图片/视频（自动截首帧）/文件（txt/md/json/csv/pdf 自动提取文本）", "修复：快捷操作「排序」页改版——上区点减号收进「更多」、下区点加号移回工作台，拖拽排序保留，改动即时保存"]),
        ("v1.87", "2026-10-29", ["修复：AI 助手设置改为「输入即保存」——API Key/模型/接口端点/偏好模板改动立即生效，移除旧「保存」按钮", "修复：设置里默认模型名改为火山方舟正确模型 ID（doubao-seed-2-1-turbo-260628，旧短名自动迁移）", "修复：自定义模型 ID 保存后再次进入设置自动回填显示", "修复：电表管理批量导出记录全选按钮支持反选（已全选时变为「取消全选」）", "修复：工作台「更多」面板关闭后切换板块不再重复弹出"]),
        ("v1.86", "2026-10-29", ["修复：工作台快捷操作补入「安居客」「AI 助手」两个入口（旧版本安装自动迁移，打开 App 即可见，排序可自行调整）", "新增：设置页加入「安居客后台」设置入口（后台 URL / 实地核验预警天数 / 下架预警天数 / 最大翻页数 / 历史快照开关）", "新增：设置页加入「AI 助手」设置入口（API Key 存钥匙串、模型选择、接口端点、偏好模板），入口显示 Key 配置状态"]),
        ("v1.85", "2026-10-29", ["新增「安居客后台」板块（工作台 → 安居客，移动经纪人真实图标）：读取你自己的安居客/58 移动经纪人推广房源数据（今日/累计点击、房态天数、已编辑天数、推广平台、核验/维护/视频/质量），本地保存、历史快照留痕（最近 30 次），只读展示、绝不做任何发布操作", "登录方式：App 内嵌后台页面，登录一次持久（cookie 保留），之后点「读取」直接抓取", "预警：房态 ≥ 7 天（默认可改）标红提醒「需实地核验」；已编辑 ≥ 90 天（默认可改）标红提醒「将自动下架」，支持「只看预警」筛选", "概览卡：今日点击 / 推广房源 / 剩余端口 / 套餐剩余天数", "排序：今日点击 / 累计点击 / 房态天数 / 已编辑天数；点击量旁显示较上次快照的增量", "安居客设置：后台 URL、两个预警阈值、最大翻页数、历史快照开关均可修改", "新增「AI 助手」（工作台 → AI 助手，豆包 logo）：火山方舟豆包模型对话，5 个快捷场景一键带入（云端监控 / 用量查询 / 电表盯防 / 批量账单 / 数据问答）", "API Key 只存本机钥匙串（Keychain），不上传不备份；模型、接口端点、偏好模板（调教）都在设置页可改，不做死", "工作台快捷操作升级：默认两行 8 个（成交/收入/支出/收租 + 待办/电表管理/安居客/AI 助手），「更多」收纳后台管理/包租/水电结算/新增房源"]),
        ("v1.84", "2026-10-28", ["修复官方电表接口联调根因：官方接口只认表单格式，App 请求已全部改为表单发送，同步修正数据解析，直连模式全链路实测通过", "新增「电表监控」板块（工作台 → 电表管理）：集中查看全部电表余额/累计用量/状态/抄表时间，进入自动刷新、串行限速查询，仅读取展示、充值仍走官方页面", "双数据源可切换（设置 → 电表监控）：直连接口（默认）+ 网页抓取兜底", "电表管理：一键导入当前微信身份绑定的全部电表 + 手动增删 + 备注房号", "电表卡片三行布局：户号+房号+状态 / 剩余电量+记录充值 / 累计+抄表时间+单表刷新；低电量与拉闸时户号、房号、电量同步变红；单台刷新有刷新中/完成提示", "排序 + 筛选（低于 X 度可输入 + 拉闸）", "充值记录按表查看（进入自动刷新 + 手动刷新按钮）+ 用电趋势（每次刷新自动积累剩余电量走势，原生折线图）", "导出 CSV：自动同步官方绑定（关系始终准确）、默认不勾选、全选只增不减、支持排序与搜索、手动输户号一行一个", "顶栏新增搜索（放大镜）：按户号或房号快速查找电表", "低电量提醒（阈值可配，每天每户最多一次）+ 可选定时自动刷新（默认关）", "电表查询链接自定义更换入口：换微信换链接即更新 openId 并重置会话", "工作台快捷操作改版：两行新布局 + 「更多」收纳 + 自定义排序实时保存"]),
        ("v1.83", "2026-10-28", ["媒体预检优化：无变化刷新时从「逐房号串行列桶」改为「一次整桶拉取比对」，房源再多刷新也只发 1 次云端请求，明显提速", "同步下载限流：账本下载改为每次最多并发 8 套，房源多时不再因瞬时并发过高触发云端限流", "同步失败自动重试一次：弱网/信号切换导致的瞬断会自动补一次，不再手动反复点刷新", "后台功耗优化：通知重建与小组件同步改为「数据保存时」触发，不再每 30 秒空转", "公告链接安全：只放行 http/https 链接，异常 scheme 一律忽略", "崩溃留痕与提示：数据库异常等致命错误自动写入崩溃日志，下次启动提示「上次异常退出」，设置页可导出定位", "媒体补传进度文件级：进度条显示当前房号「本套 x/y 个文件」，一眼分清是图多还是卡住", "云函数请求超时参数化：列桶/用量统计等大操作放宽到 30 秒，不再因大桶超时失败", "新增自动化测试：云函数 19 项核心逻辑测试（口令/签名/超时/路径防护/埋点去重）+ Swift 核心逻辑自测脚本（Mac 上 swift 一键运行）"]),
        ("v1.82", "2026-10-28", ["远程配置页全面中文化：功能开关/数值参数/提示文案/帮助说明全部显示中文名称，英文 key 以小字副标题展示便于对照", "远程配置页排版优化：分区图标化（基础设置/功能开关/数值参数/提示文案/帮助说明/版本更新记录）、公告开关联动显示文字与链接、更新日志支持左滑删除、底部增加保存按钮"]),
        ("v1.81", "2026-10-28", ["远程配置原生化：App 内管理后台新增第 4 个「远程配置」页，公告/功能开关/参数/提示文案/帮助文本/更新日志全部可在 App 内直接编辑保存，不再需要跳网页后台、不再下载文件", "原生远程配置页与云端网页后台同源：加载=云端 configGet，保存=云端 configSave（自动版本+1），保存后同步写本地缓存，断网仍用最新配置"]),
        ("v1.80", "2026-10-27", ["新增「远程配置中心」：云端后台可可视化编辑提示文案/功能开关/参数/公告/最低版本/帮助说明/版本更新记录，保存后 App 启动或同步即生效，无需重新安装", "新增公告横幅：后台填写公告 → App 房源页顶部即时显示（可带链接）", "新增最低版本检查：云端可设置最低版本，低于该版本启动提示更新", "远程配置三级兜底：云端 → 本地缓存 → 内置默认；断网时用本地缓存，首次安装用内置默认，功能不受影响", "提示文案（同步/删除/备份/离线重建等 20+ 条）改为云端可配，不再需要发版改文案"]),
        ("v1.79", "2026-10-27", ["修复账本增量未真正生效：增量对比从「字节全等」改为「业务字段+媒体清单语义」判断，updatedAt 等元数据不再干扰，真正无变化的房源刷新时零写入、不记日志"]),
        ("v1.78", "2026-10-27", ["本地账本镜像改为增量同步：每次刷新逐套与现有账本对比，有差异才写入、无差异跳过（房源再多也只写变化的套数），提示与实际写入套数一致"]),
        ("v1.77", "2026-10-27", ["本地账本镜像改为仅在「左上角云端同步」后重建（下拉刷新不再触发），重建完成有提示并写入操作日志（同步-重建本地账本镜像）"]),
        ("v1.76", "2026-10-27", ["修复「刷新同步提示无变化时未把账本同步到本地」：下拉刷新、云端同步、同步完成的全部成功路径都会重建本地账本镜像（media/<房号>/info.json），保证每次刷新后本地账本与云端一致"]),
        ("v1.75", "2026-10-27", ["新增「离线重建房源」（设置→数据管理）：无需联网，从本机 media 账本（每套 info.json）一键重建/刷新全部房源记录，数据库丢失或断网时可用，不删除现有数据", "修复同步误删「本地账本镜像」：同步对账把每套的 media/<房号>/info.json 当成多余媒体删掉（实测一次删 7 套）——现已排除该文件，不再误删", "同步完成后自动重建/刷新全部本地账本镜像，与云端完全一致", "（说明：房源图片命名自带唯一ID（如 1-2059-JPG-A3F9C2-1.jpg），删除旧图换新图文件名必不同，其他设备刷新可正确同步新图）"]),
        ("v1.73", "2026-10-27", ["刷新/同步结果提示改为原生悬浮横幅：顶部轻量胶囊、自动消失（替代原来占半个屏幕的居中弹窗）", "删除、批量标记等操作结果同样改为悬浮横幅提示", "需要你确认的操作（同步变更确认/删除确认）仍保留弹窗"]),
        ("v1.72", "2026-10-27", ["刷新提示框重做：点刷新立即显示「正在刷新…」横幅+按钮转圈，比对完成才出结果（不再干点没反应）", "修正「版本更新介绍」顺序：改为按日期倒序（v1.71 置顶，此前 v1.50-1.53 误排最前）", "房源卡片租金字体/颜色恢复原样（headline 加粗 + 主题色）", "批量恢复/导入后不再自动上传云端（此前导入即自动传媒体且不建账本）；改为等手动点「刷新同步」先比对再统一补传，并清空自动补传队列", "操作日志动作细化：编辑保存按实际改动字段命名（修改租金同步/修改户型同步/修改状态同步…），不再笼统记「同步房源」", "本地房源账本改一房一账本：与云端同构，每套 media/<房号>/info.json（保存/导入/同步/恢复联动），删除整套=删 media/<房号>/ 文件夹一步到位", "任何涉及云端同步的动作都显示卡片进度条：纯文字编辑保存、状态切换、补传账本均有「同步中」反馈"]),
        ("v1.71", "2026-10-27", ["云端账本改为一房一文件（h/<房号>/info.json）：改一套写一套、并发不再互相覆盖，删除整套=删 h/<房号>/ 文件夹一步到位", "删除一致性：单套/批量删除同删 h/ 与私有区（分享页+首帧图）", "编辑保存只在媒体有变化时才触发上传（纯文字修改不再全量重传媒体）", "媒体上传失败自动重试一次，日志带具体错误原因", "批量删除云端加同步进度条，云端删完才弹完成提示", "刷新进度条完成后自动收起；修复最小化后新任务不显示", "完成提示框全局化：离开房源板块也能点「好」", "房源卡片租金字体与房号一样大", "批量恢复文件选择框白屏缓解", "修复编辑换图后媒体落盘无前缀目录（卡片黑图）"]),
        ("v1.70", "2026-10-27", ["修复「刷新标识不会自己收起」：同步/媒体补传进度条任务完成后 1.2 秒自动收起，不再需要手动点「完成」", "修复「批量恢复媒体后卡片不显示缩略图/显示无实拍图，必须重启才正常」：列表刷新时强制重载每套房源对象（含媒体关系），恢复后立即显示", "云端配置小字说明还原为仅讲配置口径（v1.69 曾误并入版本更新内容，已撤销）"]),
        ("v1.69", "2026-10-26", ["修复批量删除不彻底：此前每套房源并发读改写云端账本互相覆盖，删除 7 套后账本仍残留 3 套，且删除日志只记 4/7、有的只记「删文件夹」；改为单任务串行删除 + 每套一条「彻底删除（本地+云端）」完整日志", "修复同步弹窗/日志显示无前缀房号（1417上 等）：所有弹窗、提示、日志、同步详情一律真实引用完整房号（带 1-/2- 前缀），不再去前缀简化", "新增房源表单房号强制带座号前缀（1- 或 2-），不带前缀无法保存并红字提示；输入时实时红字提示", "批量恢复/清单导入/媒体包导入/扫描补录强制带前缀：无前缀房号不识别到列表，并提示哪些房号不符合规范；删除无前缀目录兼容逻辑（v1.62 遗留回退），减少幽灵房源", "全量备份恢复房号归一：备份中历史带前缀脏数据恢复后统一为「无前缀+座号」内部结构，媒体目录/显示仍带前缀", "房源列表「全部户型」筛选固定在最左，不随右侧户型横向滚动", "更新设置页「云端配置」小字说明（同步机制、待补传媒体、房号前缀规范）"]),
        ("v1.68", "2026-10-26", ["同步/媒体补传改为「确认后执行」：先干跑检查云端缺哪些媒体的详情弹确认框，确认后才开始上传（不再静默后台跑）", "新增同步任务进度条（房源页顶部）+ 可最小化收起到「待补传媒体」页随时查看进度", "修复数据文件夹大小统计漏掉 media 媒体目录（v1.40 起媒体独立目录）", "操作日志颜色修正：云端日志结果字段不总是「成功/失败」，改为明确失败词才标红"]),
        ("v1.67", "2026-10-26", ["修复左上角刷新「点击没反应」：云端媒体对账/补传在后台线程访问 SwiftData 模型导致崩溃，改为主线程提取值快照、后台只做网络请求", "媒体补传与云端对账改为线程安全（SwiftData 属性仅主线程访问）"]),
        ("v1.66", "2026-10-26", ["修复保存房源偶发误报离线（NWPathMonitor 瞬态误判，改为短时等待确认）", "新增「待补传媒体」后补任务页：集中查看上传失败/待补传媒体，一键全部重试、左滑清除"]),
        ("v1.65", "2026-10-26", ["同步补传房源后自动上传本地媒体（幂等+刷新分享页，与批量导入同机制）", "同步「已刷新，无变化」时自动做云端媒体对账：本地有媒体但云端桶缺失的自动补传并提示明细，桶齐才提示无变化"]),
        ("v1.64", "2026-10-26", ["修复批量恢复后同步死循环/云端房源丢失：本地多套房补传云端时改为聚合一次写账本（此前逐个并发「读改写」同一账本文件，最后一次写回覆盖其他结果，实测 7 套只剩 2309 一套；补传失败保持「仅本地」并提示，不再误标「双端」）", "媒体下载兼容 v1.62 及更早的无前缀云端目录（h/2309上/）：账本带 1- 前缀但旧媒体在无前缀目录时也能找到，避免「本地缺媒体」反复循环"]),
        ("v1.63", "2026-10-26", ["房号/媒体目录统一保留座号前缀：1 座、2 座都显示与存储为 1-xxx / 2-xxx（恢复清单、媒体文件夹、列表显示一致；存量无前缀目录扫描/导入时自动迁移归位）", "恢复（云端/本地/旧版 JSON 备份）完成后发刷新通知：媒体也一并恢复后房源列表立即更新，无需退出重进", "云端操作记录不再提供一键清空，改为左上角「多选」勾选后删除（仅本机日志可清空）", "批量导入/批量恢复接入本地操作日志（操作日志-本机操作可查）", "房源板块下拉刷新改成本地刷新：自动检测并补全缺失的媒体记录（磁盘有记录无 → 补建），有变化列出明细、无变化提示「已刷新，无变化」；左上角刷新按钮保持云端同步不变", "批量导入模板示例改为带前缀写法（1-2334上 / 2-1418下），页面说明同步更新"]),
        ("v1.62", "2026-10-26", ["修复批量录入后房源列表不刷新（需退出重进才显示）：导入完成即通知列表刷新", "修复媒体恢复错乱：1 座房号带「1-」前缀（如 1-2245上）与 App 存储的无前缀目录（2245上）不一致，导致媒体读不到、双目录并存——导入/扫描自动归一目录并迁移存量错乱目录，读取兼容带前缀目录", "批量导入/扫描时对带 1- 前缀的目录自动合并到无前缀目录（点一次扫描补录即可修复存量错乱）"]),
        ("v1.61", "2026-10-26", ["批量录入媒体包兼容性加强：zip 支持 DEFLATE 压缩（电脑 WinRAR/发送到压缩文件夹压的 zip 现在能识别），中文文件名编码兼容（GBK 回退）", "媒体包可直接选文件夹（无需压缩）：zip 或文件夹均可，文件夹内按房号分子目录即可", "清单导入预览回显原始输入（1-2245上 不再被删成 2245上）：CSV 写什么预览显示什么；座号留空时房号带 2- 前缀自动判 2 座，状态留空默认待租（页面说明已注明）"]),
        ("v1.60", "2026-10-26", ["导出房源模板 CSV 加 UTF-8 BOM：在 Windows 的 Excel/记事本打开不再乱码", "导入 CSV 编码自动识别：支持 UTF-8（含BOM）/ GBK（Excel 中文版另存）/ Unicode，电脑填好的清单发回手机也能正常读取"]),
        ("v1.59", "2026-10-26", ["批量录入优化：①清单导入新增「导出模板」按钮（生成带表头+示例行的 CSV，可存到文件/发微信）；②「从文件选择 CSV / zip」改用系统文档选择器，修复点击无反应；③媒体包导入增加解析预览（每行显示动作）；④扫描补录/解析预览每行写清动作（新建房源 / 补挂 K 个 / 媒体齐全 / 重复跳过）", "修复扫描补录反复提示补媒体的 bug：扫描模式文件已在正式目录，改为只补建缺失的媒体记录（不再复制文件），确认后再次扫描不再误报", "房源板块导航栏：多选按钮从右上角移到左上角刷新按钮旁边；右上角保留批量导入 + 新增"]),
        ("v1.58", "2026-10-26", ["新增「批量录入」功能（房源列表右上角 ⬇ 图标）：①清单导入——粘贴或选择 CSV（房号,座号,房东,户型,租金,密码,备注,状态），解析预览后一次导入；②媒体包导入——选择 zip（根目录下按房号建文件夹放照片视频），自动挂媒体到已有房、未收录房号自动新建房源；③扫描补录——扫描 Documents/media/ 下已按房号建好的文件夹，自动建房源/补媒体记录", "开启文件共享（UIFileSharingEnabled）：电脑连接后可在访达/文件里看到「公寓管家」的 Documents，把按房号分好的照片视频文件夹拖入 media/ 下，回 App 点「扫描补录」一键录入", "批量导入的房源自动触发：媒体上传云端 + 自动生成分享 H5（与新增/编辑保存后同机制）", "CSV 支持中文逗号/制表符分隔、表头自动识别、重复房号自动跳过并提示"]),
        ("v1.57", "2026-10-26", ["全量备份补齐房源字段：新增导出/导入 cloudStatusRaw（云端状态）与 lastUpdatedAt（最后更新时间）——修复「全量备份恢复后所有房源变『仅本地』，再同步时把云端已删房源当作本地新增补传回云端（已删房源复活）」的隐患", "备份房源结构 schemaVersion 5 → 6（兼容旧备份：缺这两个字段的旧备份恢复时维持原行为）"]),
        ("v1.56", "2026-10-26", ["快速备份不再包含房源字段：快速备份 = 账本 + 媒体清单 + 日志（不含房源、不含照片视频），房源统一从云端同步恢复——彻底解决「恢复旧快速备份后，已删除房源因变成仅本地而被重新上传回云端（复活）」的问题", "恢复快速备份时跳过房源导入（即使旧版备份含房源 JSON 也不再导入），恢复后房源列表需从云端同步拉回；全量备份保持不变（账本 + 房源 + 照片视频）"]),
        ("v1.55", "2026-10-25", ["公开选房链接增加有效期（默认 2 天）：可在「设置 → 房源分享 → 选房链接有效期」调整为 1/2/3/7/15/30 天；重新生成链接会先删除旧壳（旧链接立即失效），到期后旧链接自动打不开", "选房页访问计入获客统计：选房页每次打开/刷新埋点（按用户名分文件），网页后台登录自己的用户名即可看到选房页访问数据", "云端部署包：选房壳内嵌云函数地址不再硬编码，改为自动取当前云函数地址或环境变量 FUNC_URL（同一桶多用户/多部署互不串地址）"]),
        ("v1.54", "2026-10-25", ["新增/编辑房源保存后自动生成脱敏版分享 H5（删旧生成新），选房链接里每间房点开即有完整详情页", "「刷新分享缓存」升级为全量重建：云端旧分享页全部删除（旧链接立即失效）+ 每间房重新生成最新 H5", "选房页名片区永远沉底显示（默认取设置页名片，云端名片更新实时刷新），无房源时中间留白名片沉底", "选房壳模板统一为名片沉底新版布局"]),
        ("v1.53", "2026-10-25", ["选房页 JS 根治：onerror 改为无引号嵌套写法，任何版本生成的壳脚本都不会再坏", "线上壳直接修复为可用版本（脚本正常 + og 签名有效），不再依赖重新生成即可显示房源"]),
        ("v1.52", "2026-10-25", ["修复选房页打开一直「加载中」：封面 onerror 单引号未转义导致脚本解析失败，已修复 JS 转义", "微信卡片提示：分享必须用 App「分享给租客」或微信内右上角分享，复制粘贴链接只显示纯链接"]),
        ("v1.51", "2026-10-25", ["修复选房页封面不显示：封面从 CSS 背景图改为 <img> 标签加载（微信兼容更好），加载失败自动隐藏占位", "卡片点击有反应：有分享 H5 的房源点击直接打开完整详情页；没有的全屏放大封面预览", "修复微信分享卡片无信息：og:url 改用壳自身自定义域名签名链接，og:image 改用第一套房封面（此前指向不存在的 qrcode.jpg 导致微信只显示纯链接）", "设置压缩开关改名「压缩上传媒体（房源+分享）」：新增/编辑房源媒体上传云端与分享 H5 都会压缩（图片长边≤1600、视频 720p），上传更快", "云函数 rooms_json 新增 share 字段（每套房分享 H5 的自定义域名签名链接）"]),
        ("v1.50", "2026-10-25", ["选房链接彻底对齐单房分享H5：App本地生成选房静态壳上传COS，链接用自定义域名签名（与单房H5同机制），微信内正常打开不再下载", "分享出微信卡片：壳内og标题/描述/封面图全走自定义域名，微信分享渲染成卡片（房源实拍图+米兰公馆·在租房源）", "云函数rooms_json支持cd参数：选房页封面/二维码签名URL全部走自定义域名", "未配置自定义域名时App内明确提示（与单房分享H5相同要求）"]),
        ("v1.49", "2026-10-25", ["修复微信打开选房链接变「下载文件」：链接改走 COS 域名（与单房分享 H5 同机制），云函数生成静态壳存桶 users/用户名/rooms/ 并返回 COS 签名链接，微信内直接打开正常显示", "选房页数据仍实时：页面 JS 每次打开/刷新实时拉云端房源/名片/二维码，改房源改名片后租客刷新即最新", "修复云函数中文路径 COS 签名（users/涛/… 此前 403）：原始路径签名+编码路径发送；选房页封面签名改 10 年长效"]),
        ("v1.48", "2026-10-25", ["「公开选房链接」页内新增「编辑名片 / 二维码」直达入口：修改名片/换二维码不用再退回上级菜单，保存后租客刷新选房页即最新", "选房页补微信卡片信息（og 元数据）：微信里分享链接渲染成卡片，浏览器打开为完整网页（修复旧版打开下载数据文件）"]),
        ("v1.47", "2026-10-25", ["新增「公开选房链接」：设置 → 房源分享 → 公开选房链接，一键复制/分享给租客——对方打开实时看到所有待租房源（只显示户型，房东/密码/备注隐藏），新增/下架房源、改租金后刷新即最新", "名片/二维码实时同步云端：名片保存后上传云端 profile.json，二维码保持实时上传 qrcode.jpg；公开选房页每次刷新都读最新名片与二维码", "选房页卡片 2 列正方形网格，封面为视频预览图/实拍图，带完整防保存机制（禁右键/禁长按/图片背景图渲染，与单房分享 H5 一致）"]),
        ("v1.46", "2026-10-25", ["获客统计按用户名隔离（云端）：分享 H5 埋点带用户名，云端按用户分文件记录；后台统计、清空都只操作当前用户名名下的数据，多个用户共用同一云函数地址互不干扰", "App 内获客分析页明确显示统计归属当前用户名；分享记录说明同步更新为实际路径"]),
        ("v1.45", "2026-10-25", ["「打开『文件』App 查看数据文件夹」点击直达房源图片视频所在 media 文件夹：Info.plist 补上 LSSupportsOpeningDocumentsInPlace（此前 iOS 无法定位子目录，只落到文件 App 根目录）", "云端配置页保存用户名 / 云函数地址后返回再进立即显示最新值：页面出现时从存储重读全部配置字段（与分享水印开关、微信二维码同款修法，不再需要退出 App 重进）"]),
        ("v1.44", "2026-10-25", ["详情页自动下载后即时显示：删除媒体/缺文件后自动补缺，下载完成立即刷新媒体区，不再空白占位等重启", "配置备份补全云函数地址与用户名（此前备份只含桶/地域/密钥/域名，换机还原后后台连不上）", "文件 App「用其他 App 打开」导入配置备份被识别：自动复制进备份目录并弹提示，可一键还原", "「从其他位置选择」备份文件按钮修复：文件选择器在列表视图内自挂，点击立即弹出"]),
        ("v1.43", "2026-10-25", ["同步「下载2个删2个」死循环根治：下载只认云端账本名单（不再把视频首帧图/旧分享页等未登记对象当媒体下载），本地多余残留一次清理收敛", "本地删 media 文件后同步刷不回：账本/本地记录/磁盘真实文件三名单对账，缺媒体自动从云端回补、多余跟随删除", "视频 .mov/.mp4 两套名字打架：归一化等价比较（去扩展名小写），下载落盘名与账本完全一致", "日志操作记录区分方向：同步房源（云端→本地）/（本地→云端）、上传媒体（本地→云端）、删除媒体（本地→云端）等明确标注", "详情页打开自动补缺：记录在但磁盘文件缺失且云端有，自动下载回补；云函数配置按钮样式对齐 COS 按钮"]),
        ("v1.42", "2026-10-25", ["断网刷新不再误删本地房源：云端账本读取拆分明细，网络/解析失败必须抛错中止，只有服务端明确 404 才视为云端无数据", "完全断网保存必出提示：实时网络判定 + 媒体上传失败立即弹「已保存到本机，媒体将自动补传」并入队，联网自动上传", "同步提示/日志统一逐套列房号：新增/更新/删除/补传/媒体差异只要有对比差异就列出具体房号（如「新增 1-2036」「云端删除 1-101」）", "后台分享记录读不到修复：云函数 do_shares 双重编码 + 中文路径 COS 签名 403 根因修复（签名按原始未编码路径、发送用百分号编码 URL），分享记录正常返回", "房源卡片底部细进度条实时展示「上传中/同步中 x%」，覆盖上传云端与同步本地两条链路", "微信二维码保存即时生效：保存/清除立即同步桶内 users/<用户名>/qrcode.jpg，已发 H5 动态引用即更新", "全 App 开关即时生效统一排查：按水印开关修法（显式 Binding 写入）修复自动备份开关等同类开关"]),
        ("v1.41", "2026-10-25", ["水印开关即时生效：显式 Binding 拨动即存，设置页入口副标题 onAppear 刷新返回即显示最新", "同步无变化不再弹确认：更新判定改字段级对比（房号/房东/户型/租金/密码/备注/状态/媒体清单，任一不同才算变化）", "后台分享记录空记录不再一直转圈：加载完成标志 + 空态显示「暂无分享记录」", "云端操作日志核对：确认日志真实记录在云端桶（带用户名），全局共享可见为有意设计（多人协作审计）", "媒体同步细粒度（核心）：媒体文件名带唯一 ID，删光旧照片重加新照片不再撞名；编辑保存后媒体即时上传/删除同步删云端；双向 reconcile 媒体差异；恢复备份后视频打不开修复", "快速备份恢复统计去房源字段（房源/照片/视频只在全量备份恢复时展示）；云函数配置三按钮合并为「保存并验证 + 清空地址」；清空全部配置补清云函数地址与用户名"]),
        ("v1.40", "2026-10-25", ["云端私有数据全部收进 users/<用户名>/（分享页/封面/缩略图/二维码/分享记录/备份/媒体镜像），删房连带删用户分享页——多用户数据隔离基础", "本地根目录重建：备份 + media 两平级文件夹，启动幂等迁移；全量恢复 media 解压到 Documents 根（修复 media/media 套层 + 详情乱套）", "云端同步先弹变化确认（含新增房号 / 他人修改者 / 删除 / 补传明细），确认后才应用", "新增/编辑房源无网络先提示仅存本机；房源媒体上传失败入队自动补传（联网自动补）", "水印开关即改即存；分享 H5 媒体上传前 HEAD 探测去重、视频首帧图每次重新生成；H5 缓存命中简化", "桶管理删除仅删云端对象（本机文件保留）；云函数 track 服务端 30 秒去重；后台 401/失败统一文案；操作日志 + 崩溃日志并入快速/全量备份", "云函数地址独立保存/验证/清空、口令入钥匙串；部署包下载改 App 内图文教程；分享记录写新路径并清旧路径；全量备份媒体完整性校验；旧备份兼容 + 上传幂等"]),
        ("v1.24", "2026-10-24", ["多用户数据隔离：云端备份按用户名分目录（backups/<用户名>/），各用户只看得见自己的备份，另一台手机读不到你的经营数据；媒体镜像按内容去重共享（不含隐私）", "分享记录按用户名隔离（h/_share_records_<用户名>.json），各用户只看自己发的分享；网页后台同步按用户名读取", "用户名不设默认（不预填「涛」），保存时强制非空；云端保存时若没设用户名会提醒，未设名时备份/分享统一归到「未设置」名下，不会误覆盖别人数据"]),
        ("v1.23", "2026-10-24", ["桶管理修复：文件行的「复制下载链接」与「删除」按钮独立区分（此前 iOS 17 列表手势会误触发删除），复制不再误弹删除框", "桶管理顶部新增「访问腾讯云储存桶」图标：一键跳浏览器腾讯云 COS 控制台（登录后可直接管理桶）", "桶储存用量卡片移到桶管理页顶部（原在获客分析），获客分析保留「清空访问统计」按钮"]),
        ("v1.22", "2026-10-24", ["App 内管理后台补齐为完整最新版：获客分析页新增「桶储存用量」卡片（总占用 + 分项，可刷新）+「清空访问统计」按钮（一键删除 test101 等测试埋点，重新累计）", "桶管理改走云函数接口（与网页后台一致）：点进房源文件夹自动展开 media/，图片视频直接显示，不再空白", "以后网页后台每次改动，App 内后台同步生效；浏览器版作为可选补充"]),
        ("v1.21", "2026-10-24", ["设置页云端配置新增「刷新网页后台缓存」：以后网页后台每次改动（重新部署云函数）后，点一下这个按钮就清掉网页缓存、换新版本戳，再打开后台立即是最新版，不用重新构建 App", "管理后台右上角 Safari 打开网页后台时，改用动态版本参数强制浏览器取最新页，网页改完不会再看到旧版"]),
        ("v1.20", "2026-10-24", ["云端后台时间改为北京时间（此前显示像美国时区），新增「清空访问统计」一键删除 test101 等测试埋点，可重新统计", "桶管理点进房源文件夹自动展开 media/ 直接显示媒体文件，少点一层；新增「储存用量」卡片显示总占用与分项（访问统计/房源媒体/房源分享/云端备份）", "操作日志分「本机操作 / 云端操作」两区：本机操作记本地，本机发起的云端操作直接记到云端区（不重复显示）；云端区显示操作者用户名，同桶多用户的桶操作会同步显示", "操作日志支持左滑删除 + 多选删除（进入编辑模式勾选后删除）；云端区删除走云端记录，下拉可刷新", "云端配置板块新增「使用说明」：单用户 / 多用户详细操作说明（展开块式，大白话），三端互通说明移入云端配置", "分享 H5 缓存口径统一：缓存存本地，刷新只清本地，不影响云端"]),
        ("v1.19", "2026-10-24", ["一套配置、多人使用：房源在云端共享（新增/编辑/状态变更自动双写云端），两台手机或两个人用同一个桶可互相看到房源", "房源卡片新增三态标识「本地 / 云端 / 双端」，卡片显示最后更新时间（首次录入时间，改已租/待租时刷新）", "房源板块新增下拉刷新 + 左上角手动同步（拉取云端房源），共享房源以「最后保存的为准」", "纯云端房源（别人录入的）可一键下载到本地；编辑/分享/一键保存会自动先下载再操作", "删除房源提示是否同步删除云端；操作日志全面接入成交/收租/包租/水电/分享/导出等所有动作", "操作日志：保留 45 天、显示操作者用户名（云端多用户可见是谁操作的）、查看器加搜索框、设置页显示日志占用空间", "设置页新增「多用户」：填用户名 + 一键导出「给别人用」的配置（bucket/密钥/域名/云函数/用户名），发给别人填上即可共享"]),
        ("v1.18", "2026-10-23", ["云端后台统一成一套自适应（responsive）：手机 / 桌面同一网址，浏览器与 App 打开同一个后台，排版随屏幕自动适配", "设置页新增「云端配置」板块（合并原远程配置）：云函数地址（后台网址）、COS 存储桶/密钥/域名、后台口令、下载云端部署包集中在一处", "首页「管理后台」入口链接改为可设置：随「云端配置 → 云函数地址」走，别人部署后填自己的地址即可打开他自己的后台", "新增「下载云端部署包」：把一键部署脚本 + 图文说明（zip）导出到本地，发给房东在电脑上运行即可在自己的腾讯云部署云端后台", "取消单机 / 云端模式切换构想：保持「本地数据 + 云端桶/云函数」既有结构，本地记账数据始终保存在本地"]),
        ("v1.17", "2026-10-23", ["修复点房源卡片闪退：成交/在租/退租的关联查询改用主容器，不再在房源独立容器查未注册模型", "崩溃日志改为内置查看器：逐份查看完整内容，右上角「导出」直接生成 txt 到 App 根目录（命名「崩溃日志_导出日期」）", "操作日志右上角「完成」改为「导出」：直接生成 txt，命名「操作日志_导出日期」，存 App 根目录", "分享水印改为叠加在每张图片的右下角（不再是页面右下角）；预览同步为多张图片、每张各自带水印", "App 内「管理后台」直接换成云端后台（网页 WebView），免登录打开", "设置里修改「管理后台口令」保存后自动同步云函数（云端后台、网页后台立即用新口令）", "云端后台去掉演示/示例，全部通真实数据：获客统计、分享记录、桶文件管理均读取云函数实时数据", "三端互通非实时处补「刷新」按钮：云端后台每个板块顶部都有刷新，桶文件支持逐级浏览/下载/删除", "App 版本记录更新到 v1.17", "设置页新增「三端互通」详细介绍与使用说明"]),
        ("v1.14", "2026-10-23", ["云端下载备份直接用原名落盘，下载的备份在「查看备份文件」里直接可见可恢复（不再带「下载_」前缀被列表过滤；旧的「下载_」文件自动识别归组显示）", "外部导入备份弹「立即恢复 / 稍后再说」二级确认；立即恢复走完整恢复流程，完成弹窗显示恢复口径（成交/在租/有效房源/照片视频等分行统计 + 全部核对无误）", "恢复云端备份时明确提示来源：本地已有同名则直接用本地恢复、本地没有则自动下载到本地后恢复，完成弹窗与操作日志均写明", "快速备份与全量备份都支持手动上传到云端（快速只传 zip 本体，全量再传照片视频增量）", "房源详情「一键转发朋友圈」改为「转存到微信」：图片（前 9 张）+ 视频全部进分享面板，到微信里选「收藏」后再自行转发朋友圈", "修复房源左滑「删除」确认无反应：合并多个弹窗为单一确认弹窗，消除 iOS 17 弹窗互相覆盖问题", "设置页「清空数据」移到「导出崩溃日志」下方（板块末位）", "本地备份与云端备份一样提供手动刷新按钮", "版本更新介绍补全 v1.12 / v1.13 两条记录"]),
        ("v1.13", "2026-10-23", ["设置页「查看备份文件」全新排版：快速备份 / 全量备份两大板块切换，每个板块内分本地备份、云端备份两组，原有功能全部保留", "备份成功弹提示；修复恢复数据卡死在 38% 的问题", "「打开备份文件夹」直达文件 App；旧版 JSON 备份收纳进折叠入口", "完成按钮移到右上角；云端备份支持实时刷新桶内文件并同步显示", "操作日志只保留一个月；自动备份保留天数数字放在 - + 号中间", "云端只保留最新 10 份自动备份（手动备份、手动上传的全量备份不清理）", "云端下载逐文件 CRC 校验；下载前先检查本地是否已有同名备份，有则直接复用", "分享房源上传到桶时显示百分比进度；房源板块删除到回收站，回收站删房源同步删除桶里的房源文件夹", "系统「用其他 App 打开」zip 可导入公寓管家识别；房号输入自动去空格", "根目录只保留一个「备份」文件夹（快速备份 / 全量备份 / cos 配置备份等子文件夹细分）"]),
        ("v1.9", "2026-10-23", ["设置页顶部空白彻底移除：滚动检测不再用占位行（v1.7/v1.8 残留行占位），改为 UIKit 监听滚动容器偏移，不占任何布局", "修复点「房源」板块闪退：房源软删除字段为可选属性，iOS 17 SwiftData 谓词翻译可选 Bool 会崩溃；改为全量拉取 + 内存过滤，兼容旧库且不再走有风险的谓词", "汇总页 KPI 胶囊改为动态宽度：标题/数值胶囊随文本长度自适应（¥70447 与 ¥20688 宽度不同，不再固定最小宽/被压缩）"]),
        ("v1.8", "2026-10-23", ["修复存储异常：房源模型软删除字段改为可选属性（v1.7 加非可选字段触发 iOS 17 SwiftData 自动迁移失败，打不开旧房源库导致整 App 进入临时模式）", "启动自动找回被隔离的主库文件（此前容器初始化失败时移入沙箱 backup 文件夹的经营数据会自动归位，无需手动恢复）", "设置页顶部空白行移除（滚动检测标记行不再占位）", "页面背景统一为 iOS 系统分组灰（与设置页一致，各功能板块不再偏绿）", "房源板块标题改为「房源管理」"]),
        ("v1.7", "2026-10-23", ["品牌全局统一：所有「房源管家 / 租房管家」残留文案替换为「公寓管家」（含备份提示、数据文件夹说明）", "房源板块底色统一为主 App 深绿主题（背景 / 主色 / 强调色对齐，不再暖白/深墨蓝/琥珀）", "设置页图标与字体配色改为 iOS 原生蓝（房源管家风格）", "设置页顶部横线动态化：页面在顶部不显示，向下滑动、顶栏固定后才显示分隔线", "登记房源房号实时查重：输入即检测，重复房号变红提示（与保存时校验同口径，兼容 1- / 2- 前缀）", "房源板块：移除左上角设置按钮（已合并至主设置）；右上角 + 按钮样式与其他板块统一", "房源卡片左滑菜单：编辑 / 分享 / 删除（删除二次确认后移入回收站，不再直接删照片视频文件）", "回收站：新增房源板块（软删除房源可还原/彻底删除，彻底删除才移除本地文件）；顶部增加板块分类标签筛选；清空支持清空单个板块或全部", "备份/恢复文案更新：「备份租房数据（不含房源）」「恢复租房数据（不含房源）」，补充房源数据备份/恢复说明", "新增「查看备份文件」：设置页数据管理与远程配置备份 COS 处均可用内部浏览组件查看备份文件，不再跳文件 App"]),
        ("v1.11", "2026-10-22", ["设置页两处「查看备份文件」（数据管理 + 远程配置 COS）支持左滑删除，删除前二次确认，删除后列表自动刷新", "「打开『文件』App 查看数据文件夹」点击直接打开房源图片/视频所在 Media 文件夹（不再只打开文件 App 根目录）", "房源卡片左滑：编辑 / 状态按钮改为双色区分（编辑保持 iOS 蓝，状态切换用绿色，不再连排同色）", "房源卡片左滑状态按钮按当前状态动态显示：待租房源左滑显示「已租」（点击改为已租），已租房源左滑显示「待租」（点击改回待租）"]),
        ("v1.10", "2026-10-22", ["房源卡片左滑菜单改为 iOS 原生 swipeActions：样式与其他板块（成交/收租/包租/待办）完全一致，滑动更流畅，不再用自定义拖拽组件", "左滑菜单「分享」替换为「已租」：左滑一键把房源切换为已租状态并保存，默认列表（待租）即时刷新，无需进详情页操作"]),
        ("v1.6", "2026-10-22", ["设置统一：房源板块独立设置页取消，全部合并进主 App「设置 → 房源分享」分组（远程配置/名片信息/分享压缩/刷新缓存/房源数据）", "房源板块左上角设置按钮：一键跳转主「设置」页，全 App 只保留一个设置入口", "UI 按房源管家设置页原生 iOS 风格统一（Form 分组 + 小字说明）", "配色恢复为原租房管家深绿主题"]),
        ("v1.4", "2026-10-22", ["回收站入口调整：移至设置页右上角（图标+文字按钮），不再占用数据管理列表", "工作台「新增房源」：不再跳转房源板块，改为直接弹出登记表单（与新增收租/新增成交一致），保存后房源列表自动刷新"]),
        ("v1.3", "2026-10-22", ["房源板块：户型筛选支持多选（可同时筛选多种户型）", "房源设置：刷新分享缓存增加二次确认，防止误触", "房源设置：移除底部版本号", "分享压缩开关默认开启（此前默认关闭，视频按原文件上传）", "工作台：回收站入口移至设置页，空位新增「新增房源」入口"]),
        ("v1.2", "2026-10-22", ["修复：房源板块闪退（根治）——租房管家与房源管家数据改为两个独立存储容器，房源页面使用专属数据上下文，规避 iOS 17 早期版本多存储配置崩溃问题", "房源数据仍独立存放 Documents/备份/（housekeeper.store），拷贝还原方式不变"]),
        ("v1.1", "2026-10-22", ["修复：与旧租房管家彻底隔离——App Group 改为全新独立组，桌面小组件/同步数据不再与旧应用互通", "优化：房源板块移至第二个 Tab（工作台之后），通知提醒跳转同步更新"]),
        ("v5.29", "2026-10-21", ["备份数据与恢复数据分开两行显示", "设置页每一行补上系统小图标（与备份/恢复/清空同风格）", "修复备份频率与自定义铃声标题重复显示的问题", "移除设置页底部版本号", "自动备份说明补充：按天自动备份超过7天自动清理，手动备份保留"]),
        ("v5.28", "2026-10-21", ["设置页面改为 iOS 原生清爽风格（Form 分组 + 小字说明），整体更简洁、字体图标回归系统默认大小", "应用名称更新为租房管家"]),
        ("v5.27", "2026-10-21", ["设置页面微信风格：浅灰背景、白色圆角分组卡片、镂空线条图标、行间浅灰分隔线", "备份/数据同步/自动备份/水电单价/自定义铃声各板块增加小字使用说明", "构建流程增加 Release 发布通道，IPA 可通过 GitHub Release 下载", "应用名称更新为租房管家"]),
        ("v5.26", "2026-10-21", ["设置页面改为微信风格：浅灰背景、白色圆角分组卡片、镂空线条图标、行间浅灰分隔线，上下间距、字体大小、色调、背景色按微信设置页统一", "备份/数据同步/自动备份/水电单价/自定义铃声各板块增加小字使用说明", "构建流程增加 Release 发布通道，IPA 可通过 GitHub Release 下载"]),
        ("v1.0", "2026-10-21", ["公寓管家正式版：租房管家（经营工具）与房源管家（获客分享）合体", "完整保留租房管家全部功能：工作台/成交/收租/包租/汇总/设置/回收站/待办/备忘录/账单模板/自动备份", "新增房源管家板块：房源库/实拍图视频/微信卡片分享/H5脱敏页/腾讯云COS远程配置", "房源数据独立存储（备份文件夹），可直接拷贝还原", "全新应用ID（com.gj.tg），与旧应用完全隔离，可并行安装"]),
        ("v5.25", "2026-10-14", ["包租水电结算退出自动保存，不再丢失", "新增待办默认置顶显示", "待办接入回收站，支持还原与永久删除", "水电计算历史支持长按复制"]),
        ("v5.24", "2026-10-14", ["成交金额/杂项收支/汇总净收入补齐纯数字输出，全App金额无千分位点号"]),
        ("v5.23", "2026-10-14", ["账单金额全部改为纯数字输出，彻底消除千分位点号（如 1,500 → 1500）"]),
        ("v5.22", "2026-10-14", ["待办排序稳定化，拖动不再卡死", "首页工作台待办手动排序生效，结果持久保存", "全部待办已办结默认按完成日期降序"]),
        ("v5.19", "2026-10-13", ["完全移除未收租提醒进度条，仅保留提醒列表", "收租管理导出Excel补充预存金额、本月应收、本月状态与收租明细", "分享账单图片金额去除千位点号，出账日期字体加大加粗", "设置新增账单模板设置：固定提示文本可修改、收款码可更换、支持预览", "修复备忘录拖动排序退出APP后复原，手动排序持久保存"]),
        ("v5.18", "2026-10-13", ["修复13号交租水电结算后账单不显示水电结算：账单按结算日期匹配，结算单为空但有金额时显示电费/水费明细", "修复只写水费无电费时累计水电不统计", "修复包租房卡片已付租金统计金额不对：只统计合法期数月记录", "修复工作台首页付租按钮无效：付款记录月统一，保存后立即刷新", "修复收租卡片关闭详情表单后跳到顶部，保留滚动位置", "修复1号交租28号未显示未收租提醒（按下一应收期判断）", "水电结算写入后收租计划金额实时更新", "未收租提醒进度条改为只统计提醒列表内房源数据"]),
        ("v5.17", "2026-09-22", ["成交板块三个标签（成交记录/杂项收入/杂项支出）与收租板块（在租/退租）增加本页数量统计，跟随筛选实时变化", "退租卡片左滑还原增加确认弹窗；退租房源详情页点编辑改为编辑退租信息", "包租详情页右上角改为编辑、左上角改为关闭", "收租计划已打勾后金额锁定不可修改；水电结算金额随时可编辑，取消结算需确认弹窗", "修复备份恢复后回收站记录全部复活的问题（备份补存删除状态）", "汇总统计增加过滤双保险，回收站记录不再计入任何统计"]),
        ("v5.16", "2026-09-22", ["工作台快捷操作新增回收站入口（第4个功能）", "回收站右滑还原增加二级确认弹窗，与永久删除一样先确认再执行", "成交、收租、杂项收入支出、包租删除的记录统一进入回收站，支持右滑还原/永久删除、多选批量还原/删除、一键清空"]),
        ("v5.15", "2026-09-22", ["修复从水电结算表单（详情页左上角、列表页、工作台入口）写入水电后返回界面不刷新的问题", "写入水电成功后自动刷新对应页面（月度收租金额、收租列表、工作台数据）"]),
        ("v5.14", "2026-09-22", ["修复收租详情页写入水电后月度收租金额不即时刷新的问题（水电保存后自动重建月度计划行）", "水电结算输入改为防抖保存（停止输入0.35秒后保存），输入与滑动更流畅", "水电结算计划列表排序去重改为缓存、日期标题格式化静态化，滑动更流畅", "月度收租打勾、改金额后立即保存，避免数据丢失"]),
        ("v5.13", "2026-09-22", ["修复收租计划金额负数结余计算错误：水电结算写入和账单更新时结余符号由加改为减，结余为负（预存用超）时正确相加", "快捷收租、快捷付租弹窗高度改为直接作用于弹窗根视图，确保360紧凑高度生效", "快捷收租默认金额直接读取收租计划当月金额（不再重复加预存）"]),
        ("v5.12", "2026-09-21", ["快捷收租、快捷付租弹窗高度调整到与日期轮盘一致的紧凑高度", "修复未收租提醒卡片不显示水电提示的问题：当月有未结算水电计划时，卡片金额下方显示「需结算水电」"]),
        ("v5.11", "2026-09-21", ["快捷收租、快捷付租弹窗改为自适应紧凑高度（不再半屏）", "未收租提醒金额直接读取收租计划的当月金额（与结算后的计划一致），不再单独计算", "收租计划金额的水电结余匹配统一改为按结算计划日期当月匹配，与提醒判断口径一致"]),
        ("v5.10", "2026-09-21", ["未收租提醒水电判断改为直接读取收租表单的当月结算计划（有记录且未结算才提示需结算，已结算或无记录不提示），不再推算", "快捷收租表单删除水电结算输入项，水电统一在收租详情表单的结算计划中维护"]),
        ("v5.9", "2026-09-21", ["新增/编辑成交表单：房号、房东、租期、管理人、客源改为左右布局", "新增/编辑收租表单：房号、房东、租期改为左右布局", "新增/编辑包租表单：房号、管理人、租期、免租期、水电底数改为左右布局", "包租详情水电结算日期改为轮盘选择（半屏弹出）", "收租详情收租计划日期显示完整年月日且不换行", "修复桌面小组件包租应付读不到数据的问题", "恢复备份时增加确认弹窗，防止误覆盖数据"]),
        ("v5.8", "2026-09-21", ["成交、收租、包租详情表单及快捷收租/付租表单右侧数据由灰色改为黑色加粗显示", "设置页整体优化：除清空数据外所有选项改为白色底色，全部文字改为黑色加粗"]),
        ("v5.7", "2026-09-21", ["户型选择新增复式独立厨房", "水电结算已结算改未结算增加确认提示，防止误触", "修复从收租详情进入水电结算时默认总预存与设置页不一致", "收租卡片已收未收状态改为按下一期交租日提前3天转为未收"]),
        ("v5.6.2", "2026-09-21", ["水电计划使用完整日期显示", "备份恢复和字段稳定修复"]),
        ("v5.6.1", "2026-09-21", ["修复通知角标调度问题"]),
        ("v5.6", "2026-09-21", ["新增手动租金和水电计划编辑", "账单排版优化和支付码并排显示", "桌面小组件数据同步和刷新修复"]),
        ("v5.5", "2026-09-19", ["账单顶部安全间距和副标题压缩", "上下账单统一字号并完整换行", "Widget与主App打包前注入App Group无证书签名"]),
        ("v5.4", "2026-09-19", ["账单字体与完整换行统一", "支付宝微信双收款码并排", "新增出账时间和人工录入提示"]),
        ("v5.3.1", "2026-09-19", ["水电计划随房源信息变化自动更新", "收租金额公式修正", "附加费分享状态修复", "账单排版与小组件同步优化"]),
        ("v5.3", "2026-09-19", ["按HTML样式重做账单图片", "水电结算文字完整显示", "月季结算日期及最后一期修正", "小组件刷新修复"]),
        ("v5.2", "2026-09-19", ["新增收租闪退修复", "水电未结算清空与空值隐藏", "金额支持全删", "取消分享预览"]),
        ("v5.1", "2026-09-19", ["水电计划左右UI及可编辑结算文本", "计划去重排序和新增收租修复", "工作台结余金额修复", "收租账单附加费用和紧凑排版", "所有图片分享增加预览"]),
        ("v5.0", "2026-09-19", ["水电计划去重和账单分享", "收款码账单图片", "桌面小组件打包"]),
        ("v4.9", "2026-09-19", ["全量备份稳定ID", "水电月季计划和详情写回修复", "写入成功关闭表单", "历史降序搜索", "成交联动收租修复", "工作台金额修复"]),
        ("v4.8", "2026-09-19", ["水电保存提示与微信跳转", "收租快捷水电结算与周期写入", "按月按季水电计划及结余联动", "支持单独水费或电费结算", "水电默认单价和预存设置", "在租退租动作调整及成交联动收租"]),
        ("v4.7", "2026-09-19", ["通知角标及打开APP清零", "四类通知独立铃声设置", "水电结算支持带/不带总表及整数结算", "新增结算单复制、保存、历史、编辑删除排序预览和图片分享", "结算历史纳入总备份恢复"]),
        ("v4.6", "2026-09-19", [
            "修复同一时间多个待办只收到一条通知的问题，通知重建改为串行且每条使用唯一ID",
            "收租、包租付租和租期到期通知改为每间房独立发送，并按绿点未逾期、红点已逾期显示",
            "业务通知按未来7天每天11点预排，控制在iOS通知数量上限内",
            "新增通知计划账本，启动或回前台时补发最近6小时应发但未确认的提醒",
            "补发单次最多10条，避免打开APP时集中弹出过多通知"
        ]),
        ("v4.5", "2026-09-19", [
            "设置提醒的未办事项卡片左侧新增黄色发光点",
            "待办事项改为最新添加的优先显示",
            "前台通知支持横幅、通知中心列表和提示音",
            "收租、包租付租和租期到期改为每天11点分组提醒，区分即将到期与已逾期",
            "待办到达提醒时间后每小时持续提醒，归档或删除后自动取消"
        ]),
        ("v4.4", "2026-09-19", [
            "所有公共日期轮盘改为固定高度底部弹窗，不再全屏显示",
            "新增本地通知授权及收租提前3天、包租付款提前3天、租期到期提前7天提醒",
            "待办表单新增可选年月日时分提醒时间",
            "点击业务通知可自动切换到工作台、收租或包租板块",
            "待办提醒时间纳入总备份和恢复逻辑"
        ]),
        ("v4.3", "2026-09-19", [
            "快捷操作和KPI看板统一使用下方板块同款标题栏组件",
            "统一六个工作台板块折叠状态的上下内边距和高度",
            "修复KPI看板标题略微靠右，与其他板块标题左侧对齐",
            "保持快捷操作网格和KPI展开内容布局不变"
        ]),
        ("v4.2", "2026-09-19", [
            "工作台待办改成与全部待办相同的原生List和onMove排序配置",
            "不再强制永久编辑模式，默认不显示右侧排序手柄",
            "取消工作台待办最多显示5条的限制，有多少未办事项就显示多少",
            "列表高度根据待办数量和长文本自动扩展，不再截断内容"
        ]),
        ("v4.1", "2026-09-19", [
            "隐藏工作台待办右侧排序图标，保留整行长按拖动排序",
            "自动备份增加运行期间每30秒检查，不再要求重启APP才能触发",
            "设置变更后立即清理旧时间槽并重新检查计划",
            "使用实际自动备份文件校验本期是否完成，避免错误跳过",
            "自动备份成功提醒改为全局根视图弹窗"
        ]),
        ("v4.0", "2026-09-19", [
            "退租信息保存后自动关闭退租表单和房源详情",
            "工作台待办改用与全部待办一致的原生拖动排序",
            "取消工作台折叠箭头，改为点击区域标题栏空白处折叠或展开",
            "重构自动补偿备份：启动和回前台检查计划时间槽，漏备立即补做并防止重复",
            "自动备份成功后在APP任意页面显示全局提醒"
        ]),
        ("v3.6", "2026-09-19", [
            "修正收租与退租切换位置，优化退租卡片内容和日期显示",
            "退租及待办表单统一使用成交表单同款日期选择器",
            "工作台待办支持拖动排序，全部待办调整搜索布局并放大已办状态字体",
            "工作台四个提醒区域统一折叠，收租进度合并到未收租提醒",
            "修复设置页备份恢复重复弹层、选择无效及自动备份启动补偿逻辑"
        ]),
        ("v3.5", "2026-09-19", [
            "优化收租与退租切换、退租胶囊卡片、退租时间折叠及还原在租流程",
            "完善待办搜索、排序、编辑预览、恢复未办理及删除二次确认",
            "工作台提醒区域支持折叠，收租进度合并到未收租提醒，并对调收支图标颜色",
            "总备份完整包含已办和未办待办，自动备份支持错过计划时间后启动补备份",
            "设置页移除Excel转备份，备份与恢复按钮改为同一行"
        ]),
        ("v3.4", "2026-09-18", [
            "收租新增在租与退租双页，支持退租登记、编辑、删除和分享",
            "退租详情顶部展示退租时间、原因、押金、房损、水电及联系人信息",
            "新增待办事项，支持新增时间、办理日期、拖动排序和未办/已办归档",
            "工作台新增待办区域与快捷入口，完成待办时增加二次确认",
            "快捷操作改为每行4个共2行，并支持快捷操作和 KPI 看板收起"
        ]),
        ("v3.3", "2026-09-18", [
            "iPhone 与 Windows 电脑版版本统一升级至3.3",
            "电脑版整体界面按手机版视觉规范重新设计",
            "统一顶部品牌栏、底部六栏导航、浅灰绿背景和白色圆角卡片",
            "统一按钮、输入框、状态标签及业务编辑表单样式",
            "保留数据导入、业务增删改查、局域网同步和备份迁移功能"
        ]),
        ("v3.2", "2026-09-18", [
            "iPhone 与 Windows 电脑版版本统一升级至3.2",
            "修复 iPhone 向电脑版同步时可能出现 HTTP 400 的问题",
            "补齐 Windows 窗口、任务栏及发布 EXE 的应用图标",
            "按手机端10类数据模型补齐电脑版业务模块和增删改查",
            "统一跨端实体类型并增加旧版桌面数据自动迁移，提升同步兼容性"
        ]),
        ("v3.0", "2026-09-17", [
            "品牌升级为租房管家，正式版本升级至3.0",
            "修复收租详情修改后卡片已收月数、累计水电和待收状态不能实时刷新的问题",
            "收租页和工作台下拉刷新改为真实保存并重新加载数据",
            "月度收租计划按完整租期生成，支持2年及更长租期",
            "修正工作台房源统计：管理仅统计管理类型，托管包租继续合计统计"
        ]),
    ]
    // v1.80：远程配置——版本记录合并云端更新日志（后台「远程配置」新增条目即出现在 App 设置 → 关于，无需发版）
    var displayVersions: [(version: String, date: String, changes: [String])] {
        // 云端条目与本地条目合并：同版本号去重（本地优先），再按日期倒序排列。
        // 修复此前云端旧条目直接拼在最前、重复版本号导致 ForEach 行渲染丢失、最新条目不显示的问题。
        var merged: [String: (version: String, date: String, changes: [String])] = [:]
        for item in cloudEntries {
            merged[item.version] = (version: item.version, date: item.date ?? "", changes: item.changes)
        }
        for item in versions where merged[item.version] == nil {
            merged[item.version] = item
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return merged.values.sorted { lhs, rhs in
            let dl = formatter.date(from: lhs.date) ?? .distantPast
            let dr = formatter.date(from: rhs.date) ?? .distantPast
            if dl != dr { return dl > dr }
            return lhs.version > rhs.version
        }
    }
    /// v2.31：拉云端更新记录——成功写进页面状态；失败给一行可点的重试提示，不再永远卡在「正在同步」
    private func loadCloud(force: Bool = false) async {
        if cloudLoading { return }
        if didLoadCloud && !force { return }
        didLoadCloud = true
        cloudFailed = false
        cloudLoading = true
        let ok = await RemoteConfig.refresh()
        cloudEntries = RemoteConfig.changelog ?? []
        cloudLoading = false
        cloudFailed = !ok
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(displayVersions, id: \.version) { ver in
                    Section(header: HStack {
                        Text(ver.version)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.themeAccent)
                        Spacer()
                        Text(ver.date)
                            .font(.system(size: 12))
                            .foregroundColor(.black)
                    }) {
                        ForEach(ver.changes, id: \.self) { change in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(.themeAccent)
                                    .padding(.top, 6)
                                Text(change)
                                    .font(.system(size: 14))
                                    .foregroundColor(.black)
                                    .fontWeight(.semibold)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle("版本更新介绍")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) {
                if cloudLoading {
                    Text("正在同步云端更新记录…")
                        .font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                } else if cloudFailed {
                    Button {
                        Task { await loadCloud(force: true) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text("云端更新记录没拉到，点这里重试")
                                .font(.footnote)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.themeAccent)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 8)
                }
            }
            .task { await loadCloud() }
        }
    }
}


// MARK: - 账单模板设置（固定文本 / 收款码 / 预览）
struct BillTemplateSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @AppStorage("billFixedTip") private var billFixedTip = "账单由人工录入，系统生成，如金额有误请与我联系！"
    @AppStorage("billGreeting") private var billGreeting = "尊敬的租客，感谢您选择我司提供的租赁服务！"
    @AppStorage("billDuePrefix") private var billDuePrefix = "您"
    @AppStorage("billDueSuffix") private var billDueSuffix = "前需支付房租账单明细如下："
    @AppStorage("billLateFeeTip") private var billLateFeeTip = "（请务必按时交租，逾期交租将按照租房合同约定计算滞纳金：月租金5%/天×天数）"
    @AppStorage("billSign") private var billSign = "谢谢  祝 商祺"
    @AppStorage("billQRAlipayFile") private var billQRAlipayFile = ""
    @AppStorage("billQRWechatFile") private var billQRWechatFile = ""

    @State private var alipayItem: PhotosPickerItem?
    @State private var wechatItem: PhotosPickerItem?
    @State private var showAlipayPicker = false
    @State private var showWechatPicker = false
    @State private var previewImage: UIImage?
    @State private var showPreview = false
    @State private var showMsg = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("固定文本（生成账单时实时生效）") {
                    TextField("顶部固定提示", text: $billFixedTip, axis: .vertical).lineLimit(1...3)
                    TextField("问候语", text: $billGreeting, axis: .vertical).lineLimit(1...3)
                    HStack(spacing: 6) {
                        TextField("引导语前段", text: $billDuePrefix)
                        Text("交租日期").font(.footnote).foregroundColor(.gray)
                        TextField("引导语后段", text: $billDueSuffix)
                    }
                    TextField("滞纳金提示", text: $billLateFeeTip, axis: .vertical).lineLimit(1...3)
                    TextField("落款", text: $billSign)
                }
                Section("收款码") {
                    qrRow("支付宝收款码", file: $billQRAlipayFile, showPicker: $showAlipayPicker)
                    qrRow("微信收款码", file: $billQRWechatFile, showPicker: $showWechatPicker)
                    Text("点击“更换”从相册选择新收款码，立即生效；点击“清除”恢复内置默认收款码。")
                        .font(.footnote)
                }
                Section("预览") {
                    Button("预览账单效果") { makePreview() }
                        .foregroundColor(.themeAccent)
                }
            }
            .navigationTitle("账单模板设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .photosPicker(isPresented: $showAlipayPicker, selection: $alipayItem, matching: .images)
            .photosPicker(isPresented: $showWechatPicker, selection: $wechatItem, matching: .images)
            .onChange(of: alipayItem) { _, newItem in
                saveQRAsync(item: newItem, prefix: "alipay_qr") { newName in
                    let old = billQRAlipayFile
                    billQRAlipayFile = newName
                    if let oldURL = qrURL(old), oldURL.lastPathComponent != newName { try? FileManager.default.removeItem(at: oldURL) }
                }
            }
            .onChange(of: wechatItem) { _, newItem in
                saveQRAsync(item: newItem, prefix: "wechat_qr") { newName in
                    let old = billQRWechatFile
                    billQRWechatFile = newName
                    if let oldURL = qrURL(old), oldURL.lastPathComponent != newName { try? FileManager.default.removeItem(at: oldURL) }
                }
            }
            .sheet(isPresented: $showPreview) {
                if let image = previewImage { ShareImagePreview(image: image, share: {}) }
            }
            .alert("提示", isPresented: $showAlert) { Button("确定", role: .cancel) {} } message: { Text(showMsg) }
        }
    }

    private func qrRow(_ title: String, file: Binding<String>, showPicker: Binding<Bool>) -> some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            if let img = loadQR(file.wrappedValue) { Image(uiImage: img).resizable().scaledToFit().frame(width: 42, height: 42).cornerRadius(6) }
            Button("更换") { showPicker.wrappedValue = true }
                .buttonStyle(.bordered).font(.footnote)
            if !file.wrappedValue.isEmpty {
                Button("清除") {
                    if let url = qrURL(file.wrappedValue) { try? FileManager.default.removeItem(at: url) }
                    file.wrappedValue = ""
                }.buttonStyle(.bordered).tint(.red).font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }

    private func qrURL(_ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private func loadQR(_ name: String) -> UIImage? {
        guard let url = qrURL(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // 异步加载相册图片并保存到 Documents，完成后在主线程回调文件名
    private func saveQRAsync(item: PhotosPickerItem?, prefix: String, assign: @escaping (String) -> Void) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                let name = "\(prefix)_\(Int(Date().timeIntervalSince1970)).png"
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                if let png = img.pngData() {
                    try? png.write(to: url)
                    await MainActor.run { assign(name) }
                }
            }
        }
    }

    private func makePreview() {
        let props = (try? modelContext.fetch(FetchDescriptor<Property>())) ?? []
        guard let property = props.first(where: { !$0.isTerminated && !$0.monthlyRentRecords.isEmpty }) else {
            showMsg = "暂无可预览的收租房源，请先在收租板块添加房源并生成收租计划。"
            showAlert = true
            return
        }
        let cal = Calendar.current
        let y = cal.component(.year, from: Date())
        let m = cal.component(.month, from: Date())
        let rent = property.monthlyRentRecords.first { $0.year == y && $0.month == m } ?? property.monthlyRentRecords.first!
        let utility = property.utilitySettlementRecords.first { rec in
            guard let d = rec.dueDate else { return false }
            return cal.component(.year, from: d) == rent.year && cal.component(.month, from: d) == rent.month
        }
        let view = RentBillShareView(property: property, rent: rent, utility: utility, extras: [])
        let renderer = ImageRenderer(content: view.frame(width: 360))
        renderer.scale = 3
        if let image = renderer.uiImage {
            previewImage = image
            showPreview = true
        } else {
            showMsg = "账单预览生成失败，请重试。"
            showAlert = true
        }
    }
}

// MARK: - v1.36 管理后台口令（网页版登录用；App 内免登录直接带哈希）

struct AdminPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = CloudConfig.adminPassword
    @State private var confirm = ""
    @State private var savedFlash = false
    @State private var resultMsg: String?
    @State private var errorMsg: String?

    var body: some View {
        Form {
            Section {
                SecureField("后台口令", text: $password)
                SecureField("再次输入确认", text: $confirm)
            } header: {
                Text("口令设置")
            } footer: {
                Text("网页版管理后台用此口令登录；App 内打开后台免登录。默认口令 12345678，建议修改为不易猜的字符。v1.17 需求6：保存后会自动同步到云函数（云端后台、网页后台同用此口令）。")
            }
            Section {
                Button("保存") { save() }
            }
            if let errorMsg {
                Section {
                    Text(errorMsg).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("管理后台口令")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已保存", isPresented: Binding(
            get: { savedFlash },
            set: { if !$0 { savedFlash = false } }
        )) {
            Button("好", role: .cancel) { dismiss() }
        } message: {
            Text(resultMsg ?? "后台口令已更新：\(password)")
        }
    }

    private func save() {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else {
            errorMsg = "口令至少 6 位"
            return
        }
        guard trimmed == confirm else {
            errorMsg = "两次输入不一致"
            return
        }
        // v1.17 需求6：记录旧口令哈希用于云函数鉴权，再更新本地
        let oldHash = CloudConfig.passwordHash
        CloudConfig.adminPassword = trimmed
        resultMsg = "本地口令已更新：\(trimmed)"
        savedFlash = true
        // 异步同步到云函数（改桶内 h/_admin_pwd.json）
        Task {
            let tip = await syncCloud(oldHash: oldHash, new: trimmed)
            await MainActor.run { resultMsg = tip }
        }
    }

    /// v1.17 需求6：调用云函数 setPwd 把新口令同步到云端（成功后云端后台与网页后台立即用新口令）
    private func syncCloud(oldHash: String, new: String) async -> String {
        guard let encoded = new.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(CloudConfig.functionURL)?act=setPwd&k=\(oldHash)&new=\(encoded)") else {
            return "已保存到本地，但同步云函数失败（云函数地址无效）。\n网页版后台仍用旧口令，请稍后在设置页重试。"
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                return "已保存到本地；但云端同步被拒绝（口令校验失败）。\n请确认云函数已部署后重试。"
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["ok"] as? Bool == true {
                return "本地 + 云端后台口令均已更新：\(new)"
            }
            return "已保存到本地；云端同步未确认，请稍后重试。"
        } catch {
            return "已保存到本地；云端同步失败（网络错误：\(error.localizedDescription)）"
        }
    }
}


// MARK: - v2.18：全量备份进度枢纽
/// 全量备份打包耗时可达几十秒（含照片视频），进度只在这里写、View 只读。
/// 写入口径：BackupV5Manager.createFullBackup 的 progress 回调本身已切回主线程。
final class FullBackupProgressHub: ObservableObject {
    nonisolated(unsafe) static let shared = FullBackupProgressHub()
    @Published var value: Double?
}

// MARK: - v2.23 设置页改「一级菜单 + 二级页面」
// 首页只留 6 个分组入口 + 关于（应用相关）组；每组内容单独一页。
// 说明：原 SettingsView 内的 7 组 Section 代码保留（不再在首页渲染），下面 6 页是独立实现，各有自己的状态与弹窗。

// MARK: 组 1 账号与云端
struct AccountSettingsPage: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("我的用户名")
                            Text("操作日志 / 分享 / 统计都带这个名字；在「云端配置」里可下拉选云端已有的用户名")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.fill")
                    }
                    Spacer()
                    Text(CloudUser.username.isEmpty ? "未设置" : CloudUser.username)
                        .font(.footnote)
                        .foregroundColor(CloudUser.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .red : .secondary)
                }
                NavigationLink {
                    CosConfigView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("云端配置")
                            Text("COS 存储桶 / 密钥 / 自定义域名 / 云函数地址")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                }
                NavigationLink {
                    AdminPasswordView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("管理后台口令")
                            Text("网页版登录用 · App 内自动免登录")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                }
            } header: {
                Text("账号与云端")
            } footer: {
                Text("云端配置决定房源图片/视频传到哪个桶、分享卡片用哪个域名；配好后可导出部署包给别的房东自建后台。")
            }
        }
        .navigationTitle("账号与云端")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: 组 2 分享与展示
struct ShareSettingsPage: View {
    @Environment(\.houseModelContext) private var houseModelContext
    @State private var showMessage = ""
    @State private var showAlert = false
    @State private var showHouseCacheConfirm = false
    @State private var houseCacheTip: String?
    @State private var roomsLinkExpiry = 2
    @State private var compressOnShare = true
    @State private var watermarkSubtitle = ""

    private func refreshWatermarkSubtitle() {
        let wm = WatermarkSettingsStore.current
        watermarkSubtitle = wm.enabled ? "已开启 · \(wm.text)" : "已关闭"
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ShareProfileView()
                } label: {
                    Label("名片信息", systemImage: "person.crop.circle")
                }
                NavigationLink {
                    RoomsShareView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("公开选房链接")
                            Text("实时读云端账本，租客自己挑房；有效期在下一行设")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "globe.asia.australia")
                    }
                }
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("选房链接有效期")
                            Text("只管「公开选房链接」；到期后旧链接失效，要重新生成")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock.badge.xmark")
                    }
                    Spacer()
                    Picker("", selection: $roomsLinkExpiry) {
                        Text("1 天").tag(1)
                        Text("2 天").tag(2)
                        Text("3 天").tag(3)
                        Text("7 天").tag(7)
                        Text("15 天").tag(15)
                        Text("30 天").tag(30)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: roomsLinkExpiry) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "roomsLinkExpiryDays")
                        showMessage = "已设为 \(newValue) 天：下次「重新生成链接」按新有效期生效"
                        showAlert = true
                    }
                }
                NavigationLink {
                    WatermarkSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("分享水印")
                            Text(watermarkSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "camera.aperture")
                    }
                }
                .onAppear { refreshWatermarkSubtitle() }
                Toggle(isOn: Binding(
                    get: { compressOnShare },
                    set: { newValue in
                        compressOnShare = newValue
                        UserDefaults.standard.set(newValue, forKey: "compressOnShare")
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("压缩上传媒体（房源+分享）")
                        Text("图片长边压到 1600（JPEG 0.8）；视频长边压到 960、约 1 Mbps。只影响之后新上传的文件，已上传的不变。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    showHouseCacheConfirm = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("重建全部分享链接")
                            Text("清掉云端旧分享页后逐间重建；已经发出去的旧链接会立即失效")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                }
            } header: {
                Text("分享与展示")
            } footer: {
                Text(RemoteConfig.help("shareSectionFooter2", "这一组只决定「分享出去的东西长什么样、有效期多久、要不要水印和压缩」。桶、密钥、域名在「账号与云端」里。"))
            }
        }
        .navigationTitle("分享与展示")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            compressOnShare = shareCompressionEnabled
            let d = UserDefaults.standard.integer(forKey: "roomsLinkExpiryDays")
            roomsLinkExpiry = d > 0 ? d : Int(RemoteConfig.param("roomsLinkExpiryDays", 2))
            refreshWatermarkSubtitle()
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(showMessage)
        }
        .confirmationDialog("重建全部房源分享链接", isPresented: $showHouseCacheConfirm, titleVisibility: .visible) {
            Button("清空并重建全部", role: .destructive) {
                ShareCacheStore.clearAll()
                rebuildAllShareH5()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将重建全部房源的分享链接：云端旧分享页全部删除（旧链接立即失效），并为每间房重新生成最新 H5。确定继续吗？")
        }
        .alert("重建全部分享链接", isPresented: Binding(
            get: { houseCacheTip != nil },
            set: { if !$0 { houseCacheTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(houseCacheTip ?? "")
        }
    }

    private func rebuildAllShareH5() {
        guard let ctx = houseModelContext,
              let config = CosConfig.load(), config.isValid else {
            houseCacheTip = "请先到「云端配置」填写 COS 配置并验证通过"
            return
        }
        let houses = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        let active = houses.filter { !($0.isDeleted ?? false) }
        let profile = CosUploader.loadShareProfile()
        let items = active.map { h -> (files: [ShareMediaFile], roomKey: String, info: ShareHouseInfo) in
            (
                h.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) },
                h.mediaRoomKey,
                ShareHouseInfo(
                    displayRoomNo: h.displayRoomNo,
                    towerLabel: h.towerLabel,
                    layout: h.layout,
                    statusLabel: h.status.label,
                    priceText: h.priceText,
                    landlord: h.landlord,
                    password: h.password,
                    remark: h.remark,
                    name: profile.name,
                    phone: profile.phone
                )
            )
        }
        houseCacheTip = "正在重建 \(active.count) 套房源的分享链接…"
        Task {
            var ok = 0, fail = 0
            for it in items {
                do {
                    _ = try await CosUploader.autoRegenerateMaskedShare(mediaFiles: it.files, roomKey: it.roomKey, info: it.info, config: config)
                    ok += 1
                } catch {
                    fail += 1
                }
            }
            await MainActor.run {
                houseCacheTip = "分享链接已全部重建：\(ok) 间成功" + (fail > 0 ? "，\(fail) 间失败（可再次刷新重试）" : "") + "\n旧分享链接已全部失效"
            }
        }
    }
}

// MARK: 组 4 账单与默认值
struct DefaultsSettingsPage: View {
    @AppStorage("defaultElectricPrice") private var defaultElectricPrice = "0.8"
    @AppStorage("defaultWaterPrice") private var defaultWaterPrice = "5.5"
    @AppStorage("defaultUtilityPrepayment") private var defaultUtilityPrepayment = "0"
    @State private var showBillTemplate = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("电费单价", systemImage: "bolt")
                    Spacer()
                    TextField("0.8", text: $defaultElectricPrice)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                HStack {
                    Label("水费单价", systemImage: "drop")
                    Spacer()
                    TextField("5.5", text: $defaultWaterPrice)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                HStack {
                    Label("默认总预存", systemImage: "wallet.pass")
                    Spacer()
                    TextField("0", text: $defaultUtilityPrepayment)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                Button { showBillTemplate = true } label: {
                    HStack {
                        Label("账单模板设置", systemImage: "textformat.alt")
                        Spacer()
                        Text("文本/收款码/预览")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("账单与默认值")
            } footer: {
                Text("这三个默认值是「水电结算」页的默认单价与预存，打开结算页自动填入；不影响已生成的结算记录，也不影响房源租金。")
            }
        }
        .navigationTitle("账单与默认值")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBillTemplate) {
            BillTemplateSettingsView()
        }
    }
}

// MARK: 组 5 外部服务
struct ServicesSettingsPage: View {
    @EnvironmentObject private var meterStore: MeterStore

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    MeterSettingsDetailView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("电表监控")
                            Text(meterStore.settings.openId.isEmpty ? "未配置链接" : (meterStore.settings.provider == .webView ? "网页抓取" : "直连接口"))
                                .font(.caption2)
                                .foregroundStyle(meterStore.settings.openId.isEmpty ? Color.red : Color.secondary)
                        }
                    } icon: {
                        Image(systemName: "bolt.batteryblock.fill")
                    }
                }
                NavigationLink {
                    AjkSettingsDetailView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("安居客后台")
                            Text("推广房源抓取 · 实地核验 / 下架预警")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "building.2.fill")
                    }
                }
                NavigationLink {
                    AIAssistantSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 助手")
                            Text(KeychainHelper.exists(key: "ai.volcengine.apiKey") ? "已配置 API Key" : "未配置 Key")
                                .font(.caption2)
                                .foregroundStyle(KeychainHelper.exists(key: "ai.volcengine.apiKey") ? Color.secondary : Color.red)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
            } header: {
                Text("外部服务")
            } footer: {
                Text("电表监控只读取展示电量（充值仍走官方页面）；安居客后台只读抓取推广房源、不做发布；AI 助手走你自己的火山方舟 Key——Key 只存本机钥匙串，不上传、不随备份上传。")
            }
        }
        .navigationTitle("外部服务")
        .navigationBarTitleDisplayMode(.inline)
    }
}
// MARK: 组 3 备份与安全
struct BackupSettingsPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.houseModelContext) private var houseModelContext
    @State private var showMessage = ""
    @State private var showAlert = false
    @State private var showBackupKindSheet = false
    @State private var showOfflineRestoreConfirm = false
    @State private var showBackupCenterBrowse = false
    @State private var showMigration = false
    @State private var showBackupCenterRestore = false
    @State private var showLogsView = false
    @State private var showCrashLogsView = false
    @State private var showClearSheet = false
    @State private var clearType: DataBackupManager.BackupType? = nil
    @State private var showClearConfirm = false
    @AppStorage("autoBackupRetentionDays") private var backupRetentionDays = 7
    @State private var autoBackupEnabled = false
    @State private var backupFrequency = "day"
    @State private var backupHour = 23
    @ObservedObject private var backupProgress = FullBackupProgressHub.shared
    private let backupManager = DataBackupManager.shared

    private var crashLogBytes: Int {
        CrashLogCollector.totalBytes()
    }

    var body: some View {
        Form {
            Section {
                Button { showBackupKindSheet = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("备份数据")
                            Text("快速 = 账本 + 媒体清单（自动传云端）；全量 = 额外含全部房源与照片视频")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                Button { showBackupCenterRestore = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("恢复数据")
                            Text("从本机或云端备份还原，会覆盖当前数据；恢复前自动留一份安全备份")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用自动备份")
                            Text("到点自动存一份快速备份并传云端；错过会等下次打开 App 补做")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { autoBackupEnabled },
                        set: { newValue in
                            autoBackupEnabled = newValue
                            saveAutoSettings()
                        }
                    ))
                    .labelsHidden()
                }
                if autoBackupEnabled {
                    HStack {
                        Label("备份频率", systemImage: "calendar")
                        Spacer()
                        Picker("", selection: $backupFrequency) {
                            Text("每天").tag("day")
                            Text("每周").tag("week")
                            Text("每月").tag("month")
                        }
                        .tint(.secondary)
                        .labelsHidden()
                        .onChange(of: backupFrequency) { _, _ in saveAutoSettings() }
                    }
                    HStack {
                        Label("备份时间", systemImage: "timer")
                        Spacer()
                        Button { if backupHour > 0 { backupHour -= 1 } } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        Text(String(format: "%02d:00", backupHour))
                            .font(.system(size: 16, weight: .semibold))
                            .frame(minWidth: 58)
                            .multilineTextAlignment(.center)
                        Button { if backupHour < 23 { backupHour += 1 } } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onChange(of: backupHour) { _, _ in saveAutoSettings() }
                    HStack {
                        Label("保留天数", systemImage: "archivebox")
                        Spacer()
                        Button { if backupRetentionDays > 1 { backupRetentionDays -= 1 } } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        Text("\(backupRetentionDays) 天")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(minWidth: 58)
                            .multilineTextAlignment(.center)
                        Button { if backupRetentionDays < 60 { backupRetentionDays += 1 } } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onChange(of: backupRetentionDays) { _, _ in saveAutoSettings() }
                }
                Button { showBackupCenterBrowse = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("备份文件管理")
                            Text("查看本机 / 云端备份，可上传、下载、删除；要恢复到手机请点上面「恢复数据」。旧版 JSON 备份也在这里")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                Button { showMigration = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("换机迁移")
                            Text("导出 .zfgj 迁移包拷到新手机，一次性复制；不是日常同步")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "iphone.and.arrow.forward")
                    }
                }
                NavigationLink {
                    MediaPendingView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("待补传媒体")
                            Text("上传失败的图片视频排在这里，逐个重试")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                Button { showOfflineRestoreConfirm = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("离线重建房源")
                            Text("扫描本机账本重建房源记录，无需联网；不删除任何现有数据")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.clockwise.icloud")
                    }
                }
                Button { showLogsView = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("操作日志")
                            Text("备份 / 恢复 / 上传 / 删除 / 同步的流水，本机区 + 云端区")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
                Button { showCrashLogsView = true } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("崩溃日志")
                                Text("App 异常退出时自动记录，可查看、导出、清理")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "ladybug")
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(crashLogBytes), countStyle: .file))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Button { showClearSheet = true } label: {
                    HStack {
                        Label("清空数据", systemImage: "trash")
                            .foregroundColor(.red)
                        Spacer()
                        Text("按板块清空")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("备份与安全")
            } footer: {
                Text(RemoteConfig.help("backupIntro2", "快速备份只含账本 + 媒体清单（不含房源记录与照片视频文件，自动传云端）；全量备份才含全部房源与照片视频（体积大，需在备份文件管理里手动传云端）。恢复会覆盖当前数据，恢复前自动打包当前数据做安全备份，失败自动还原。自动备份固定走快速备份。"))
            }
        }
        .navigationTitle("备份与安全")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadAutoSettings()
            backupProgress.value = nil
        }
        .sheet(isPresented: $showBackupCenterBrowse) {
            BackupFileBrowseViewV5(mode: .browse)
        }
        .sheet(isPresented: $showBackupCenterRestore) {
            BackupFileBrowseViewV5(mode: .restore)
        }
        .sheet(isPresented: $showLogsView) {
            BackupLogsView()
        }
        .sheet(isPresented: $showMigration) {
            MigrationView()
        }
        .sheet(isPresented: $showCrashLogsView) {
            CrashLogsView()
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(showMessage)
        }
        .confirmationDialog("选择备份方式", isPresented: $showBackupKindSheet, titleVisibility: .visible) {
            Button("快速备份（推荐）") { performNewBackup(kind: .fast) }
            Button("全量备份（含照片视频）") { performNewBackup(kind: .full) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("快速备份：账本 + 媒体清单（不含房源与照片视频文件），备份后自动上传云端；房源从云端同步恢复。\n全量备份：账本 + 房源 + 全部照片视频，备份后可在「备份文件管理」中手动上传云端。")
        }
        .alert("离线重建房源", isPresented: $showOfflineRestoreConfirm) {
            Button("取消", role: .cancel) { }
            Button("开始重建") { runOfflineRestore() }
        } message: {
            Text("将扫描本机 media 文件夹中的所有账本（每套 info.json）并重建房源记录。无需联网；已有房源按账本刷新，缺失房源自动补齐，不删除任何现有数据。")
        }
        .confirmationDialog("选择要清空的板块", isPresented: $showClearSheet, titleVisibility: .visible) {
            Button("清空成交数据") { clearType = .deals; showClearConfirm = true }
            Button("清空收租数据") { clearType = .properties; showClearConfirm = true }
            Button("清空包租数据") { clearType = .payouts; showClearConfirm = true }
            Button("清空全部数据", role: .destructive) { clearType = .total; showClearConfirm = true }
            Button("取消", role: .cancel) { }
        }
        .alert("确认清空", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { clearType = nil }
            Button("确定清空", role: .destructive) {
                if let type = clearType {
                    clearData(type: type)
                }
                clearType = nil
            }
        } message: {
            if let type = clearType {
                Text(type == .total ? "确定要清空所有数据吗？此操作不可恢复，建议先备份数据。" : "确定要清空\(type == .deals ? "成交数据" : type == .properties ? "收租数据" : "包租数据")吗？此操作不可恢复。")
            } else {
                Text("")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .backupCenterMessage)) { note in
            if let text = note.userInfo?["message"] as? String {
                showMessage = text
                showAlert = true
            }
        }
    }

    private func saveAutoSettings() {
        let previous = UserDefaults.standard.data(forKey: "autoBackupSettings").flatMap { try? JSONDecoder().decode(AutoBackupSettings.self, from: $0) }
        let settings = AutoBackupSettings(enabled: autoBackupEnabled, frequency: backupFrequency, hour: backupHour, minute: 0, lastBackupDate: previous?.lastBackupDate)
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "autoBackupSettings")
            UserDefaults.standard.removeObject(forKey: "autoBackupCompletedSlot")
            UserDefaults.standard.synchronize()
            NotificationCenter.default.post(name: .autoBackupSettingsChanged, object: nil)
        }
    }

    private func loadAutoSettings() {
        if let data = UserDefaults.standard.data(forKey: "autoBackupSettings"),
           let settings = try? JSONDecoder().decode(AutoBackupSettings.self, from: data) {
            autoBackupEnabled = settings.enabled
            backupFrequency = settings.frequency
            backupHour = settings.hour
        }
    }

    private func performNewBackup(kind: BackupKindV5) {
        guard let houseCtx = houseModelContext else {
            showMessage = "房源数据容器不可用，请重启 App 后重试"
            showAlert = true
            return
        }
        if kind == .fast {
            if let url = BackupV5Manager.createFastBackup(mainContext: modelContext, houseContext: houseCtx) {
                BackupLogStore.log(category: "备份", action: "快速备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                Task {
                    await CloudBackupService.autoUploadFastBackup(zipURL: url, config: nil)
                }
                showMessage = RemoteConfig.tip("quickBackupOk", "快速备份成功：{file}\n已自动上传云端（若网络失败会在下次打开 App 时自动重试）").replacingOccurrences(of: "{file}", with: url.lastPathComponent)
            } else {
                showMessage = "快速备份失败，请检查存储空间"
            }
            showAlert = true
        } else {
            if !BackupV5Manager.hasFreeSpace(needed: BackupV5Manager.collectMediaFileEntries().reduce(0) { $0 + (BackupV5Manager.fileSize(at: $1.fileURL)) }) {
                showMessage = RemoteConfig.tip("fullBackupSpace", "存储空间不足，全量备份至少需要与照片视频等量的剩余空间")
                showAlert = true
                return
            }
            backupProgress.value = 0
            Task {
                let url = await BackupV5Manager.createFullBackup(mainContext: modelContext, houseContext: houseCtx) { p in
                    FullBackupProgressHub.shared.value = p
                }
                await MainActor.run {
                    backupProgress.value = nil
                    if let url = url {
                        BackupLogStore.log(category: "备份", action: "全量备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                        showMessage = RemoteConfig.tip("fullBackupOk2", "全量备份成功：{file}\n可在「备份文件管理」中手动上传到云端").replacingOccurrences(of: "{file}", with: url.lastPathComponent)
                    } else {
                        showMessage = "全量备份失败，请检查存储空间"
                    }
                    showAlert = true
                }
            }
        }
    }

    private func runOfflineRestore() {
        guard let houseCtx = houseModelContext else {
            showMessage = "房源数据容器不可用，请重启 App 后重试"
            showAlert = true
            return
        }
        let n = LocalHouseLedger.restoreAll(houseContext: houseCtx)
        if n > 0 {
            showMessage = "离线重建完成：已从本地账本恢复 \(n) 套房源"
            showAlert = true
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        } else {
            showMessage = "未找到本地账本（media 文件夹中没有 info.json）。请先联网同步一次生成账本，或使用「恢复数据」。"
            showAlert = true
        }
    }

    private func clearData(type: DataBackupManager.BackupType) {
        let success: Bool
        switch type {
        case .deals: success = backupManager.clearDeals(modelContext: modelContext)
        case .properties: success = backupManager.clearProperties(modelContext: modelContext)
        case .payouts: success = backupManager.clearPayouts(modelContext: modelContext)
        case .total: success = backupManager.clearAll(modelContext: modelContext)
        }
        showMessage = success ? (type == .total ? "全部数据已清空" : "\(type.rawValue)已清空") : "清空失败，原数据已保留，请重试"
        showAlert = true
    }
}

// MARK: 组 6 存储与清理
struct StorageSettingsPage: View {
    @State private var showMessage = ""
    @State private var showAlert = false
    @State private var showAICacheConfirm = false
    @State private var showIpaClearConfirm = false
    @State private var orphanCleaning = false
    @State private var orphanCleanResult: String?
    @State private var orphanList: [HouseListView.OrphanMedia] = []
    @State private var showOrphanListConfirm = false
    @State private var scanFraction = 0.0
    @State private var scanStageText = ""
    @State private var orphanControl: HouseListView.OrphanScanControl?
    @State private var orphanTaskID: UUID?
    @State private var orphanScanBackgrounded = false

    /// v2.23：已下载的安装包占用文案（个数 · 大小）
    private func downloadedPackagesText() -> String {
        let n = UpdateDownloader.downloadedPackages().count
        let size = ByteCountFormatter.string(fromByteCount: Int64(UpdateDownloader.downloadsSizeBytes()), countStyle: .file)
        return n == 0 ? "无" : "\(n) 个 · \(size)"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("数据文件夹大小")
                            Text("房源照片视频与备份都在这；整个文件夹拷走就是一份完整备份")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "externaldrive")
                    }
                    Spacer()
                    Text(houseDocumentsSizeText())
                        .foregroundColor(.secondary)
                }
                Button {
                    showAICacheConfirm = true
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI 产物（可清理）")
                                Text("AI 生成的账单图片、导出表格等；清空不影响对话记录与 App 数据")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkles.rectangle.stack")
                        }
                        Spacer()
                        Text(aiCacheSizeText())
                            .foregroundColor(.secondary)
                    }
                }
                // v2.23：清理 App 内下载的更新安装包
                Button {
                    showIpaClearConfirm = true
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("清理下载的安装包")
                                Text("App 内下载的更新包（文件 App → 公寓管家 → Updates）；新包下载校验通过后会自动只留最新一个")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "shippingbox")
                        }
                        Spacer()
                        Text(downloadedPackagesText())
                            .foregroundColor(.secondary)
                    }
                }
                Button {
                    openHouseDataFolder()
                } label: {
                    Label("打开「文件」App 查看数据文件夹", systemImage: "folder")
                }
            } header: {
                Text("存储与清理")
            } footer: {
                Text("数据存放在「公寓管家」文件夹内的 backups / media 两个子文件夹；换机或重装时整个文件夹拷回原位即可还原。")
            }

            Section {
                Button {
                    startOrphanScan()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(orphanCleaning ? "正在扫描云端…" : "清理桶孤儿媒体")
                            Text("先列出孤儿名单+详细路径，确认后再删除；操作日志会记录")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "trash.circle")
                    }
                }
                .disabled(orphanCleaning)
            } header: {
                Text("云端清理")
            } footer: {
                Text("只删不在任何房源账本名单里的桶内媒体对象，不影响正在使用的照片视频。")
            }
        }
        .navigationTitle("存储与清理")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if orphanCleaning && !orphanScanBackgrounded {
                OrphanScanProgressOverlay(
                    fraction: scanFraction, stage: scanStageText,
                    onBackground: { orphanScanBackgrounded = true },
                    onCancel: { Task { await orphanControl?.cancel() } })
            }
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(showMessage)
        }
        .alert("清空 AI 产物？", isPresented: $showAICacheConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                AIToolExecutor.clearAIArtifacts()
                showMessage = "AI 产物已清空"
                showAlert = true
            }
        } message: {
            Text("将删除「AI产物」文件夹里的全部账单图片与导出表格（AI 对话历史与 App 数据不受影响）。确定清空吗？")
        }
        .alert("清空下载的安装包？", isPresented: $showIpaClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                let n = UpdateDownloader.clearDownloads()
                showMessage = n > 0 ? "已删除 \(n) 个安装包" : "没有需要清理的安装包"
                showAlert = true
            }
        } message: {
            Text("将删除 Updates 文件夹里已下载的全部 .ipa（不影响已安装的 App，也不影响下次更新下载）。")
        }
        .alert("发现 \(orphanList.count) 个孤儿媒体", isPresented: $showOrphanListConfirm) {
            Button("取消", role: .cancel) { orphanList = [] }
            Button("确认删除", role: .destructive) {
                orphanCleaning = true
                Task {
                await MediaActivityGate.shared.beginCleanup()
                defer { Task { await MediaActivityGate.shared.endCleanup() } }
                    do {
                        guard let config = CosConfig.load() else {
                            orphanCleanResult = "请先在「云端配置」填写 COS 配置"
                            return
                        }
                        let list = orphanList
                        let deleted = await HouseListView.deleteOrphanMedia(list, config: config)
                        let paths = list.prefix(20).map { $0.path }.joined(separator: "\n")
                        let more = list.count > 20 ? "\n…等共 \(list.count) 个" : ""
                        BackupLogStore.log(category: "同步", action: "桶孤儿清理（手动）", result: deleted == list.count ? "成功" : "部分成功",
                                           detail: "删除 \(deleted)/\(list.count) 个：\n\(paths)\(more)", cloud: true)
                        orphanCleanResult = "已删除 \(deleted)/\(list.count) 个孤儿媒体（详见操作日志）"
                    } catch {
                        orphanCleanResult = "清理失败：\(error.localizedDescription)"
                    }
                    orphanList = []
                    orphanCleaning = false
                }
            }
        } message: {
            let preview = orphanList.prefix(15).map { $0.path }.joined(separator: "\n")
            let more = orphanList.count > 15 ? "\n…等共 \(orphanList.count) 个" : ""
            Text("以下文件不在任何房源账本名单里，将被删除：\n\(preview)\(more)")
        }
        .alert("桶孤儿清理", isPresented: Binding(
            get: { orphanCleanResult != nil },
            set: { if !$0 { orphanCleanResult = nil } }
        )) {
            Button("好", role: .cancel) { orphanCleanResult = nil }
        } message: {
            Text(orphanCleanResult ?? "")
        }
    }

    private func openHouseDataFolder() {
        let mediaURL = MediaStore.mediaDirectory()
        UIApplication.shared.open(mediaURL) { success in
            if !success, let root = URL(string: "shareddocuments://") {
                UIApplication.shared.open(root)
            }
        }
    }

    /// 开扫：建令牌与中心任务，注册重试入口
    @MainActor
    private func startOrphanScan() {
        orphanCleaning = true
        orphanScanBackgrounded = false
        scanFraction = 0
        let control = HouseListView.OrphanScanControl()
        orphanControl = control
        orphanTaskID = SyncTaskCenter.shared.begin(
            kind: .orphan, title: "清理桶孤儿媒体", total: 1)
        TaskRetryPerformer.shared.orphanScan = {
            await startOrphanScanAndRun()
        }
        Task {
            await MediaActivityGate.shared.beginCleanup()
            defer { Task { await MediaActivityGate.shared.endCleanup() } }
            await runOrphanScan(control: control)
        }
    }

    /// 重试入口：重新建一套再跑
    @MainActor
    private func startOrphanScanAndRun() async {
        orphanCleaning = true
        orphanScanBackgrounded = false
        scanFraction = 0
        let control = HouseListView.OrphanScanControl()
        orphanControl = control
        orphanTaskID = SyncTaskCenter.shared.begin(
            kind: .orphan, title: "清理桶孤儿媒体", total: 1)
        await MediaActivityGate.shared.beginCleanup()
        defer { Task { await MediaActivityGate.shared.endCleanup() } }
        await runOrphanScan(control: control)
    }

    /// 孤儿扫描主流程（手动触发与任务中心重试共用）；取消即停止扫描，一个文件都不删
    @MainActor
    private func runOrphanScan(control: HouseListView.OrphanScanControl) async {
        guard let id = orphanTaskID else { return }
        do {
            guard let config = CosConfig.load() else {
                orphanCleanResult = "请先在「云端配置」填写 COS 配置"
                SyncTaskCenter.shared.finish(id: id, success: false,
                                            failure: "没读到 COS 配置，先到「云端配置」填好再重试")
                orphanCleaning = false
                return
            }
            let list = try await HouseListView.scanOrphanMedia(config: config, control: control) { done, total, room in
                Task { @MainActor in
                    scanFraction = Double(done) / Double(max(1, total))
                    scanStageText = room.isEmpty ? "正在列桶…" : "正在核对 \(room)（\(done)/\(total)）"
                    SyncTaskCenter.shared.advance(id: id, done: done, total: max(1, total),
                                                  note: "正在核对 \(room)")
                }
            }
            if await control.isCancelled {
                SyncTaskCenter.shared.cancel(id: id, note: "已取消本次扫描，未删除任何文件")
                orphanCleanResult = "已取消本次扫描，未删除任何文件"
            } else if list.isEmpty {
                orphanCleanResult = "扫描完成：没有发现孤儿媒体"
                SyncTaskCenter.shared.finish(id: id, success: true, note: "没有发现孤儿媒体")
            } else {
                orphanList = list
                SyncTaskCenter.shared.finish(id: id, success: true,
                                            note: "发现 \(list.count) 个孤儿，确认名单后再删")
                showOrphanListConfirm = true
            }
        } catch {
            orphanCleanResult = "扫描失败：\(error.localizedDescription)"
            SyncTaskCenter.shared.finish(id: id, success: false,
                                        failure: "扫描失败：\(error.localizedDescription)，点重试")
        }
        orphanCleaning = false
    }
}


// v2.47：桶孤儿媒体扫描进度弹窗
struct OrphanScanProgressOverlay: View {
    let fraction: Double
    let stage: String
    var onBackground: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: max(0, min(1, fraction)))
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text(stage.isEmpty ? "正在扫描云端…" : stage)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(Int(max(0, min(1, fraction)) * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                HStack(spacing: 12) {
                    Button {
                        onBackground()
                    } label: {
                        Text("后台运行")
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    Button {
                        onCancel()
                    } label: {
                        Text("取消本次")
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - v2.51 电梯码快捷入口（gongyuguanjia://elevator）

/// 全局电梯码展示状态：URL Scheme / 设置页预览 都走这里
final class ElevatorCodeCenter: ObservableObject {
    static let shared = ElevatorCodeCenter()
    @Published var isPresenting = false
    private init() {}
    func open() { isPresenting = true }
    func close() { isPresenting = false }
}

/// 电梯码本地存取：默认用内置资源；自选图存 Documents/电梯码/elevator-code.png（不上云、不进备份）
enum ElevatorCodeStore {
    static let assetName = "ElevatorCode"

    static var customFileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("电梯码", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("elevator-code.png")
    }

    static var hasCustom: Bool {
        FileManager.default.fileExists(atPath: customFileURL.path)
    }

    static var displayImage: UIImage {
        if let data = try? Data(contentsOf: customFileURL), let img = UIImage(data: data) {
            return img
        }
        if let img = UIImage(named: assetName) { return img }
        return placeholder
    }

    /// 理论上不会走到这里（内置图缺失时的兜底，避免空白页）
    static var placeholder: UIImage {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "未设置电梯码" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .medium),
                .foregroundColor: UIColor.black
            ]
            let rect = CGRect(x: 0, y: 282, width: size.width, height: 44)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            var centered = attrs
            centered[.paragraphStyle] = para
            text.draw(in: rect, withAttributes: centered)
        }
    }

    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        guard let data = image.pngData() else { return false }
        do {
            try data.write(to: customFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: customFileURL)
    }
}

/// 全屏电梯码：亮度拉满，关闭时恢复原亮度
struct ElevatorCodeFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var previousBrightness: CGFloat?

    private var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 14) {
                    HStack {
                        Text("电梯码")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭电梯码")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                    Spacer(minLength: 0)

                    Image(uiImage: ElevatorCodeStore.displayImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: max(geo.size.width - 28, 120),
                               maxHeight: max(geo.size.height - 150, 120))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 14)

                    Spacer(minLength: 0)

                    Text("亮度已调到最亮 · 扫完点右上角关闭")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.bottom, 10)
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            let screen = currentScreen
            previousBrightness = screen?.brightness
            screen?.brightness = 1.0
        }
        .onDisappear {
            if let old = previousBrightness, let screen = currentScreen {
                screen.brightness = old
            }
            ElevatorCodeCenter.shared.isPresenting = false
        }
    }
}

/// 设置页·电梯码：预览、更换、恢复默认，以及一键打开方式说明
struct ElevatorCodeSettingsPage: View {
    @ObservedObject private var center = ElevatorCodeCenter.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var reloadTick = 0
    @State private var alertText: String?

    private let deepLink = "gongyuguanjia://elevator"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(uiImage: ElevatorCodeStore.displayImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 92, height: 92)
                        .padding(6)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.themeBorder, lineWidth: 0.5)
                        )
                        .id(reloadTick)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(ElevatorCodeStore.hasCustom ? "正在使用：自选二维码" : "正在使用：内置默认二维码")
                            .font(.subheadline)
                        Text("建议用清晰、方正的二维码图片；换完立即生效")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)

                Button {
                    center.open()
                } label: {
                    Label("全屏预览", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("从相册更换二维码", systemImage: "photo.on.rectangle")
                }
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task { @MainActor in
                        defer { pickerItem = nil }
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else {
                            alertText = "读取这张图片失败，换一张试试"
                            return
                        }
                        if ElevatorCodeStore.save(image) {
                            reloadTick += 1
                            alertText = "电梯码已更换，立即生效"
                        } else {
                            alertText = "保存失败，请重试"
                        }
                    }
                }

                if ElevatorCodeStore.hasCustom {
                    Button(role: .destructive) {
                        ElevatorCodeStore.reset()
                        reloadTick += 1
                        alertText = "已恢复内置默认二维码"
                    } label: {
                        Label("恢复默认二维码", systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("电梯码")
            } footer: {
                Text("自选图只存本机（文件 App / 公寓管家 / 电梯码），不上传云端、不进备份；换机或重装后回到内置默认码。")
            }

            Section {
                HStack {
                    Text(deepLink)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = deepLink
                        alertText = "已复制链接"
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 操作按钮（左侧那颗）")
                        .font(.footnote.weight(.semibold))
                    Text("设置 → 操作按钮 → 选「快捷指令」→ 新建一条：添加动作「打开 URL」→ 填入上面的链接。按一下即全屏出码。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("2. 控制中心")
                        .font(.footnote.weight(.semibold))
                    Text("设置 → 控制中心 → 添加「快捷指令」→ 选同一条指令；从右上角下滑点一下即可。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("3. 背面轻点 / 锁屏")
                        .font(.footnote.weight(.semibold))
                    Text("设置 → 辅助功能 → 触控 → 背面轻点 → 双击 → 选同一条快捷指令。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("4. 桌面小组件")
                        .font(.footnote.weight(.semibold))
                    Text("桌面「租房管家」中号组件已直接指向这个链接，点组件即全屏出码，不再回首页。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("一键打开方式")
            } footer: {
                Text("相机控制按钮（右侧）只对相机类 App 开放拍摄扩展，普通 App 无法占用；用它旁边的操作按钮可以达到同样「按一下出码」的效果。")
            }
        }
        .navigationTitle("电梯码")
        .navigationBarTitleDisplayMode(.inline)
        .alert("电梯码", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(alertText ?? "")
        }
    }
}
