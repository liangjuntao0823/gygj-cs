import Foundation
import UIKit
import SwiftUI
import Security
import SwiftData
import CryptoKit

/// 房源模块的共享基础类型：
/// 本机钥匙串、分享模式/二维码、媒体命名、水印、用户名与服务器操作日志、服务器房源记录。
/// 这里不包含任何对象存储（COS）配置、签名、上传或桶路径。

/// 分享压缩开关默认开启——未设置过时按开启处理（省流量）
/// v1.80：用户未手动设置时，默认值改读云端远程配置（后台「远程配置」可改，改后 App 同步即生效）
var shareCompressionEnabled: Bool {
    if let v = UserDefaults.standard.object(forKey: "compressOnShare") as? Bool { return v }
    return RemoteConfig.feature("compressUpload", true)
}

/// v1.55：公开选房链接有效期（天）。默认 2 天；可在「设置 → 房源分享」里动态调整（1/2/3/7/15/30 天）。
/// 链接到期后签名失效，租客打开旧链接会提示无法访问，需要重新生成新链接发给租客。
var roomsLinkExpiryDays: Int {
    let d = UserDefaults.standard.integer(forKey: "roomsLinkExpiryDays")
    if d > 0 { return d }
    // v1.80：未设置时默认值读云端远程配置（后台可改，App 同步即生效）
    return Int(RemoteConfig.param("roomsLinkExpiryDays", 2))
}

enum KeychainKey {
    static let shareName = "share.name"
    static let sharePhone = "share.phone"
    static let adminPassword = "cloud.adminPassword"
}

enum KeychainStore {
    private static let service = "com.gj.tg2.housekeeper"

