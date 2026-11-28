import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Security

// MARK: - v1.34 钥匙串写入修复（独立实现，避免改动 KeychainStore 整文件）

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

/// 设置页（房源服务器配置 / 名片信息）
/// 服务器配置：房源服务器地址与账号授权
/// 名片信息：姓名/电话只存本机钥匙串，分享链接按参数携带，不上传服务器
///
/// 本文件只保留服务器配置（ServerConfigView）、名片信息（ShareProfileView）与钥匙串修复（KeychainFix）。

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

// MARK: - 房源服务器配置

struct ServerConfigView: View {
    @State private var username = ""
    // 房源服务器（8082 权威库）地址与状态；全工程唯一地址编辑入口，电表/通知通道复用同一地址
    @State private var endpointInput = ""
    @State private var serverTip: String?
    @State private var tipPositive = true
    @State private var busy = false
    @State private var savedTip: String?
    // 服务器授权码：换取账号级长期令牌（房源台账 / 电表 / 通知推送共用），入口从电表页归位到本页
    @State private var authCode = ""
    @State private var authBusy = false
    @State private var authTip: String?
    @State private var authPositive = true
    @State private var tokenVersion = 0

    private var sync: MeterCloudSync { MeterCloudSync.shared }
    private var bound: Bool { _ = tokenVersion; return sync.hasToken }

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
                TextField("服务器地址", text: $endpointInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack(spacing: 12) {
                    Button {
                        connect()
                    } label: {
                        HStack(spacing: 6) {
                            if busy { ProgressView().controlSize(.small) }
                            Label("连接", systemImage: "link")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 31/255, green: 58/255, blue: 95/255))
                    .disabled(busy)
                    Button {
                        disconnect()
                    } label: {
                        Label("断开连接", systemImage: "link.slash")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                if let serverTip {
                    Text(serverTip)
                        .font(.footnote)
                        .foregroundColor(tipPositive ? .green : .red)
                }

                Divider()

                if bound {
                    HStack(spacing: 6) {
                        Label("已绑定服务器授权令牌", systemImage: "checkmark.shield.fill")
                            .font(.footnote)
                            .foregroundColor(.green)
                        Spacer()
                        Button("清除", role: .destructive) { clearAuth() }
                            .font(.footnote)
                    }
                } else {
                    TextField("服务器授权码", text: $authCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                    Button {
                        enrollAuth()
                    } label: {
                        HStack(spacing: 6) {
                            if authBusy { ProgressView().controlSize(.small) }
                            Label("验证并授权", systemImage: "key.fill")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 31/255, green: 58/255, blue: 95/255))
                    .disabled(authBusy || authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let authTip {
                    Text(authTip)
                        .font(.footnote)
                        .foregroundColor(authPositive ? .green : .red)
                }
            } header: {
                Text("房源服务器（台账权威库）")
            } footer: {
                Text("房源文字台账、状态与修订记录存到这台服务器；未接入服务器时回退本机数据。点「连接」验证地址可达；在本页输入服务器授权码换取账号令牌，授权后房源台账、电表值守与通知推送共用同一账号。「断开连接」只清空服务器地址，本机账号令牌保留。")
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
        .navigationTitle("服务器配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            username = CloudUser.username
            endpointInput = MeterStore.shared.settings.cloudEndpointRaw ?? ""
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

    /// 连接：先把输入地址落盘，再打 health + stats 验证可达性与账号权限
    private func connect() {
        guard !busy else { return }
        let v = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else {
            serverTip = "地址不能为空"
            tipPositive = false
            return
        }
        MeterStore.shared.settings.cloudEndpoint = v
        MeterStore.shared.saveSettings()
        busy = true
        serverTip = nil
        Task {
            let result = await HouseRepository.shared.testConnection()
            busy = false
            serverTip = result.summary
            tipPositive = result.isPositive
        }
    }

    /// 断开：清空服务器地址（回退默认），本机账号令牌不动
    private func disconnect() {
        MeterStore.shared.settings.cloudEndpointRaw = nil
        MeterStore.shared.saveSettings()
        endpointInput = ""
        serverTip = "已断开：服务器地址已清空（账号令牌保留）"
        tipPositive = false
    }

    /// 用服务器授权码换取账号级长期令牌（房源 / 电表 / 通知共用）
    private func enrollAuth() {
        guard !authBusy else { return }
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            authTip = "请填写服务器授权码"
            authPositive = false
            return
        }
        authBusy = true
        authTip = nil
        Task {
            do {
                _ = try await sync.enroll(store: MeterStore.shared, code: code)
                authBusy = false
                authCode = ""
                tokenVersion += 1
                // 绑定成功后立刻把服务器地址/令牌写进 App Group，CloudOps 与分享扩展
                // 下一次操作即可写日志，不必等退后台或重启 App。
                SharedBridge.writeMirrors()
                authTip = "授权成功，已接入服务器"
                authPositive = true
            } catch {
                authBusy = false
                authTip = error.localizedDescription
                authPositive = false
            }
        }
    }

    /// 清除本机授权令牌；服务器上已同步的配置仍保留
    private func clearAuth() {
        sync.clearToken()
        tokenVersion += 1
        // 清掉 App Group 镜像令牌，避免扩展/CloudOps 继续用旧令牌写服务器
        SharedBridge.writeMirrors()
        authTip = "本机授权令牌已清除（服务器上已同步的配置仍保留）"
        authPositive = false
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
struct ShareProfileView: View {
    @State private var shareName = ""
    @State private var sharePhone = ""
    @State private var savedTip: String?
    @State private var qrImage: UIImage?
    @State private var qrPickerItem: PhotosPickerItem?

    init() {
        let n = KeychainStore.load(KeychainKey.shareName) ?? ""
        let p = KeychainStore.load(KeychainKey.sharePhone) ?? ""
        _shareName = State(initialValue: n)
        _sharePhone = State(initialValue: p)
        if let data = QrcodeStore.loadData() {
            _qrImage = State(initialValue: UIImage(data: data))
        }
    }

    /// 预览用的姓名/电话：输入为空时显示默认值（与分享时行为一致）
    private var previewName: String {
        let n = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "未设置姓名" : n
    }
    private var previewPhone: String {
        let p = sharePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "未设置电话" : p
    }

    /// 二维码只存本机 QrcodeStore，不上传服务器。
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

            Section(header: Text("名片信息"), footer: Text("姓名、电话只保存在本机钥匙串，不上传服务器。分享链接会把这两项放进链接参数，访客打开时由页面直接显示；服务器不保存姓名和电话。修改并保存后，重新复制/分享链接才会带上新名片，旧链接保持原样。")) {
                TextField("姓名（只存本机）", text: $shareName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("电话（只存本机）", text: $sharePhone)
                    .keyboardType(.phonePad)
                Button {
                    saveShareProfile()
                } label: {
                    Text("保存名片信息")
                        .frame(maxWidth: .infinity)
                }
                .disabled(shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 微信二维码只保存在本机，不上传服务器；服务器 H5 不展示二维码。
            Section(header: Text("微信二维码"), footer: Text("二维码只保存在本机，不上传服务器。服务器分享页不展示二维码；需要发二维码时，请在微信里直接发送这张图片。")) {
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
                            syncQRToCloud(clear: false)
                            savedTip = ok ? "微信二维码已保存到本机 ✅" : "保存二维码失败，请重试"
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
                        syncQRToCloud(clear: true)
                        savedTip = "二维码已从本机清除"
                    }
                }
            }
        }
        .navigationTitle("名片信息")
        .navigationBarTitleDisplayMode(.inline)
        // v1.42：返回本页时重新读本地二维码（与分享水印开关同款修法——init 缓存可能陈旧，onAppear 刷新即显示最新）
        // b29：姓名/电话也一起回读。此前只在 init 读一次，导航栈复用页面时 @State 会被重置为空。
        .onAppear {
            let profile = ShareProfileStore.load()
            shareName = profile.name
            sharePhone = profile.phone
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

    /// 姓名/电话只存本机钥匙串，不上传服务器。
    private func syncProfileToCloud(name: String, phone: String) {}

    /// 保存分享名片信息（姓名/电话）到钥匙串
    private func saveShareProfile() {
        let name = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = sharePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            savedTip = "姓名不能为空"
            return
        }
        var ok = ShareProfileStore.save(name: name, phone: phone)
        // 回读校验：保存后立刻从同一钥匙串读取，避免“提示成功但下次进页面为空”的假成功。
        let saved = ShareProfileStore.load()
        if saved.name != name || saved.phone != phone { ok = false }
        // v1.47：保存后同步云端名片（公开选房页实时生效）
        syncProfileToCloud(name: name, phone: phone)
        if ok {
            // 把状态同步成刚落库的值，返回再进也以钥匙串为准
            shareName = saved.name
            sharePhone = saved.phone
        }
        savedTip = ok ? "名片信息已保存 ✅\n姓名：\(name)\n电话：\(phone.isEmpty ? "（未填，分享页不显示电话）" : phone)\n重新复制/分享链接即带上新名片" : "写入本机钥匙串失败，请重新保存一次"
    }
}

// MARK: - v1.47 公开选房链接（发给租客的实时选房 H5）

/// 选房链接页：生成「公开选房 H5」链接（云函数 ?act=rooms&u=<用户名>），
/// 复制/分享给租客即可实时查看所有待租房源；改房源、改名片、换二维码后租客刷新即最新。
struct RoomsShareView: View {
    @State private var serverLink = ""
    @State private var linkTip: String?
    @State private var copiedTip: String?

    /// v1.49：公开选房链接改为 服务器托管链接（与单房分享 H5 同域名同机制，微信内可正常打开）。
    /// 由云函数 roomsSeed 生成静态壳并上传服务器 users/<用户名>/rooms/index.html 后返回；
    /// 壳页面每次打开/刷新 JS 实时拉 rooms_json 数据，房源/名片/二维码变化刷新即最新，无需重建。
    private var link: String { serverLink }

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
                        // b29：直呈系统分享面板，微信扩展才拿得到内容
                        SharePresenter.present(items: [link])
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
            if serverLink.isEmpty {
                Task { await refreshLink() }
            }
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

    /// 选房页由服务器本地托管静态壳，长期有效，房源/名片刷新即最新；旧对象存储 H5 壳上传链路已下线。
    private func refreshLink() async {
        if HouseServerMode.ready {
            if let h5 = HouseRemoteClient.h5URL() {
                serverLink = h5.absoluteString
                linkTip = "链接长期有效；房源、名片或二维码更新后，租客刷新页面即为最新"
            } else {
                serverLink = ""
                linkTip = "尚未接入服务器：请到「云端配置」检查服务器地址或账号绑定"
            }
            return
        }
        serverLink = ""
        linkTip = "尚未接入服务器：请到「云端配置」检查服务器地址或账号绑定"
    }
}
