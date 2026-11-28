import SwiftUI

// MARK: - v1.82 远程配置原生化（中文显示 + 排版优化）
/// 读取：服务器 fetchConfig → 未配置/为空时用默认模板填充
/// 保存：服务器 putConfig（自动 version+1）→ 云端生效 + 写本地缓存
/// 所有配置项显示中文名称（英文 key 以小字副标题展示，便于对照后台文档）
struct RemoteConfigAdminView: View {
    @State private var config = RemoteConfig.Payload()
    @State private var loading = false
    @State private var saving = false
    @State private var statusText = ""
    @State private var loaded = false

    // 更新日志新增条目
    @State private var newCLVersion = ""
    @State private var newCLDate = ""
    @State private var newCLChanges = ""

    /// v1.89：AI 模型清单（JSON 文本编辑）
    @State private var aiModelsJSON = ""

    // v2.21：App 在线更新表单
    @State private var updateVersion = ""
    @State private var updateBuild = ""
    @State private var updateObjectKey = ""
    @State private var updateDownloadURL = ""
    @State private var updateInstallPage = ""
    @State private var updateSize = ""
    @State private var updateSha = ""
    @State private var updateNotes = ""

    var body: some View {
        Form {
            // ── 顶部：状态 + 操作 ──
            Section {
                HStack {
                    Label("配置版本", systemImage: "number")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(config.version > 0 ? "v\(config.version)" : "未加载")
                        .fontWeight(.semibold)
                }
                if let ua = config.updatedAt, !ua.isEmpty {
                    HStack {
                        Label("更新时间", systemImage: "clock")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ua)
                    }
                }
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(statusText.contains("失败") || statusText.contains("无效") ? .red : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button {
                        loadConfig()
                    } label: {
                        Label(loading ? "加载中…" : "从云端加载", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(loading || saving)
                    Button {
                        saveConfig()
                    } label: {
                        Label(saving ? "保存中…" : "保存到云端", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || saving)
                }
            } header: {
                Label("远程配置中心", systemImage: "gearshape.2")
            } footer: {
                Text("保存后立即写入云端，App 下次启动 / 同步自动生效；断网时 App 使用本地缓存，不受影响。")
            }

            // ── 基础设置 ──
            Section {
                Toggle("显示公告横幅", isOn: Binding(get: {
                    config.announcement?.enabled ?? false
                }, set: { v in
                    var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                    a.enabled = v
                    config.announcement = a
                }))
                .tint(.green)
                if config.announcement?.enabled == true {
                    LabeledContent {
                        TextField("公告文字", text: Binding(get: {
                            config.announcement?.text ?? ""
                        }, set: { v in
                            var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                            a.text = v
                            config.announcement = a
                        }), axis: .vertical)
                        .lineLimit(1...3)
                        .multilineTextAlignment(.trailing)
                    } label: {
                        Text("公告文字").foregroundStyle(.secondary)
                    }
                    LabeledContent {
                        TextField("选填，点击可跳转", text: Binding(get: {
                            config.announcement?.link ?? ""
                        }, set: { v in
                            var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                            a.link = v.isEmpty ? nil : v
                            config.announcement = a
                        }))
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .multilineTextAlignment(.trailing)
                    } label: {
                        Text("公告链接").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("基础设置", systemImage: "slider.horizontal.3")
            }

            // ── 功能开关 ──
            Section {
                ForEach(config.features.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(Self.label(key), isOn: Binding(get: {
                            config.features[key] ?? false
                        }, set: { config.features[key] = $0 }))
                        .tint(.green)
                        if Self.label(key) != key {
                            Text(key).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Label("功能开关", systemImage: "switch.2")
            }

            // ── 数值参数 ──
            Section {
                ForEach(config.params.keys.sorted(), id: \.self) { key in
                    LabeledContent {
                        TextField("", text: Binding(get: {
                            let v = config.params[key] ?? 0
                            return v == v.rounded() ? String(Int(v)) : String(v)
                        }, set: { t in
                            config.params[key] = Double(t) ?? (config.params[key] ?? 0)
                        }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.label(key))
                            if Self.label(key) != key {
                                Text(key).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Label("数值参数", systemImage: "number.circle")
            }

            // ── 提示文案 ──
            Section {
                ForEach(config.tips.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(Self.label(key)).font(.subheadline).fontWeight(.medium)
                            if Self.label(key) != key {
                                Text(key).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        TextField("提示内容", text: Binding(get: {
                            config.tips[key] ?? ""
                        }, set: { config.tips[key] = $0 }), axis: .vertical)
                            .lineLimit(1...3)
                            .font(.footnote)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Label("提示文案（App 内各处提示语）", systemImage: "text.bubble")
            }

            // ── 帮助说明 ──
            Section {
                ForEach(config.helpTexts.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(Self.label(key)).font(.subheadline).fontWeight(.medium)
                            if Self.label(key) != key {
                                Text(key).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        TextField("帮助内容", text: Binding(get: {
                            config.helpTexts[key] ?? ""
                        }, set: { config.helpTexts[key] = $0 }), axis: .vertical)
                            .lineLimit(1...5)
                            .font(.footnote)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Label("帮助说明（设置页长文案）", systemImage: "questionmark.circle")
            }

            // ── App 在线更新（v2.21）──
            Section {
                TextField("最新版本号，如 2.21", text: $updateVersion)
                TextField("Build 号，如 144", text: $updateBuild)
                    .keyboardType(.numberPad)
                TextField("服务器媒体路径，如 update/公寓管家2.21-b144.ipa", text: $updateObjectKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("备用直链 https（选填）", text: $updateDownloadURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("第三方签名平台安装页（选填）", text: $updateInstallPage)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("安装包大小（字节，选填）", text: $updateSize)
                    .keyboardType(.numberPad)
                TextField("SHA256（选填，填了下载后校验）", text: $updateSha)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("更新内容，每行一条（留空自动取下方版本记录）", text: $updateNotes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Label("App 在线更新（v2.21）", systemImage: "arrow.up.circle")
            } footer: {
                Text("最新版本号高于用户当前版本时，工作台版本号变橙色「↑」胶囊，设置页出现「发现新版本」。服务器媒体目录只保留最新一个安装包：先删 update/ 下旧包再传新包，把媒体路径填到第一栏。更新内容留空会自动取下方「版本更新记录」里对应版本的条目。")
            }

            // ── AI 模型清单（v1.89）──
            Section {
                TextEditor(text: $aiModelsJSON)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                Text("格式：[{\"modelID\":\"doubao-…\",\"name\":\"模型名\",\"desc\":\"说明\"}]；保存时自动校验，非法 JSON 不生效")
                    .font(.caption2).foregroundStyle(.secondary)
            } header: {
                Label("AI 模型清单（设置页模型下拉扩展）", systemImage: "brain")
            } footer: {
                Text("App 内置默认 3 个模型；这里追加账号下已开通的其他模型，App 设置页会自动合并显示并附说明。")
            }

            // ── 版本更新记录 ──
            Section {
                let list = Binding<[RemoteConfig.ChangelogEntry]>(
                    get: { config.changelog ?? [] },
                    set: { config.changelog = $0 }
                )
                ForEach(list.wrappedValue) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.version)\(entry.date.map { " · \($0)" } ?? "")")
                            .font(.footnote).fontWeight(.semibold)
                        ForEach(entry.changes, id: \.self) { c in
                            Text("· \(c)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    var arr = list.wrappedValue
                    arr.remove(atOffsets: offsets)
                    config.changelog = arr
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("新增一条（添加到顶部）").font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("版本号", text: $newCLVersion)
                            .textFieldStyle(.roundedBorder)
                        TextField("日期（可选）", text: $newCLDate)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField("改动内容，每行一条", text: $newCLChanges, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("添加到日志") { addChangelog() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newCLVersion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 2)
            } header: {
                Label("版本更新记录（App 设置页展示）", systemImage: "list.bullet.clipboard")
            } footer: {
                Text("左滑条目可删除。新增条目会显示在 App 设置页的版本记录顶部。")
            }

            // ── 底部保存 ──
            Section {
                Button {
                    saveConfig()
                } label: {
                    Label(saving ? "保存中…" : "保存全部配置到云端", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || saving)
            }
        }
        .navigationTitle("远程配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loaded { loadConfig() }
        }
    }

    // MARK: 加载

    private func loadConfig() {
        loading = true
        statusText = ""
        Task { @MainActor in
            guard HouseServerMode.ready else {
                loading = false
                statusText = "未连接服务器，无法加载配置"
                return
            }
            do {
                let dict = try await HouseRemoteClient.shared.fetchConfig()
                if let fetched = Self.payload(from: dict) {
                    config = fetched
                    syncAIModels()
                } else {
                    config = Self.defaultTemplate()
                    aiModelsJSON = ""
                }
                fillUpdateForm()
                loaded = true
                statusText = "已加载服务器配置 v\(config.version)"
                loading = false
            } catch {
                loading = false
                statusText = "服务器配置加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func syncAIModels() {
        if let list = config.aiModels, let data = try? JSONEncoder().encode(list) {
            aiModelsJSON = String(data: data, encoding: .utf8) ?? ""
        } else {
            aiModelsJSON = ""
        }
    }

    private static func payload(from dict: [String: Any]) -> RemoteConfig.Payload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let p = try? JSONDecoder().decode(RemoteConfig.Payload.self, from: data) else { return nil }
        return p
    }

    private static func dictionary(from p: RemoteConfig.Payload) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(p),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    // MARK: 保存

    private func saveConfig() {
        saving = true
        statusText = ""
        // v1.89：解析 AI 模型清单（非法 JSON 则忽略并提示，不阻断其他配置保存）
        let trimmed = aiModelsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            config.aiModels = nil
        } else if let data = trimmed.data(using: .utf8),
                  let list = try? JSONDecoder().decode([RemoteConfig.AIModelInfo].self, from: data) {
            config.aiModels = list
        } else {
            saving = false
            statusText = "AI 模型清单 JSON 格式无效，请检查后重试"
            return
        }
        applyUpdateForm()
        config.version = (config.version > 0 ? config.version : 0) + 1
        var body = config
        body.updatedBy = CloudUser.username

        guard HouseServerMode.ready else {
            saving = false
            statusText = "未连接服务器，无法保存配置"
            return
        }
        Task { @MainActor in
            do {
                guard let dict = Self.dictionary(from: body) else {
                    throw NSError(domain: "RemoteConfigAdmin", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "配置编码失败"])
                }
                try await HouseRemoteClient.shared.putConfig(dict)
                RemoteConfig.apply(body)
                saving = false
                statusText = "已保存 ✓ 服务器配置 v\(body.version)，App 下次启动/同步即生效"
            } catch {
                saving = false
                statusText = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func fillUpdateForm() {
        let u = config.update
        updateVersion = u?.latestVersion ?? ""
        updateBuild = u?.latestBuild.map { String($0) } ?? ""
        updateObjectKey = u?.objectKey ?? ""
        updateDownloadURL = u?.downloadURL ?? ""
        updateInstallPage = u?.installPageURL ?? ""
        updateSize = u?.sizeBytes.map { String($0) } ?? ""
        updateSha = u?.sha256 ?? ""
        updateNotes = (u?.notes ?? []).joined(separator: "\n")
    }

    private func applyUpdateForm() {
        let v = updateVersion.trimmingCharacters(in: .whitespaces)
        if v.isEmpty {
            config.update = nil
            return
        }
        var info = config.update ?? RemoteConfig.UpdateInfo()
        info.latestVersion = v
        info.latestBuild = Int(updateBuild.trimmingCharacters(in: .whitespaces))
        info.objectKey = updateObjectKey.trimmingCharacters(in: .whitespaces)
        info.downloadURL = updateDownloadURL.trimmingCharacters(in: .whitespaces)
        info.installPageURL = updateInstallPage.trimmingCharacters(in: .whitespaces)
        info.sizeBytes = Int(updateSize.trimmingCharacters(in: .whitespaces))
        info.sha256 = updateSha.trimmingCharacters(in: .whitespaces)
        info.notes = updateNotes.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let d = info.releasedAt, !d.isEmpty {
            // 保留已有发布日期
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            info.releasedAt = f.string(from: Date())
        }
        config.update = info
    }

    private func addChangelog() {
        let version = newCLVersion.trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty else { return }
        let date = newCLDate.trimmingCharacters(in: .whitespaces)
        let changes = newCLChanges.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var list = config.changelog ?? []
        list.insert(RemoteConfig.ChangelogEntry(version: version, date: date.isEmpty ? nil : date, changes: changes), at: 0)
        config.changelog = list
        newCLVersion = ""
        newCLDate = ""
        newCLChanges = ""
    }

    // MARK: 配置项中文名（英文 key → 中文显示）

    private static func label(_ key: String) -> String {
        LABELS[key] ?? key
    }

    private static let LABELS: [String: String] = [
        // 功能开关
        "compressUpload": "上传压缩",
        "watermark": "分享水印",
        "autoBackup": "自动备份",
        "showOfflineRestore": "离线重建入口",
        "showRoomsShare": "选房分享入口",
        // 数值参数
        "autoBackupKeepDays": "自动备份保留天数（天）",
        "roomsLinkExpiryDays": "选房链接有效期（天）",
        "videoCompressHeight": "视频压缩高度（px）",
        "imageCompressQuality": "图片压缩质量（0-1）",
        "syncRetryCount": "同步失败重试次数",
        // 提示文案
        "refreshDone": "刷新完成提示",
        "refreshNoChange": "刷新无变化提示",
        "refreshFail": "刷新失败提示",
        "syncFail": "同步失败提示",
        "noCloudConfig": "未配置云端提示",
        "containerUnavailable": "数据容器不可用提示",
        "deletingCloud": "删除云端中提示",
        "bulkDeleteDone": "批量删除完成提示",
        "cloudCopyDeleted": "云端副本已删除提示",
        "cloudDeleteFail": "服务器删除失败提示",
        "bulkRentDone": "批量已租完成提示",
        "backfillFail": "补传云端失败提示",
        "quickBackupOk": "快速备份成功提示",
        "quickBackupFail": "快速备份失败提示",
        "fullBackupOk": "全量备份成功提示",
        "fullBackupFail": "全量备份失败提示",
        "fullBackupSpace": "全量备份空间不足提示",
        "fullBackupRunning": "全量备份进行中提示",
        "offlineRestoreOk": "离线重建完成提示",
        "noLocalLedger": "无本地账本提示",
        "noPreviewRooms": "无可预览房源提示",
        "billPreviewFail": "账单预览失败提示",
        // 帮助说明
        "houseShareFooter": "云端配置与名片说明",
        "backupIntro": "备份体系说明",
        "autoBackupIntro": "自动备份说明",
        "cloudSetupIntro": "云端配置说明",
        "passwordIntro": "后台口令说明",
        "multiShareIntro": "多用户共享说明",
        "clearConfigWarn": "清空配置警告",
        "tencentTutorial": "腾讯云部署教程",
        "backupConfigFile": "备份配置文件说明"
    ]

    // MARK: 默认模板（与云端后台 CFG_DEFAULT 同源，云端未配置时保证全部可编辑）

    private static func defaultTemplate() -> RemoteConfig.Payload {
        var p = RemoteConfig.Payload()
        p.version = 1
        p.announcement = RemoteConfig.Announcement(enabled: false, text: "", link: nil)
        p.minimumVersion = ""
        p.features = [
            "compressUpload": true,
            "watermark": true,
            "autoBackup": true,
            "showOfflineRestore": true,
            "showRoomsShare": true
        ]
        p.params = [
            "autoBackupKeepDays": 7,
            "roomsLinkExpiryDays": 2,
            "videoCompressHeight": 720,
            "imageCompressQuality": 0.85,
            "syncRetryCount": 1
        ]
        p.tips = [
            "refreshDone": "已刷新",
            "refreshNoChange": "已刷新，无变化",
            "refreshFail": "刷新失败，请检查网络",
            "syncFail": "同步失败：{error}",
            "noCloudConfig": "未连接服务器，无法同步房源",
            "containerUnavailable": "数据容器不可用，无法删除",
            "deletingCloud": "正在同步删除服务器副本…",
            "bulkDeleteDone": "已永久删除 {changed} 套（共选中 {total} 套），服务器同步中…",
            "cloudCopyDeleted": "已删除服务器同步副本",
            "cloudDeleteFail": "服务器删除失败：{error}。可在同步任务中心重试",
            "bulkRentDone": "已将 {changed} 套标记为已租（共选中 {total} 套）",
            "backfillFail": "补传服务器失败：{error}。本地房源保持「仅本地」，可稍后重新同步补传",
            "quickBackupOk": "快速备份成功：{file}\n已自动上传服务器（若网络失败会在下次打开 App 时自动重试）",
            "quickBackupFail": "快速备份失败，请检查存储空间",
            "fullBackupOk": "全量备份成功：{file}\n可在「备份文件管理」中手动上传到云端",
            "fullBackupFail": "全量备份失败，请检查存储空间",
            "fullBackupSpace": "存储空间不足，全量备份至少需要与照片视频等量的剩余空间",
            "fullBackupRunning": "正在生成全量备份…",
            "offlineRestoreOk": "离线重建完成：已从本地账本恢复 {n} 套房源",
            "noLocalLedger": "未找到本地账本（media 文件夹中没有 info.json）。请先联网同步一次生成账本，或使用「恢复数据」。",
            "noPreviewRooms": "暂无可预览的收租房源，请先在收租板块添加房源并生成收租计划。",
            "billPreviewFail": "账单预览生成失败，请重试。"
        ]
        p.helpTexts = [
            "houseShareFooter": "服务器配置：服务器地址与账号授权码，用于上传房源图片/视频、生成微信分享 H5 和打开服务器管理后台。名片信息：分享 H5 页面和微信卡片上显示的姓名与电话。压缩上传开启后，新增/编辑房源的图片视频上传服务器与分享 H5 都会压缩（视频压到 720p、图片轻压缩），上传更快更省流量。房源数据（数据库、图片视频、二维码）默认存放在「公寓管家」文件夹内的「备份」「media」两个子文件夹，长按拷贝/共享即为备份，重装后放回原位即可还原。",
            "backupIntro": "备份数据 = 快速备份（账本 + 媒体清单，不含房源与照片视频，自动上传服务器；房源统一从服务器同步恢复）或全量备份（额外含全部房源与照片视频）。恢复会覆盖当前数据，恢复前自动打包当前数据做安全备份，失败自动还原。旧版分板块 JSON 备份仍可在「备份文件管理」中恢复，不会丢失。",
            "autoBackupIntro": "自动备份 = 快速备份（账本 + 房源 + 清单），备份成功后自动上传服务器；超过保留天数（默认 7 天）的自动备份会自动清理，手动备份不会被删除。若到点 App 未在前台，会等下次打开 App 时自动补做。",
            "cloudSetupIntro": "• 单用户：填好服务器地址 + 授权码，房源改动在任务中心手动上传/补传，备份自动上传服务器，后台看统计与用量。\n• 多用户：几台手机接入同一台服务器、各自用授权码接入，房源共享（一台录入，另一台点左上角刷新可见）；名片/水印/统计/备份按用户名隔离，互不读取。\n• 房源板块只保留左上角刷新；点按会先弹出确认，不会直接静默同步。",
            "passwordIntro": "网页版管理后台用此口令登录；App 内打开后台免登录。默认口令 12345678，建议修改为不易猜的字符。保存后会自动同步到服务器后台（App 与网页后台同用此口令）。",
            "multiShareIntro": "多台手机接入同一台服务器、各自用授权码，即可共享房源：一台录入，另一台点左上角刷新就能看到。操作日志/分享/统计会带上您的用户名，其他私有数据（名片/水印/统计/备份）按用户名分开。",
            "clearConfigWarn": "将删除本机保存的服务器地址、授权码等全部配置，并断开与服务器的连接。此操作不可撤销，可先用「备份配置到文件」留底。",
            "tencentTutorial": "1. 准备一台可公网访问的服务器，部署公寓管家服务；2. 打开服务器管理后台，生成 8 位授权码；3. App「云端配置」填服务器地址 + 授权码完成接入；4. 图片、视频、备份全部落服务器本地磁盘，请定期备份服务器数据目录。",
            "backupConfigFile": "点「备份配置到文件」后，备份文件（服务器地址_日期.json，含授权码）会直接生成到 iOS「文件」App → 我的 iPhone → 公寓管家 → 「备份」文件夹，随整个「备份」文件夹一起备份即可。换机 / 重装 / 误改后，点「从备份文件恢复配置」在列表中选择备份文件（或从其他位置导入）即可一键还原。授权码请勿外泄。"
        ]
        p.changelog = []
        return p
    }
}