    /// 仅用于定位条目（删除/更新）的精简 query，不含 data/accessible，
    /// 避免额外属性导致 SecItemDelete/Update 匹配不到旧项。
    private static func identityQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    /// v1.20：返回写入结果（true=成功）。此前写入失败被静默吞掉，用户以为保存成功实际没写入。
    /// kSecAttrAccessibleAfterFirstUnlock 提高开机解锁前访问的可靠性
    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        // 先用精简 query 彻底删除同 service+account 的旧项
        SecItemDelete(identityQuery(key) as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem {
            // 旧项极端情况下仍在：改用 Update 真正写入，而不是把 duplicate 当成功
            let updateStatus = SecItemUpdate(
                identityQuery(key) as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                ] as CFDictionary
            )
            return updateStatus == errSecSuccess
        }
        return false
    }

    static func load(_ key: String) -> String? {
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

    /// 真正删除条目；不存在也视为成功（幂等）
    @discardableResult
    static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(identityQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}


enum ShareMode: String {
    case masked = "masked"
    case full = "full"

    /// 分享页固定路径后缀：两个模式独立页面互不覆盖
    var pageSuffix: String {
        switch self {
        case .masked: return "share"
        case .full: return "share-full"
        }
    }

    /// v1.36：文件名/记录用的中文模式标签
    var modeLabel: String {
        switch self {
        case .masked: return "脱敏版"
        case .full: return "完整版"
        }
    }
}

// MARK: - 名片微信二维码（v1.27）

/// 微信二维码存储：设置页「名片信息」上传保存为 Documents/qrcode.png。
/// 二维码只留在本机，不上传服务器、不进入任何分享页面；需要发二维码时直接在微信发送图片。
enum QrcodeStore {
    static let fileName = "qrcode.png"

    static var fileURL: URL {
        DataRoot.url().appendingPathComponent(fileName)
    }

    @discardableResult
    static func save(_ data: Data) -> Bool {
        do {
            try data.write(to: fileURL)
            return true
        } catch {
            return false
        }
    }

    static func loadData() -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 媒体命名 / 格式 / 等价比较（v2.37 #9 #11 集中收口）

/// 媒体文件命名与「同一逻辑文件」的统一口径。所有对账、下载、孤儿清理、上传都只走这里，避免各处自己拼。
///
/// 背景：iPhone 拍的视频本地可能是 .mov（QuickTime），但上传时统一转码成 .mp4，
/// 所以服务器上的视频永远是 .mp4；同一逻辑视频在本地/账本可能叫 .mov、在服务器上叫 .mp4。
/// 图片则不转码、不改名，后缀原样保留。
enum MediaNaming {
    /// 云端对象名：视频统一 .mp4（转码结果），图片/其它保持原名。
    static func cloudName(fileName: String, kind: String) -> String {
        kind == "video" ? ((fileName as NSString).deletingPathExtension) + ".mp4" : fileName
    }

    /// 服务器落盘名：视频统一 `.mp4`（本地文件名可仍是 `.mov`），图片保持原名。
    static func remoteName(fileName: String, kind: String) -> String {
        kind == "video" ? cloudName(fileName: fileName, kind: kind) : fileName
    }

    /// 对账用的「规范键」。
    /// - 视频：.mov / .mp4 统一归一到「同名 .mp4」，正确识别「本地 .mov ↔ 云端 .mp4」本就是同一视频，
    ///   不会再因为两套名字互斥而误判、死循环；
    /// - 图片/其它：保留完整文件名（含后缀，转小写），于是 foo.jpg 与 foo.png、不同 base 名都能区分，不再混为一谈。
    /// 注意：这里只对「视频的转码等价」做归一，不是无脑去后缀；foo.mov 与 foo.mp4 归一是因为架构上它们必然是同一视频。
    static func canonicalKey(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".mov") {
            return ((name as NSString).deletingPathExtension).lowercased() + ".mp4"
        }
        return lower
    }

    /// 从视频数据里识别真实容器格式，返回 "mp4" 或 "mov"（数据不足/无法判断时默认 mp4）。
    /// v2.37（#9）：下载落盘前先看真实格式，按真实格式命名，不再「内容是 mp4 却套个 .mov 后缀」。
    static func videoExtension(for data: Data) -> String {
        guard data.count >= 12 else { return "mp4" }
        func ascii(_ offset: Int, _ length: Int) -> String {
            let end = min(offset + length, data.count)
            return String(decoding: data.subdata(in: offset..<end), as: UTF8.self)
        }
        let atom = ascii(4, 4)
        if atom == "ftyp" {
            // ISO-BMFF：brand == "qt  " 才是 QuickTime；其余（isom/mp42/M4V 等）都是 mp4 家族
            return ascii(8, 4) == "qt  " ? "mov" : "mp4"
        }
        // 无 ftyp 的老式 QuickTime 容器
        if ["moov", "mdat", "wide", "free", "pnot", "skip"].contains(atom) { return "mov" }
        return "mp4"
    }

    /// 从磁盘文件读前 16 字节识别真实视频格式（供本地导入/兜底路径使用）。
    static func videoExtension(forFile url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (url.pathExtension.lowercased() == "mov") ? "mov" : "mp4"
        }
        let head = handle.readData(ofLength: 16)
        try? handle.close()
        return videoExtension(for: head)
    }
}

// MARK: - 分享合集数据结构


struct ShareCollectionItem: Hashable, Codable {
    let roomKey: String
    let displayRoomNo: String
    let towerLabel: String
    let layout: String
    let statusLabel: String
    let priceText: String
    let landlord: String
    let password: String
    let remark: String
    let mediaFiles: [ShareMediaFile]
}

enum WatermarkPosition: String, CaseIterable, Codable {
    case bottomRight, topLeft, topRight, bottomLeft
    var label: String {
        switch self {
        case .bottomRight: return "右下"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        }
    }
}

struct WatermarkSettings: Codable, Equatable {
    var enabled: Bool
    var text: String
    var fontSize: Double
    var opacity: Double
    var position: WatermarkPosition
    var offsetX: Double
    var offsetY: Double

    static let defaultText = "米兰公馆房源"
    static let `default` = WatermarkSettings(enabled: true, text: defaultText, fontSize: 14, opacity: 0.5, position: .bottomRight, offsetX: 12, offsetY: 12)
}

enum WatermarkSettingsStore {
    private static let key = "watermark.settings.v1"
    static var current: WatermarkSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode(WatermarkSettings.self, from: data) else { return .default }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
    /// 清除自定义水印并恢复默认（默认文本 + 默认样式 + 开关恢复开启）
    static func resetToDefault() {
        current = .default
    }
}

// MARK: - v1.36 云函数配置（H5 埋点统计 + 管理后台鉴权）

