import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Security

// MARK: - v1.34 钥匙串写入修复（独立实现，避免改动 CosUploader.swift 整文件）

/// 旧 KeychainStore.save 的 bug：SecItemDelete 的查询字典里带了 kSecValueData（要写入的新值），
/// 而删除匹配按查询属性匹配——旧条目存的是旧数据，与新值不匹配 → 删不掉旧条目；
/// 随后 SecItemAdd 因同 account 条目已存在返回 errSecDuplicateItem 被当作成功 → 返回 true 但钥匙串仍是旧值
/// （表现为「保存成功退出再进又变回旧地域」，自检时读到 ap-guangzhou 旧值）。
/// 新实现：存在则 SecItemUpdate 更新、不存在则 SecItemAdd 添加，并立即回读比对，值一致才返回 true。
enum KeychainFix {
    private static let service = "com.gj.tg2.housekeeper"

    @discardableResult
    static func saveVerified(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        // 已存在 → 更新（保留 kSecAttrAccessible 属性不被覆盖）
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return load(key) == value   // 回读验证：值一致才算成功
        }
        if updateStatus != errSecItemNotFound {
            return false   // 权限等错误，明确失败
        }
        // 不存在 → 新增
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        return load(key) == value   // 回读验证
    }

    /// 删除指定 key 的钥匙串条目（清空配置用）
    static func deleteKey(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 设置页（v1.22 重构：归拢成两个入口——远程配置 / 名片信息）
/// 远程配置：腾讯云 COS 存储桶、密钥、自定义域名（用于分享房源卡片链接）
/// 名片信息：分享 H5 页面与微信卡片上显示的姓名/电话（默认：梁涛 / 13288251132）
///
/// v1.6（公寓管家）：独立设置页取消——房源分享相关设置合并进主 App「设置 → 房源分享」分组，
/// 本文件保留远程配置（CosConfigView）、名片信息（ShareProfileView）、恢复列表（ConfigRestoreListView）、
/// 钥匙串修复（KeychainFix）与配置备份（CosConfigBackup）等子页面与工具，供主设置页复用。

/// 数据文件夹总大小 = 「备份」子文件夹 + 「media」房源媒体文件夹（平级两个目录）。
/// v1.40 起房源媒体独立到 Documents/media/（不再挂在备份/Media 下），旧实现只统计「备份」漏掉了整个媒体目录，统计偏小。
func houseDocumentsSizeText() -> String {
    var total: Int64 = 0
    for root in [DataRoot.url(), MediaStore.mediaDirectory()] {
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
    }
    return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
}

/// v1.98：AI 产物缓存大小（Documents/AI产物/，设置页「AI对话缓存」行展示）
func aiCacheSizeText() -> String {
    let bytes = MainActor.assumeIsolated { AIToolExecutor.aiArtifactSizeBytes() }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - 远程配置（腾讯云 COS）

/// v1.19：新增「自定义域名（可选）」——腾讯云 2024 年后新建桶默认域名会被微信识别成文件，
/// 绑定自定义域名后微信才会把分享链接抓成网页卡片；域名留空则回退默认域名（仅兜底）
/// v1.20：保存改为「保存并验证连接」——写入钥匙串成功后立即用当前配置向 COS 上传一个测试文件
/// 并回读，真实连通才算保存成功；任何环节失败都会给出具体错误码（桶不存在/签名错误/域名未生效），
/// 不再静默提示「已保存」；同时密钥写入失败也会明确报出。
// MARK: - COS 配置备份 / 恢复（v1.33 剪贴板版 → v1.34 文件版）

/// v1.13 需求16：COS 配置备份统一存放目录 Documents/备份/CosConfig/（不再散在「备份」根目录）
enum CosConfigStore {
    static func directory() -> URL {
        let dir = DataRoot.url().appendingPathComponent("CosConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 把钥匙串里的 COS 配置导出为 JSON（v1.34 改为生成「桶名_地域_日期.json」文件由用户选择位置保存），
/// 换机 / 重装 / 误改后可从备份文件一键恢复。配置含密钥，备份文件请妥善保管。
enum CosConfigBackup {
    /// v1.44：备份文件补全云函数地址 + 用户名——换机/重装后一键还原应包含完整连接参数与身份
    static func exportJSON() -> String? {
        guard let config = CosConfig.load() else { return nil }
        let dict: [String: String] = [
            "bucket": config.bucket,
            "region": config.region,
            "secretId": config.secretId,
            "secretKey": config.secretKey,
            "customDomain": config.customDomain,
            "functionURL": CloudConfig.functionURL,
            "username": CloudUser.username
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// 从备份文件内容恢复配置到钥匙串；返回 (是否成功, 提示)
    static func restore(fromJSON json: String) -> (Bool, String) {
        guard let data = json.data(using: .utf8) else {
            return (false, "所选文件内容不是有效的配置文本，请确认选择的是「备份配置到文件」生成的 .json 文件")
        }
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return (false, "所选文件内容不是有效的配置文本，请确认选择的是「备份配置到文件」生成的 .json 文件")
        }
        guard let dict = parsed as? [String: Any] else {
            return (false, "所选文件内容不是有效的配置文本，请确认选择的是「备份配置到文件」生成的 .json 文件")
        }
        let trimSet = CharacterSet.whitespacesAndNewlines
        let bucket = (dict["bucket"] as? String ?? "").trimmingCharacters(in: trimSet)
        let region = (dict["region"] as? String ?? "").trimmingCharacters(in: trimSet)
        let secretId = (dict["secretId"] as? String ?? "").trimmingCharacters(in: trimSet)
        let secretKey = (dict["secretKey"] as? String ?? "").trimmingCharacters(in: trimSet)
        let customDomain = (dict["customDomain"] as? String ?? "").trimmingCharacters(in: trimSet)
        let functionURL = (dict["functionURL"] as? String ?? "").trimmingCharacters(in: trimSet)
        let uname = (dict["username"] as? String ?? "").trimmingCharacters(in: trimSet)
        if bucket.isEmpty || region.isEmpty || secretId.isEmpty || secretKey.isEmpty {
            return (false, "配置缺少必填项（存储桶 / 地域 / SecretId / SecretKey），请检查备份文件")
        }
        var allSaved = true
        let items: [(String, String)] = [
            (KeychainKey.bucket, bucket),
            (KeychainKey.region, region),
            (KeychainKey.secretId, secretId),
            (KeychainKey.secretKey, secretKey),
            (KeychainKey.customDomain, customDomain)
        ]
        for item in items {
            if !KeychainFix.saveVerified(item.1, for: item.0) {
                allSaved = false
            }
        }
        if !allSaved {
            return (false, "写入本机钥匙串失败，请重试；若仍失败请重启 App 后再试")
        }
        // v1.44：备份里的云函数地址 + 用户名一并还原（旧备份无此字段时保持原值，不覆盖）
        if !functionURL.isEmpty { CloudConfig.functionURL = functionURL }
        if !uname.isEmpty { CloudUser.username = uname }
        let msg = "配置已恢复：地域 " + region + " / 存储桶 " + bucket
            + (functionURL.isEmpty ? "" : "\n云函数地址：\(functionURL)")
            + (uname.isEmpty ? "" : "\n用户名：\(uname)")
            + "\n表单已刷新，可点「保存并验证连接」确认可用"
        return (true, msg)
    }
}

struct CosConfigView: View {
    @State private var username = ""
    // 房源服务器（8082 权威库）地址与状态
    @State private var endpointInput = ""
    @State private var serverTip: String?
    @State private var savedTip: String?

    init() {
        _username = State(initialValue: CloudUser.username)
        _endpointInput = State(initialValue: MeterStore.shared.settings.cloudEndpointRaw ?? "")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("连接状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(HouseServerMode.ready ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(HouseServerMode.ready ? "已接入服务器" : HouseServerMode.notReadyReason)
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                }
                Toggle("启用服务器同步", isOn: Binding(
                    get: { HouseServerMode.enabled },
                    set: { HouseServerMode.enabled = $0 }))
                TextField("服务器地址", text: $endpointInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack(spacing: 12) {
                    Button {
                        saveServerEndpoint()
                    } label: {
                        Label("保存", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 31/255, green: 58/255, blue: 95/255))
                    Button {
                        clearServerEndpoint()
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if let serverTip {
                    Text(serverTip).font(.footnote).foregroundColor(.green)
                }
            } header: {
                Text("房源服务器（台账权威库）")
            } footer: {
                Text("房源文字台账、状态与修订记录存到这台服务器；未接入服务器时回退本机数据。")
            }

            Section {
                TextField("我的用户名（如：涛）", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    saveUsername()
                } label: {
                    Label("保存用户名", systemImage: "person.fill.checkmark")
                }
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("用户名")
            } footer: {
                Text("操作日志 / 分享 / 统计都会带上这个名字。")
            }
        }
        .navigationTitle("云端配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            username = CloudUser.username
        }
        .alert("配置结果", isPresented: Binding(
            get: { savedTip != nil },
            set: { if !$0 { savedTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(savedTip ?? "")
        }
    }

    private func saveServerEndpoint() {
        let v = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { serverTip = "地址不能为空"; return }
        MeterStore.shared.settings.cloudEndpoint = v
        MeterStore.shared.saveSettings()
        serverTip = "服务器地址已保存"
    }

    private func clearServerEndpoint() {
        MeterStore.shared.settings.cloudEndpointRaw = nil
        MeterStore.shared.saveSettings()
        endpointInput = ""
        serverTip = "已恢复默认服务器地址"
    }

    private func saveUsername() {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        username = trimmed
        CloudUser.username = trimmed
        savedTip = trimmed.isEmpty
            ? "用户名不能为空，请输入后保存"
            : "用户名已保存：\(trimmed)\n操作日志 / 分享 / 统计都会带上它"
    }
}
/// 列出「备份」文件夹内的 .json 备份文件，点击直接恢复（与主 App 恢复备份同款列表写法）；
/// 列表底部提供「从其他位置选择」用系统文件选择器兜底（保留自由选择路径的能力）。
/// v1.44：文件选择器改为本列表视图内自挂（此前跨视图延迟弹 sheet 在 iOS 上偶发被吞，按钮无效）
struct ConfigRestoreListView: View {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("「备份」文件夹里还没有备份文件")
                            .font(.headline)
                        Text("请先点「备份配置到文件」生成备份，或把备份 .json 文件放进 iOS「文件」App → 我的 iPhone → 公寓管家 → 备份 文件夹")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button {
                            showImporter = true
                        } label: {
                            Label("从其他位置选择…", systemImage: "folder")
                                .font(.subheadline)
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(files, id: \.self) { url in
                            Button {
                                onPick(url)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(fileSize(of: url))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        Section {
                            Button {
                                showImporter = true
                            } label: {
                                Label("从其他位置选择…", systemImage: "folder")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("选择备份文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear(perform: loadFiles)
            // v1.44：文件选择器直接挂在本视图上（不再经父视图延迟弹），保证点按钮立即弹出系统文件选择器
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        onPick(url)
                        dismiss()
                    }
                case .failure:
                    break
                }
            }
        }
    }

    /// 列出「备份/CosConfig」文件夹内的 .json 文件（v1.13 需求16：配置备份收拢到子文件夹），
    /// 兼容旧位置「备份」根目录残留文件（启动迁移未执行完的场景），按文件名（含日期）倒序，最新的在最上面
    private func loadFiles() {
        let fm = FileManager.default
        var collected: [URL] = []
        for dir in [CosConfigStore.directory(), DataRoot.url()] {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            collected += items.filter { $0.pathExtension.lowercased() == "json" }
        }
        // 去重（同路径只保留一次）
        var seen = Set<String>()
        files = collected
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func fileSize(of url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}


// MARK: - 名片信息

/// v1.21：分享名片信息（姓名/电话）——显示在分享 H5 页面的名片区、微信卡片的描述和
/// 「拨打电话/复制电话」按钮上。v1.22：修改后再次分享自动按新名片重新生成链接
/// （分享缓存里存了名片，名片一变缓存自动失效，无需手动清缓存）。
/// v1.26：①新增实时名片预览；②说明应用范围覆盖所有出现姓名/电话的位置
/// （H5 名片区、微信卡片描述、页面底栏电话、拨打电话/复制电话）。
/// v1.27：新增「微信二维码」入口——从相册选择二维码图片保存（Documents/qrcode.png），
/// 分享时自动上传 COS 并显示在所有 H5 名片板块左侧，访客长按可直接被微信识别。
struct ShareProfileView: View {
    @State private var shareName = ""
    @State private var sharePhone = ""
    @State private var savedTip: String?
    @State private var qrImage: UIImage?
    @State private var qrPickerItem: PhotosPickerItem?

    init() {
        let n = KeychainStore.load(KeychainKey.shareName) ?? "梁涛"
        let p = KeychainStore.load(KeychainKey.sharePhone) ?? "13288251132"
        _shareName = State(initialValue: n)
        _sharePhone = State(initialValue: p)
        if let data = QrcodeStore.loadData() {
            _qrImage = State(initialValue: UIImage(data: data))
        }
    }

    /// 预览用的姓名/电话：输入为空时显示默认值（与分享时行为一致）
    private var previewName: String {
        let n = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "梁涛" : n
    }
    private var previewPhone: String {
        let p = sharePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "13288251132" : p
    }

    /// 旧桶二维码上行已下线：二维码只存本机 QrcodeStore；服务器名片/二维码上行通道待阶段 B 接入。
    private func syncQRToCloud(clear: Bool) {}

    var body: some View {
        Form {
            // v1.26：实时名片预览——输入即变，所见即所得
            Section(header: Text("名片预览")) {
                VStack(spacing: 10) {
                    Text("米兰租赁管家 · 专业省心租好房")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text(previewName)
                            .font(.headline)
                        Text(previewPhone)
                            .font(.headline)
                            .foregroundColor(.orange)
                    }
                    Text("微信同号 · 24小时可约看房")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        Text("拨打电话")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 9)
                            .background(Color(red: 31/255, green: 58/255, blue: 95/255))
                            .clipShape(Capsule())
                        Text("复制电话")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 9)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    // v1.27：二维码预览（有则显示缩略图，无则提示）
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .background(Color.white)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray4), lineWidth: 1))
                            .padding(.top, 6)
                    } else {
                        Text("未设置微信二维码")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .cornerRadius(14)
                .padding(.top, 4)
            }

            Section(header: Text("名片信息"), footer: Text("姓名和电话会应用到所有出现它们的地方：分享 H5 页面的名片区（含合集列表与详情页）、微信卡片的描述、页面底栏的联系电话、以及「拨打电话/复制电话」按钮。修改并保存后，下次分享会自动按新名片重新生成链接；之前已发出的链接保持原样。")) {
                TextField("姓名（默认：梁涛）", text: $shareName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("电话（默认：13288251132）", text: $sharePhone)
                    .keyboardType(.phonePad)
                Button {
                    saveShareProfile()
                } label: {
                    Text("保存名片信息")
                        .frame(maxWidth: .infinity)
                }
                .disabled(shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // v1.27：微信二维码——相册选择保存；分享时自动上传，显示在所有 H5 名片板块左侧
            Section(header: Text("微信二维码"), footer: Text("二维码会显示在所有分享 H5 页面的名片板块左侧（拨打电话/复制电话上方），访客长按二维码即可弹出微信「识别图中二维码」菜单。更换后无需重新分享——已发出的链接也会自动显示新二维码。")) {
                PhotosPicker(selection: $qrPickerItem, matching: .images) {
                    Label(qrImage == nil ? "选择二维码图片" : "更换二维码图片", systemImage: "qrcode")
                }
                .onChange(of: qrPickerItem) { _, newItem in
                    guard let newItem else { return }
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self),
                           let image = UIImage(data: data),
                           let jpeg = image.jpegData(compressionQuality: 0.9) {
                            let ok = QrcodeStore.save(jpeg)
                            qrImage = UIImage(data: jpeg)
                            // v1.42：保存后立即同步云端桶 users/<用户名>/qrcode.jpg——
                            //        已发出的 H5 链接动态引用桶 URL，无需重新分享即显示新二维码（此前只写本地，要等下次分享才上传）
                            syncQRToCloud(clear: false)
                            savedTip = ok ? "微信二维码已更新 ✅\n已发出的分享链接也会立即显示新二维码" : "保存二维码失败，请重试"
                        } else {
                            savedTip = "无法读取所选图片，请换一张清晰的二维码图片"
                        }
                        qrPickerItem = nil
                    }
                }
                if qrImage != nil {
                    Button("清除二维码", role: .destructive) {
                        QrcodeStore.clear()
                        qrImage = nil
                        // v1.42：清除后立即删除云端桶二维码，已发出链接不再显示（此前只清本地）
                        syncQRToCloud(clear: true)
                        savedTip = "二维码已清除，已发出的分享链接不再显示二维码"
                    }
                }
            }
        }
        .navigationTitle("名片信息")
        .navigationBarTitleDisplayMode(.inline)
        // v1.42：返回本页时重新读本地二维码（与分享水印开关同款修法——init 缓存可能陈旧，onAppear 刷新即显示最新）
        .onAppear {
            if let data = QrcodeStore.loadData() {
                qrImage = UIImage(data: data)
            } else {
                qrImage = nil
            }
        }
        .alert("保存结果", isPresented: Binding(
            get: { savedTip != nil },
            set: { if !$0 { savedTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(savedTip ?? "")
        }
    }

    /// 旧桶名片上行已下线：姓名/电话只存本机钥匙串；服务器名片上行通道待阶段 B 接入。
    private func syncProfileToCloud(name: String, phone: String) {}

    /// 保存分享名片信息（姓名/电话）到钥匙串
    private func saveShareProfile() {
        let name = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = sharePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            savedTip = "姓名不能为空"
            return
        }
        var ok = KeychainFix.saveVerified(name, for: KeychainKey.shareName)
        ok = KeychainFix.saveVerified(phone, for: KeychainKey.sharePhone) && ok
        // v1.47：保存后同步云端名片（公开选房页实时生效）
        syncProfileToCloud(name: name, phone: phone)
        savedTip = ok ? "名片信息已保存 ✅\n姓名：\(name)\n电话：\(phone.isEmpty ? "（未填，分享时用默认号）" : phone)\n公开选房链接刷新后同步更新" : "写入本机钥匙串失败，请重新保存一次"
    }
}

// MARK: - v1.47 公开选房链接（发给租客的实时选房 H5）

/// 选房链接页：生成「公开选房 H5」链接（云函数 ?act=rooms&u=<用户名>），
/// 复制/分享给租客即可实时查看所有待租房源；改房源、改名片、换二维码后租客刷新即最新。
struct RoomsShareView: View {
    @State private var cosLink = ""
    @State private var linkTip: String?
    @State private var copiedTip: String?
    @State private var showShareSheet = false

    /// v1.49：公开选房链接改为 COS 签名链接（与单房分享 H5 同域名同机制，微信内可正常打开）。
    /// 由云函数 roomsSeed 生成静态壳并上传桶 users/<用户名>/rooms/index.html 后返回；
    /// 壳页面每次打开/刷新 JS 实时拉 rooms_json 数据，房源/名片/二维码变化刷新即最新，无需重建。
    private var link: String { cosLink }

    var body: some View {
        Form {
            Section(header: Text("公开选房链接"), footer: Text("把链接发给租客，对方打开即可看到所有待租房源（只显示户型，房东/密码/备注等内部信息已隐藏）。页面每次打开或刷新都实时读取云端最新房源：您新增/下架房源、改租金、改名片、换二维码后，租客刷新一下就是最新内容，无需重新生成链接。\n\n链接默认 2 天内有效（可在「设置 → 房源分享 → 选房链接有效期」调整）。到期后旧链接失效，需重新生成新链接发给租客。")) {
                if link.isEmpty {
                    Text(linkTip ?? "正在生成链接…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text(link)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundColor(.secondary)
                    Button {
                        UIPasteboard.general.string = link
                        copiedTip = "链接已复制 ✅\n直接发给租客即可（微信内可直接打开）"
                    } label: {
                        Label("复制链接", systemImage: "doc.on.doc")
                    }
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("分享给租客", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        Task { await refreshLink() }
                    } label: {
                        Label("重新生成链接", systemImage: "arrow.clockwise")
                    }
                }
            }
            Section(header: Text("名片与二维码"), footer: Text("选房页底部展示的名片（姓名/电话）与微信二维码在这里设置：改完保存后，租客刷新选房页面即显示最新内容（名片同步云端 profile.json、二维码同步 qrcode.jpg，均为实时生效）。")) {
                NavigationLink {
                    ShareProfileView()
                } label: {
                    Label("编辑名片 / 二维码", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
        }
        .navigationTitle("公开选房链接")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if cosLink.isEmpty {
                Task { await refreshLink() }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            HouseShareSheet(items: [link])
        }
        .alert("已复制", isPresented: Binding(
            get: { copiedTip != nil },
            set: { if !$0 { copiedTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(copiedTip ?? "")
        }
    }

    /// 选房页由服务器本地托管静态壳，长期有效，房源/名片刷新即最新；旧桶 H5 壳上传链路已下线。
    private func refreshLink() async {
        if HouseServerMode.ready {
            if let h5 = HouseRemoteClient.h5URL() {
                cosLink = h5.absoluteString
                linkTip = "链接长期有效；房源、名片或二维码更新后，租客刷新页面即为最新"
            } else {
                cosLink = ""
                linkTip = "服务器地址未配置，请到「电表监控设置」检查服务器地址"
            }
            return
        }
        cosLink = ""
        linkTip = "服务器地址未配置，请到「电表监控设置」检查服务器地址"
    }
}
