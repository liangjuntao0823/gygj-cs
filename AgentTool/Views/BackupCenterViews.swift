import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - v1.12 备份中心（设置页）
// 统一查看/恢复入口：
//   · 备份文件查看器：快速/全量 zip（云端状态、上传、删除）+ 云端备份列表 + 旧版 JSON 分组
//   · 恢复选择器：本地 zip / 云端备份（下载后恢复）/ 旧版 JSON（按文件名自动识别板块）
// 恢复流程：二级确认 → 校验 → 安全快照 → 导入 → 分行统计弹窗；失败自动回滚。

/// 备份文件查看器（mode: browse=查看管理；restore=选一个恢复）
struct BackupFileBrowseViewV5: View {
    var mode: BrowseMode = .browse
    enum BrowseMode { case browse, restore }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.houseModelContext) private var houseModelContext
    @Environment(\.dismiss) private var dismiss

    // 列表
    @State private var fastBackups: [URL] = []
    @State private var fullBackups: [URL] = []
    @State private var cloudRecords: [CloudBackupService.CloudRecord] = []
    @State private var reloadTick = 0
    /// v1.13：查看备份页顶部「快速备份 / 全量备份」板块切换（0=快速，1=全量）
    @State private var selectedSection = 0

    // 上传进度
    @State private var uploadingName: String?
    @State private var uploadProgress: Double = 0
    @State private var uploadStage = ""

    // 删除/恢复确认
    @State private var deleteTarget: DeleteTarget?
    @State private var showDeleteConfirm = false
    @State private var restoreTarget: RestoreTarget?
    @State private var showRestoreConfirm = false

    // 恢复进度与统计
    @State private var isRestoring = false
    @State private var restoreProgress: Double = 0
    @State private var restoreStage = ""
    @State private var restoreStats: RestoreStatsV5?
    @State private var restoreError: String?
    /// v1.14 需求3：云端恢复时记录「本地已有副本直接用本地」或「本地无副本已从云端下载」，完成弹窗与日志展示
    @State private var restoreSourceNote: String?

    // v1.13 需求7：云端刷新
    @State private var isRefreshingCloud = false

    struct DeleteTarget { let name: String; let isCloud: Bool }
    struct RestoreTarget {
        let localURL: URL?
        let cloudName: String?
        var displayName: String
    }

    var body: some View {
        NavigationStack {
            backupList
        }
    }

    /// v1.12：List 内容拆独立属性（防 type-check 超时）
    /// v1.13：改为「快速备份 / 全量备份」两大板块切换，每个板块内分「本地备份」「云端备份」两组
    private var backupSections: some View {
        Group {
                // 顶部板块切换
                Section {
                    Picker("备份板块", selection: $selectedSection) {
                        Text("快速备份").tag(0)
                        Text("全量备份").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 2)

                    // v1.13：一键打开「备份」文件夹（文件 App 定位到备份目录）
                    Button {
                        openBackupFolder()
                    } label: {
                        Label("打开备份文件夹", systemImage: "folder")
                    }
                } header: {
                    Text("查看备份")
                } footer: {
                    Text(selectedSection == 0
                         ? "快速备份：账本 + 媒体清单（不含房源与照片视频文件），备份后自动上传云端；房源从云端同步恢复。"
                         : "全量备份：账本 + 房源 + 全部照片视频，备份后可在下方手动上传云端。")
                }

                if selectedSection == 0 {
                    // —— 快速备份板块 ——
                    if mode == .browse {
                        Section {
                            Button {
                                // 快速备份（含账本+房源+清单，自动上传云端）
                                performBackup(kind: .fast)
                            } label: {
                                Label("新建快速备份", systemImage: "bolt.circle")
                            }
                        } footer: {
                            Text("快速备份：账本 + 媒体清单（不含房源与照片视频文件），备份后自动上传云端；房源从云端同步恢复。")
                        }
                    }

                    Section {
                        if fastBackups.isEmpty {
                            Text("暂无本地快速备份")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(fastBackups, id: \.path) { url in
                                backupRow(url: url, kind: .fast)
                            }
                        }
                    } header: {
                        // v1.14 需求8：本地备份与云端备份一样提供刷新按钮
                        HStack {
                            Text("本地备份")
                            Spacer()
                            Button {
                                reload()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Section {
                        if isRefreshingCloud {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在刷新云端…")
                                    .foregroundColor(.secondary)
                            }
                        } else if fastCloudRecords.isEmpty {
                            Text("暂无云端快速备份")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(fastCloudRecords, id: \.name) { record in
                                cloudRow(record)
                            }
                        }
                    } header: {
                        HStack {
                            Text("云端备份")
                            Spacer()
                            Button {
                                refreshCloud()
                            } label: {
                                if isRefreshingCloud {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(isRefreshingCloud)
                            .buttonStyle(.borderless)
                        }
                    } footer: {
                        Text("云端备份保留最近 10 份自动备份（快速_ 前缀），全量手动上传的备份不会自动清理。")
                    }
                } else {
                    // —— 全量备份板块 ——
                    if mode == .browse {
                        Section {
                            Button {
                                // 全量备份（含照片视频），完成后手动上传
                                performBackup(kind: .full)
                            } label: {
                                Label("新建全量备份", systemImage: "externaldrive.fill")
                            }
                        } footer: {
                            Text("全量备份：账本 + 房源 + 全部照片视频，备份后可在下方手动上传云端。")
                        }
                    }

                    Section {
                        if fullBackups.isEmpty {
                            Text("暂无本地全量备份")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(fullBackups, id: \.path) { url in
                                backupRow(url: url, kind: .full)
                            }
                        }
                    } header: {
                        // v1.14 需求8：本地备份与云端备份一样提供刷新按钮
                        HStack {
                            Text("本地备份")
                            Spacer()
                            Button {
                                reload()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Section {
                        if isRefreshingCloud {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在刷新云端…")
                                    .foregroundColor(.secondary)
                            }
                        } else if fullCloudRecords.isEmpty {
                            Text("暂无云端全量备份")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(fullCloudRecords, id: \.name) { record in
                                cloudRow(record)
                            }
                        }
                    } header: {
                        HStack {
                            Text("云端备份")
                            Spacer()
                            Button {
                                refreshCloud()
                            } label: {
                                if isRefreshingCloud {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(isRefreshingCloud)
                            .buttonStyle(.borderless)
                        }
                    } footer: {
                        Text("云端备份保留最近 10 份自动备份（快速_ 前缀），全量手动上传的备份不会自动清理。")
                    }
                }

                if mode == .restore && fastBackups.isEmpty && fullBackups.isEmpty && cloudRecords.isEmpty {
                    Section {
                        Text("暂无备份文件。请先到「设置 → 备份数据」做一次备份。")
                            .foregroundColor(.secondary)
                    }
                }
        }
    }

    /// v1.13：按板块过滤的云端记录
    private var fastCloudRecords: [CloudBackupService.CloudRecord] {
        cloudRecords.filter { $0.name.hasPrefix("快速_") }
    }
    private var fullCloudRecords: [CloudBackupService.CloudRecord] {
        cloudRecords.filter { $0.name.hasPrefix("全量_") }
    }

    /// v1.12：List 拆独立属性（防 type-check 超时）
    private var backupList: some View {
        List {
            backupSections
        }
            .navigationTitle(mode == .browse ? "备份文件" : "恢复备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v1.13：完成按钮从左上角移到右上角
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay {
                if isRestoring {
                    RestoreProgressOverlay(progress: restoreProgress, stage: restoreStage)
                }
            }
            .overlay {
                if uploadingName != nil {
                    UploadProgressOverlay(name: uploadingName ?? "", progress: uploadProgress, stage: uploadStage)
                }
            }
            .confirmationDialog("删除这个备份？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { performDelete() }
                Button("取消", role: .cancel) {}
            } message: {
                if let t = deleteTarget {
                    Text(t.isCloud ? "将删除云端备份「\(t.name)」（不影响本地文件）。" : "将删除本地备份「\(t.name)」（不影响云端）。")
                } else {
                    Text("")
                }
            }
            .confirmationDialog("用这个备份恢复？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) { startRestore() }
                Button("取消", role: .cancel) {}
            } message: {
                if let t = restoreTarget {
                    Text("将用「\(t.displayName)」覆盖当前全部数据。恢复前会自动打包当前数据做安全备份，失败自动还原；成功后再清理。确定继续吗？")
                } else {
                    Text("")
                }
            }
            // v1.15 需求3：恢复完成改 overlay 卡片弹窗（iOS 17 alert 的 message 区对多行 VStack 渲染不可靠，
            // 只显示第一行「成交96条」；改用 overlay 卡片可完整显示 11 行口径 + 来源 + 安全备份清理提示）
            .overlay {
                if let stats = restoreStats, restoreError == nil {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 14) {
                            Text("恢复完成")
                                .font(.headline)
                                .foregroundColor(.white)
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(stats.summaryLines, id: \.self) { line in
                                    Text(line)
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                }
                                Text("全部核对无误")
                                    .font(.subheadline)
                                    .foregroundColor(.green)
                                if let note = restoreSourceNote {
                                    Text(note)
                                        .font(.footnote)
                                        .foregroundColor(.white.opacity(0.85))
                                }
                                // v1.15 需求3：恢复成功后安全快照已在 restore 成功路径自动删除，明确告知
                                Text("恢复前的安全备份已自动清理")
                                    .font(.footnote)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            Button("好") {
                                restoreStats = nil
                                restoreSourceNote = nil
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 8)
                            .background(Color.white)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                        }
                        .padding(20)
                        .frame(maxWidth: 320)
                        .background(Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert("恢复失败", isPresented: Binding(
                get: { restoreError != nil },
                set: { if !$0 { restoreError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(restoreError ?? "")
            }
            .onAppear { reload() }
            .onChange(of: reloadTick) { _, _ in reload() }
    }

    // MARK: - 行

    private func backupRow(url: URL, kind: BackupKindV5) -> some View {
        let rawName = url.lastPathComponent
        // v1.14 需求1：旧版「下载_」前缀文件剥掉前缀显示（文件名不变），新下载的文件直接用原名
        let name = rawName.hasPrefix("下载_") ? String(rawName.dropFirst(3)) : rawName
        let size = BackupV5Manager.fileSize(at: url)
        let cloudState = CloudBackupService.uploadState(of: name)
        let dateText = fileDateText(url)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(sizeText(size)) · \(dateText)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(cloudState)
                .font(.footnote)
                .foregroundColor(cloudState == "已上传云端" ? .green : .orange)
            if mode == .browse {
                Menu {
                    // v1.14 需求4：快速备份与全量备份都支持手动上传云端（快速只传 zip 本体，全量再传媒体增量）
                    Button("上传到云端") { uploadBackup(url: url, kind: kind) }
                    Button("删除", role: .destructive) {
                        deleteTarget = DeleteTarget(name: rawName, isCloud: false)
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .restore {
                restoreTarget = RestoreTarget(localURL: url, cloudName: nil, displayName: name)
                showRestoreConfirm = true
            }
        }
    }

    private func cloudRow(_ record: CloudBackupService.CloudRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(sizeText(record.size)) · \(record.date.formatted(date: .abbreviated, time: .shortened))\(record.isAuto ? " · 自动备份" : " · 手动上传")")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("云端")
                .font(.footnote)
                .foregroundColor(.green)
            if mode == .browse {
                Menu {
                    Button("下载到本机") { downloadCloud(record) }
                    Button("删除云端", role: .destructive) {
                        deleteTarget = DeleteTarget(name: record.name, isCloud: true)
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .restore {
                restoreTarget = RestoreTarget(localURL: nil, cloudName: record.name, displayName: record.name)
                showRestoreConfirm = true
            }
        }
    }

    // MARK: - 刷新

    /// v1.13：一键打开「备份」文件夹（文件 App 定位到备份目录；个别系统版本不支持定位子目录时兜底打开文件 App）
    private func openBackupFolder() {
        let backupRoot = DataRoot.url()
        UIApplication.shared.open(backupRoot) { success in
            if !success, let root = URL(string: "shareddocuments://") {
                UIApplication.shared.open(root)
            }
        }
    }

    private func reload() {
        let all = BackupV5Manager.listLocalBackups()
        // v1.14 需求1：旧版「下载_」前缀文件兼容显示——「下载_快速_」归快速组、「下载_全量_」归全量组，
        // 显示时剥掉「下载_」前缀（见 backupRow）；v1.14 起新下载的文件直接用原名，不再产生「下载_」前缀。
        fastBackups = all.filter { name in
            let n = name.lastPathComponent
            return n.hasPrefix("快速_") || n.hasPrefix("下载_快速_")
        }
        // v1.13 需求17：外部导入的 zip（无 快速_/全量_ 前缀）归入全量备份组，确保导入后可查看/恢复
        fullBackups = all.filter { url in
            let name = url.lastPathComponent
            if name.hasPrefix("快速_") || name.hasPrefix("下载_快速_") { return false }
            return true
        }
        cloudRecords = CloudBackupService.cloudRecords()
    }

    /// 实时刷新服务器备份清单并同步显示
    private func refreshCloud() {
        isRefreshingCloud = true
        Task {
            do {
                try await CloudBackupService.refreshCloudRecords()
                await MainActor.run {
                    isRefreshingCloud = false
                    reloadTick += 1
                    showMessageInContext("云端备份已刷新，与服务器文件同步一致")
                }
            } catch {
                await MainActor.run {
                    isRefreshingCloud = false
                    showMessageInContext("云端刷新失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 操作

    private func performBackup(kind: BackupKindV5) {
        guard let houseCtx = houseModelContext else { return }
        if kind == .fast {
            if let url = BackupV5Manager.createFastBackup(mainContext: modelContext, houseContext: houseCtx) {
                BackupLogStore.log(category: "备份", action: "快速备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                // 自动上传云端（后台；失败自动入队重试）
                Task {
                    await CloudBackupService.autoUploadFastBackup(zipURL: url)
                    await MainActor.run { reloadTick += 1 }
                }
                showMessageInContext(RemoteConfig.tip("quickBackupOk", "快速备份成功：{file}\n已自动上传云端（若网络失败会在下次打开 App 时自动重试）").replacingOccurrences(of: "{file}", with: url.lastPathComponent))
            } else {
                showMessageInContext("快速备份失败，请检查存储空间")
            }
        } else {
            // 全量备份：进度 overlay
            uploadingName = "全量备份生成中…"
            uploadProgress = 0
            uploadStage = "正在打包账本与照片视频…"
            Task {
                let url = await BackupV5Manager.createFullBackup(mainContext: modelContext, houseContext: houseCtx) { p in
                    Task { @MainActor in
                        self.uploadProgress = p
                    }
                }
                await MainActor.run {
                    uploadingName = nil
                    if let url = url {
                        BackupLogStore.log(category: "备份", action: "全量备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                        showMessageInContext(RemoteConfig.tip("fullBackupOk", "全量备份成功：{file}\n可在备份列表中手动上传到云端").replacingOccurrences(of: "{file}", with: url.lastPathComponent))
                        reloadTick += 1
                    } else {
                        showMessageInContext("全量备份失败，请检查存储空间")
                    }
                }
            }
        }
    }

    /// 手动上传备份到服务器。快速/全量均整体上传 zip（媒体已含在全量 zip 内）。
    private func uploadBackup(url: URL, kind: BackupKindV5) {
        uploadingName = url.lastPathComponent
        uploadProgress = 0
        uploadStage = "正在上传备份文件…"
        let isFast = (kind == .fast)
        Task {
            do {
                try await CloudBackupService.uploadZip(url: url) { p in
                    Task { @MainActor in self.uploadProgress = p }
                }
                await MainActor.run {
                    CloudBackupService.recordUpload(name: url.lastPathComponent, size: BackupV5Manager.fileSize(at: url), date: Date(), isAuto: false)
                    uploadingName = nil
                    BackupLogStore.log(category: "上传", action: isFast ? "快速备份上传" : "全量备份上传", result: "成功", detail: url.lastPathComponent, cloud: true)
                    showMessageInContext("已上传云端：\(url.lastPathComponent)")
                    reloadTick += 1
                }
            } catch {
                await MainActor.run {
                    uploadingName = nil
                    BackupLogStore.log(category: "上传", action: isFast ? "快速备份上传" : "全量备份上传", result: "失败", detail: error.localizedDescription, cloud: true)
                    showMessageInContext("上传失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func downloadCloud(_ record: CloudBackupService.CloudRecord) {
        // 本地已有该备份 → 提示无需下载，不重复下载
        if let existing = CloudBackupService.localCopyIfExists(name: record.name) {
            showMessageInContext("本地已存在该备份：\(existing.lastPathComponent)\n无需重复下载，可直接在本地备份中恢复。")
            return
        }
        uploadingName = record.name
        uploadProgress = 0
        uploadStage = "正在从服务器下载…"
        Task {
            do {
                let local = try await CloudBackupService.downloadBackup(name: record.name)
                await MainActor.run {
                    uploadingName = nil
                    showMessageInContext("已下载到本机：\(local.lastPathComponent)")
                    reloadTick += 1
                }
            } catch {
                await MainActor.run {
                    uploadingName = nil
                    showMessageInContext("下载失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        if target.isCloud {
            Task {
                do {
                    try await CloudBackupService.deleteRemoteBackup(name: target.name)
                    await MainActor.run {
                        BackupLogStore.log(category: "删除", action: "云端删除", result: "成功", detail: target.name, cloud: true)
                        reloadTick += 1
                    }
                } catch {
                    BackupLogStore.log(category: "删除", action: "云端删除", result: "失败", detail: "\(target.name)：\(error.localizedDescription)", cloud: true)
                    await MainActor.run { showMessageInContext("云端删除失败：\(error.localizedDescription)") }
                }
            }
        } else {
            // 本地删除：快速/全量 zip
            let localDir = BackupV5Manager.backupsDirectory
            try? FileManager.default.removeItem(at: localDir.appendingPathComponent(target.name))
            CloudBackupService.removePendingUpload(name: target.name)
            BackupLogStore.log(category: "删除", action: "本地删除", result: "成功", detail: target.name)
            reloadTick += 1
        }
        deleteTarget = nil
    }

    private func startRestore() {
        guard let target = restoreTarget else { return }
        guard let houseCtx = houseModelContext else {
            restoreError = "房源数据容器不可用"
            return
        }
        isRestoring = true
        restoreProgress = 0
        restoreStage = "正在校验备份…"
        restoreSourceNote = nil
        Task {
            do {
                if let cloudName = target.cloudName {
                    // 云端：先查本地是否已有该备份（有 → 直接按本地恢复，无 → 自动下载到本地后恢复）
                    let localHit = CloudBackupService.localCopyIfExists(name: cloudName)
                    restoreStage = (localHit != nil)
                        ? "本地已有该备份，直接用本地文件恢复…"
                        : "本地无此备份，正在从服务器下载…"
                    let local = try await CloudBackupService.downloadBackup(name: cloudName)
                    let stats = try await BackupV5Manager.restore(
                        zipURL: local, mainContext: modelContext, houseContext: houseCtx,
                        phaseProgress: { p in Task { @MainActor in self.restoreProgress = p } },
                        stageMessage: { s in Task { @MainActor in self.restoreStage = s } }
                    )
                    await MainActor.run {
                        isRestoring = false
                        restoreStats = stats
                        restoreSourceNote = (localHit != nil)
                            ? "本次恢复使用本地已有副本，未重复下载云端"
                            : "本地无该备份，已自动从云端下载到本地后恢复"
                        BackupLogStore.log(category: "恢复", action: "云端恢复", result: "成功", detail: "\(stats.summaryLines.joined(separator: " / "))；来源：\((localHit != nil) ? "本地已有副本" : "云端下载")", cloud: true)
                        // v1.63：恢复（含媒体）完成后通知房源列表/详情刷新
                        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    }
                } else if let url = target.localURL {
                    let stats = try await BackupV5Manager.restore(
                        zipURL: url, mainContext: modelContext, houseContext: houseCtx,
                        phaseProgress: { p in Task { @MainActor in self.restoreProgress = p } },
                        stageMessage: { s in Task { @MainActor in self.restoreStage = s } }
                    )
                    await MainActor.run {
                        isRestoring = false
                        restoreStats = stats
                        restoreSourceNote = "本次恢复使用本地备份文件"
                        BackupLogStore.log(category: "恢复", action: "本地恢复", result: "成功", detail: stats.summaryLines.joined(separator: " / "))
                        // v1.63：恢复（含媒体）完成后通知房源列表/详情刷新
                        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    }
                } else {
                    throw BackupV5Error.invalidBackup("未选择备份")
                }
            } catch {
                await MainActor.run {
                    isRestoring = false
                    restoreError = error.localizedDescription
                    BackupLogStore.log(category: "恢复", action: "恢复", result: "失败", detail: error.localizedDescription)
                }
            }
        }
        restoreTarget = nil
    }

    // MARK: - 提示（用环境变量传递的 alert 通道）

    @State private var message = ""
    private func showMessageInContext(_ text: String) {
        // 通过通知传给 SettingsView 的 alert 通道
        NotificationCenter.default.post(name: .backupCenterMessage, object: nil, userInfo: ["message": text])
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func fileDateText(_ url: URL) -> String {
        if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return ""
    }
}

// MARK: - 恢复进度 overlay

struct RestoreProgressOverlay: View {
    let progress: Double
    let stage: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text(stage)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct UploadProgressOverlay: View {
    let name: String
    let progress: Double
    let stage: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text(stage)
                    .font(.footnote)
                    .foregroundColor(.white)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - 操作日志视图

struct BackupLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs = BackupLogStore.all()
    @State private var cloudLogs: [CloudOpEntry] = []
    @State private var exportTip: String?
    @State private var searchText = ""
    @State private var section = 0          // 0=本机操作 1=云端操作
    @State private var isEditing = false
    @State private var selectedLocal: Set<Int> = []
    @State private var selectedCloud: Set<Int> = []
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("分区", selection: $section) {
                    Text("全部").tag(2)
                    Text("本机操作").tag(0)
                    Text("云端操作").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                if section == 0 {
                    localList
                } else if section == 1 {
                    cloudList
                } else {
                    mergedList
                }
            }
            .navigationTitle("操作日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if section != 2 {
                        if isEditing {
                            Button("取消") { exitEdit() }
                        } else if section == 1 {
                            // v1.63：云端操作记录不支持一键清空，只能单选/多选删除 → 进入多选模式
                            Button("多选") { isEditing = true }
                        } else {
                            Button("清空") { showClearConfirm = true }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button(deleteCountLabel) { deleteSelected() }
                            .disabled(deleteCount == 0)
                    } else {
                        Button("导出") { exportLogs() }
                            .disabled(section == 2 || (section == 0 ? logs.isEmpty : cloudLogs.isEmpty))
                    }
                }
            }
            .alert("操作日志", isPresented: Binding(get: { exportTip != nil }, set: { if !$0 { exportTip = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(exportTip ?? "") }
            .confirmationDialog("确定清空\(section == 0 ? "本机" : "云端")操作日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { performClear() }
                Button("取消", role: .cancel) {}
            }
            .onAppear {
                Task {
                    await CloudOps.flushPending()
                    if section == 1 || section == 2 { loadCloud() }
                }
            }
            .onChange(of: section) { _, s in if s == 1 || s == 2 { loadCloud() } }
        }
    }

    // MARK: 本机操作区（本地 UserDefaults，含历史云端操作记录）
    // v2.47：卡片与云端完全同构（左边条+动作+房号+明细+操作者）
    private var localList: some View {
        List(selection: $selectedLocal) {
            if displayLocal.isEmpty {
                Text(logs.isEmpty ? "暂无本机操作日志" : "没有匹配的日志").foregroundColor(.secondary)
            } else {
                ForEach(Array(displayLocal.enumerated()), id: \.offset) { idx, item in
                    LogDisplayRow(item: item)
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                BackupLogStore.remove(filteredLocal[idx]); reloadLocal()
                            }
                        }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索日志（分类/动作/详情/操作者）")
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    }

    // MARK: 云端操作区（桶 h/_ops.json，带用户名；同桶多用户的桶操作会同步显示）
    private var cloudList: some View {
        List(selection: $selectedCloud) {
            if displayCloud.isEmpty {
                Text(cloudLogs.isEmpty ? (CloudOps.isConfigured ? "暂无云端操作记录" : "未连接到服务器，无法读取云端操作") : "没有匹配的记录")
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(displayCloud.enumerated()), id: \.offset) { idx, item in
                    LogDisplayRow(item: item)
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                CloudOps.delete(filteredCloud[idx]) { loadCloud() }
                            }
                        }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索云端操作（类型/详情/操作者/房号）")
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .refreshable { loadCloud() }
    }

    // MARK: 全部（合并视图）：本机 + 云端统一成同一卡片，按时间倒序合并去重，排查不用两边翻
    private var mergedList: some View {
        List {
            if filteredMerged.isEmpty {
                Text("暂无操作记录").foregroundColor(.secondary)
            } else {
                ForEach(Array(filteredMerged.enumerated()), id: \.offset) { _, item in
                    LogDisplayRow(item: item)
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索全部日志（动作/详情/操作者/房号）")
    }

    /// 本机条目转统一卡片模型
    private var displayLocal: [LogDisplayItem] {
        filteredLocal.enumerated().map { idx, e in LogDisplayItem(local: e, index: idx) }
    }

    /// 云端条目转统一卡片模型
    private var displayCloud: [LogDisplayItem] {
        filteredCloud.enumerated().map { idx, c in LogDisplayItem(cloud: c, index: idx) }
    }

    /// 全部：本机 + 云端同模型合并，同分钟/同动作/同操作者跨来源去重，按时间倒序
    private var mergedItems: [LogDisplayItem] {
        let all = displayLocal + displayCloud
        var seen = Set<String>()
        var unique: [LogDisplayItem] = []
        for item in all.sorted(by: { $0.date > $1.date }) {
            let key = "\(Int(item.date.timeIntervalSince1970 / 60))|\(item.title)|\(item.user)"
            if seen.insert(key).inserted { unique.append(item) }
        }
        return unique
    }

    private var filteredMerged: [LogDisplayItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return mergedItems }
        return mergedItems.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.detail.localizedCaseInsensitiveContains(q) ||
            $0.user.localizedCaseInsensitiveContains(q) ||
            $0.room.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredLocal: [BackupLogEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return logs }
        return logs.filter { e in
            e.category.localizedCaseInsensitiveContains(q) ||
            e.action.localizedCaseInsensitiveContains(q) ||
            e.detail.localizedCaseInsensitiveContains(q) ||
            e.result.localizedCaseInsensitiveContains(q) ||
            (e.username ?? "").localizedCaseInsensitiveContains(q)
        }
    }
    private var filteredCloud: [CloudOpEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return cloudLogs }
        return cloudLogs.filter { e in
            e.op.localizedCaseInsensitiveContains(q) ||
            e.detail.localizedCaseInsensitiveContains(q) ||
            e.user.localizedCaseInsensitiveContains(q) ||
            e.room.localizedCaseInsensitiveContains(q)
        }
    }

    private var deleteCount: Int { section == 0 ? selectedLocal.count : selectedCloud.count }
    private var deleteCountLabel: String { deleteCount == 0 ? "删除" : "删除(\(deleteCount))" }

    private func reloadLocal() { logs = BackupLogStore.all(); selectedLocal = [] }
    private func loadCloud() {
        CloudOps.fetch { entries in
            DispatchQueue.main.async { cloudLogs = entries; selectedCloud = [] }
        }
    }
    private func exitEdit() { isEditing = false; selectedLocal = []; selectedCloud = [] }
    private func performClear() {
        // v1.63：云端不再提供一键清空（仅本机日志可清空；云端只能左滑/多选逐条删除）
        BackupLogStore.clear(); reloadLocal()
        showClearConfirm = false
    }
    private func deleteSelected() {
        if section == 0 {
            let entries = selectedLocal.compactMap { i in i < filteredLocal.count ? filteredLocal[i] : nil }
            for e in entries { BackupLogStore.remove(e) }
            reloadLocal()
        } else {
            let entries = selectedCloud.compactMap { i in i < filteredCloud.count ? filteredCloud[i] : nil }
            for e in entries { CloudOps.delete(e) }
            loadCloud()
        }
        exitEdit()
    }

    // MARK: 导出（本机 / 云端各自导出 txt 到 app 根目录）
    private func exportLogs() {
        if section == 0 { exportLocalLogs() } else { exportCloudLogs() }
    }
    private func exportLocalLogs() {
        guard !logs.isEmpty else { exportTip = "暂无本机操作日志可导出"; return }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"; df.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "操作日志_\(df.string(from: Date())).txt"
        var lines = ["公寓管家 · 操作日志（本机）", "导出时间：\(Date())", "共 \(logs.count) 条", "------------------"]
        for entry in logs {
            var line = "[\(entry.date.formatted(date: .numeric, time: .standard))] \(entry.category) / \(entry.action) / \(entry.result)"
            if let name = entry.username, !name.isEmpty { line += " / 操作者：\(name)" }
            lines.append(line)
            if !entry.detail.isEmpty { lines.append("   详情：\(entry.detail)") }
            if !entry.checksum.isEmpty { lines.append("   校验和：\(entry.checksum)") }
            lines.append("")
        }
        writeExport(fileName: fileName, lines: lines)
    }
    private func exportCloudLogs() {
        guard !cloudLogs.isEmpty else { exportTip = "暂无云端操作记录可导出"; return }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"; df.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "操作日志(云端)_\(df.string(from: Date())).txt"
        var lines = ["公寓管家 · 云端操作记录", "导出时间：\(Date())", "共 \(cloudLogs.count) 条", "------------------"]
        for e in cloudLogs {
            let who = e.user.isEmpty ? "未设置" : e.user
            lines.append("[\(e.t)] \(e.op)" + (e.room.isEmpty ? "" : " / 房号：\(e.room)") + " / 操作者：\(who)")
            if !e.detail.isEmpty { lines.append("   详情：\(e.detail)") }
            lines.append("")
        }
        writeExport(fileName: fileName, lines: lines)
    }
    private func writeExport(fileName: String, lines: [String]) {
        let content = lines.joined(separator: "\n")
        let fileURL = DataRoot.url().appendingPathComponent(fileName)
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            exportTip = "已导出到：\n\(fileURL.lastPathComponent)\n\n（App 根目录 / 数据文件夹）"
        } catch {
            exportTip = "导出失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 统一日志卡片模型（三个 tab 同构，v2.47）

private struct LogDisplayItem: Identifiable {
    let id: String
    let title: String        // 动作
    let room: String         // 房号
    let detail: String       // 具体变化
    let user: String         // 操作者
    let timeText: String     // yyyy-MM-dd HH:mm
    let date: Date
    let resultBadge: String  // 非成功时标题旁的结果
    let tint: Color

    private static let failWords = ["失败", "错误", "异常", "报错", "超时", "中断", "拒绝"]

    private static func cloudStyleText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func parseCloudDate(_ t: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: t) ?? Date.distantPast
    }

    private static func tintFor(title: String, isFail: Bool) -> Color {
        if isFail { return .red }
        if title.contains("删除") || title.contains("清空") { return .red }
        if title.contains("修改") || title.contains("编辑") || title.contains("切换状态")
            || title.contains("标记已租") || title.contains("迁移") || title.contains("合并")
            || title.contains("冲突") { return .orange }
        return .green
    }

    init(local e: BackupLogEntry, index: Int) {
        let isFail = Self.failWords.contains { e.result.contains($0) }
        self.id = "local-\(e.date.timeIntervalSince1970)-\(e.action)-\(index)"
        self.title = e.action
        self.room = e.room ?? HouseLedgerMigrator.parseRoomKey(in: e.detail) ?? ""
        self.detail = e.detail
        self.user = e.username ?? ""
        self.timeText = Self.cloudStyleText(e.date)
        self.date = e.date
        self.resultBadge = (e.result.isEmpty || e.result == "成功") ? "" : e.result
        self.tint = Self.tintFor(title: e.action, isFail: isFail)
    }

    init(cloud c: CloudOpEntry, index: Int) {
        let p = c.op.components(separatedBy: "·")
        let cat = p.first ?? c.op
        let act = p.count > 1 ? p[1] : cat
        let res = p.count > 2 ? p[2] : ""
        let isFail = Self.failWords.contains { res.contains($0) }
        self.id = "cloud-\(c.t)-\(c.op)-\(c.user)-\(c.room)-\(index)"
        self.title = act
        self.room = c.room
        self.detail = c.detail
        self.user = c.user
        self.timeText = c.t
        self.date = Self.parseCloudDate(c.t)
        self.resultBadge = (res.isEmpty || res == "成功") ? "" : res
        self.tint = Self.tintFor(title: act, isFail: isFail)
    }
}

// MARK: - 统一日志卡片（与原云端卡片同构）

private struct LogDisplayRow: View {
    let item: LogDisplayItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                // 第一行：动作
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(item.tint)
                    if !item.resultBadge.isEmpty {
                        Text(item.resultBadge).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(item.timeText).font(.caption).foregroundColor(.secondary)
                }
                // 第二行：房号
                if !item.room.isEmpty {
                    Text("房号：\(item.room)")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.primary)
                }
                // 第三行：具体变化
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if !item.user.isEmpty {
                        Text("操作者：\(item.user)").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 通知通道（SettingsView alert 复用）

extension Notification.Name {
    static let backupCenterMessage = Notification.Name("backupCenterMessage")
}

// MARK: - 系统分享（导出崩溃日志）

struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