enum CloudConfig {
    // v1.40：云函数地址不再内置默认值——新装 App 的地址栏为空，由用户自行填写保存。
    // 旧版默认地址仅供升级用户参考（若 UserDefaults 无值且钥匙串有旧值则读取兼容）。
    static var functionURL: String {
        get {
            // v2.68：共享区优先（分享扩展同地址）；兼容 standard 与 v1.39 钥匙串旧值。
            SharedBridge.migrateKey("cloud.functionURL")
            if let s = SharedBridge.defaults.string(forKey: "cloud.functionURL"), !s.isEmpty { return s }
            if let s = UserDefaults.standard.string(forKey: "cloud.functionURL"), !s.isEmpty { return s }
            if let s = KeychainStore.load("cloud.functionURL"), !s.isEmpty { return s }
            // v2.71：扩展镜像未写（覆盖安装后主 App 没启动过）时用默认地址兜底——
            // 否则 CloudOps.isConfigured 判未配置，分享新增/补传的公共日志静默不上云
            if SharedBridge.isExtension { return SharedBridge.fallbackFunctionURL }
            return ""
        }
        set {
            SharedBridge.defaults.set(newValue, forKey: "cloud.functionURL")
            UserDefaults.standard.set(newValue, forKey: "cloud.functionURL")
        }
    }
    static func clearFunctionURL() {
        SharedBridge.defaults.removeObject(forKey: "cloud.functionURL")
        UserDefaults.standard.removeObject(forKey: "cloud.functionURL")
        _ = KeychainStore.save("", for: "cloud.functionURL")
    }
    /// 管理后台口令（网页版登录；App 内免登录直接带哈希）。默认 12345678，可在设置页修改。
    /// v1.40：改存钥匙串——重装 App 后 UserDefaults 清空但钥匙串保留，口令不丢，云端后台不会因口令回默认而 401。
    static var adminPassword: String {
        get {
            if let s = KeychainStore.load(KeychainKey.adminPassword), !s.isEmpty { return s }
            if let s = UserDefaults.standard.string(forKey: "cloud.adminPassword"), !s.isEmpty {
                _ = KeychainStore.save(s, for: KeychainKey.adminPassword)
                return s
            }
            return "12345678"
        }
        set { _ = KeychainStore.save(newValue, for: KeychainKey.adminPassword) }
    }
    static var passwordHash: String {
        // v2.68：扩展进程读不到主 App 钥匙串，用主 App 镜像的哈希（本就随请求 URL 传输，不扩大暴露面）
        if SharedBridge.isExtension { return SharedBridge.mirroredPasswordHash }
        let data = Data(adminPassword.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 用户名 / 设备署名


enum CloudUser {
    private static let key = "cloud.username"
    /// v2.68：用户名改存 App Group 共享区（分享扩展需同用户名署名/分目录）；
    /// 升级时一次性把 standard 旧值迁进共享区，主 App 行为不变。
    static var username: String {
        get {
            SharedBridge.migrateKey(key)
            return SharedBridge.defaults.string(forKey: key) ?? ""
        }
        set { SharedBridge.defaults.set(newValue, forKey: key) }
    }
    /// v2.6：设备短标签（区分同账号多设备）——"iPhone"/"iPad"/"其他"
    static var deviceTag: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
    /// v2.6：带设备标识的署名（用于 updatedBy / 日志）——如 "涛(iPhone)"
    static var signedUsername: String {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未设置(\(deviceTag))" : "\(name)(\(deviceTag))"
    }
    static var displayName: String { username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未设置" : username }
    /// 用户名不设默认（默认空，不预填真实姓名），由用户自行设置。
    /// 返回去首尾空白的用户名；为空返回「未设置」。
    static var safeName: String {
        let t = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未设置" : t
    }

}

// MARK: - 服务器操作记录
// 所有设备对服务器房源库的操作统一记到服务器操作日志，带操作者用户名。
// App 操作日志分「本机操作」（本地）+「云端操作」（服务器记录）。

struct CloudOpEntry: Codable, Identifiable, Hashable {
    var id: String { dbID ?? "\(t)|\(op)|\(room)|\(user)|\(detail)" }
    /// 服务器自增 id（新服务器日志用）；旧云端记录没有该字段时为 nil，删除走复合键兼容。
    let dbID: String?
    let t: String
    let op: String
    let room: String
    let user: String
    let detail: String

    enum CodingKeys: String, CodingKey {
        case dbID = "id", t, op, room, user, detail
    }
}
struct CloudOpsResponse: Codable {
    let ok: Bool
    let records: [CloudOpEntry]
}

// MARK: - v2.67 公共日志待补推队列
/// 公共日志上云失败时落本地 UserDefaults，启动/回前台自动补推；
/// 对齐电脑端「等响应 + 校验结果 + 失败重试」口径，解决老版本 fire-and-forget 静默丢日志。
enum CloudOpPendingQueue {
    struct Item: Codable, Equatable, Hashable {
        let category: String
        let action: String
        let result: String
        let detail: String
        let room: String
        let uname: String
        let date: Date
    }

    private static var pendingKey: String { "cloudOpPending.\(CloudUser.safeName)" }
    private static let maxCount = 100
    private static let retentionDays: Double = 45

    /// v2.68：队列改存 App Group 共享区——分享扩展入队的日志，主 App 启动/回前台同一份补推。
    /// 升级时把 standard 旧队列一次性迁进共享区（只补不覆盖）。
    static func items() -> [Item] {
        SharedBridge.migrateKey(pendingKey)
        guard let data = SharedBridge.defaults.data(forKey: pendingKey),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Item]) {
        if let data = try? JSONEncoder().encode(list) {
            SharedBridge.defaults.set(data, forKey: pendingKey)
        }
    }

    private static func signature(_ item: Item) -> String {
        "\(item.category)·\(item.action)·\(item.result)|\(item.room)|\(item.uname)|\(item.detail)"
    }

    static func enqueue(_ item: Item) {
        var list = items()
        let sig = signature(item)
        guard !list.contains(where: { signature($0) == sig }) else { return }
        list.append(item)
        if list.count > maxCount { list = Array(list.suffix(maxCount)) }
        save(list)
    }

    static func remove(_ item: Item) {
        let sig = signature(item)
        save(items().filter { signature($0) != sig })
    }

    static func flushExpired() {
        let cutoff = Date().addingTimeInterval(-retentionDays * 86400)
        save(items().filter { $0.date >= cutoff })
    }
}

enum CloudOps {
    /// 服务器权威日志：地址与令牌都来自 8082 服务器；不再判断旧对象存储/云函数配置。
    static var isConfigured: Bool {
        !endpoint.isEmpty && !(token ?? "").isEmpty
    }
    /// 服务器地址/令牌走 App Group 镜像，主 App 与分享扩展同一口径；
    /// 不依赖 MeterModels/MeterStore（分享扩展 target 不编译这两个文件）。
    private static var endpoint: String { SharedBridge.mirroredEndpoint }
    private static var token: String? {
        let mirrored = SharedBridge.mirroredHouseToken
        #if APP_EXTENSION
        return mirrored
        #else
        if let m = mirrored, !m.isEmpty { return m }
        // 与电表/房源共用同一枚账号令牌：`MeterCloudSync.persistedToken()` 是唯一权威读取口，
        // 依次覆盖钥匙串与本机兜底文件，避免 CloudOps 自己读文件时漏掉 ad-hoc 环境。
        return MeterCloudSync.persistedToken()
        #endif
    }
    private static var apiURL: URL? {
        var base = endpoint
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/api/house/ops")
    }

    /// 本机发起云端操作 → 写一条服务器操作日志（带当前用户名）。
    /// 失败入待补队列，启动/回前台自动补推，避免 fire-and-forget 静默丢日志。
    static func log(category: String, action: String, result: String, detail: String, room: String = "") {
        // 先入共享待补队，再尝试发送：即使此刻令牌/网络未就绪，也不会静默丢日志；
        // 用户绑定服务器或回前台后 flushPending 会补写，与分享扩展同一口径。
        let item = CloudOpPendingQueue.Item(
            category: category, action: action, result: result,
            detail: detail, room: room, uname: CloudUser.username, date: Date())
        CloudOpPendingQueue.enqueue(item)
        guard isConfigured, apiURL != nil else { return }
        Task.detached {
            let ok = await CloudOps.send(item)
            if ok { CloudOpPendingQueue.remove(item) }
        }
    }

    /// 发送单条日志，最多 3 次尝试（首次 + 2 次退避）；返回是否最终写入服务器。
    @discardableResult
    static func send(_ item: CloudOpPendingQueue.Item) async -> Bool {
        guard isConfigured, let url = apiURL, let token, !token.isEmpty else { return false }
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(350 * attempt) * 1_000_000_000)
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "category": item.category, "action": item.action,
                "result": item.result, "detail": item.detail,
                "room": item.room, "operator": item.uname,
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, !ok { continue }
                return true
            } catch {
                continue
            }
        }
        return false
    }

    /// 分享扩展可靠版：先入共享区待补队再发送，成功才出队。
    static func logAwait(category: String, action: String, result: String, detail: String = "", room: String = "") async {
        let item = CloudOpPendingQueue.Item(
            category: category, action: action, result: result,
            detail: detail, room: room, uname: CloudUser.username, date: Date())
        CloudOpPendingQueue.enqueue(item)
        guard isConfigured, apiURL != nil else { return }
        let ok = await send(item)
        if ok { CloudOpPendingQueue.remove(item) }
    }

    /// 启动/回前台补推积压日志；成功出队，仍失败留队等下次。
    static func flushPending() async {
        CloudOpPendingQueue.flushExpired()
        guard isConfigured else { return }
        for item in CloudOpPendingQueue.items() {
            let ok = await CloudOps.send(item)
            if ok { CloudOpPendingQueue.remove(item) }
        }
    }

    /// 拉取服务器操作记录（日志查看器云端区）。
    static func fetch(completion: @escaping ([CloudOpEntry]) -> Void) {
        guard isConfigured, let apiURL, let token, !token.isEmpty else { completion([]); return }
        var comps = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "limit", value: "200")]
        guard let url = comps?.url else { completion([]); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = try? JSONDecoder().decode(CloudOpsResponse.self, from: data),
                  obj.ok else { completion([]); return }
            completion(obj.records)
        }.resume()
    }

    /// 删除一条服务器操作记录；优先按服务器自增 id 删，旧记录回退复合键。
    static func delete(_ e: CloudOpEntry, completion: (() -> Void)? = nil) {
        guard isConfigured, let apiURL, let token, !token.isEmpty else { completion?(); return }
        var comps = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        if let dbID = e.dbID, !dbID.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "id", value: dbID)]
        } else {
            comps?.queryItems = [
                URLQueryItem(name: "t", value: e.t),
                URLQueryItem(name: "op", value: e.op),
                URLQueryItem(name: "room", value: e.room),
                URLQueryItem(name: "user", value: e.user),
                URLQueryItem(name: "detail", value: e.detail),
            ]
        }
        guard let url = comps?.url else { completion?(); return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.async { completion?() }
        }.resume()
    }
}

// MARK: - v1.19 云端房源账本（共享房源的结构化数据）

/// 房源「账本」单条：只含结构化字段 + 媒体文件名清单；媒体文件仍存 h/<roomKey>/<name>。
/// 多台设备共享这一份账本（最后写入优先，不搞冲突合并）。
struct CloudHouseRecord: Codable, Identifiable {
    var id: String { roomKey }
    var roomKey: String
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var status: String
    var updatedAt: Date
    var updatedBy: String
    var mediaNames: [String]
    /// v2.6：单调递增修订号（每次成功写 +1），旧记录无此字段时为 nil（按 0 处理）
    var revision: Int64?
}

/// 云端房源账本读写（v1.71 方案 A）：一房一文件——每套房在 h/<房号>/info.json 存自己的记录，
/// 与媒体同目录；不再有 h/_houses.json 汇总文件。任何失败由调用方 try? 静默处理。
/// 相比旧「单文件全量读改写」：修改一套只写一套（消灭写放大）；不同套房各写各的文件
/// （并发互不覆盖，根治此前实测的「删 7 套账本残留 3 套」）；删除整套 = 删 h/<房号>/ 目录一步到位。
/// v1.42 语义保持：云端对象不存在（HTTP 404）与「读失败（网络/服务异常）」必须严格区分，
/// 读失败绝不能被当成「云端没有房源」而误删本地。
