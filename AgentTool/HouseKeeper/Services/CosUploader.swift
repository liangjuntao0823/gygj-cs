import Foundation
import SwiftData
import CryptoKit
import Security
import UIKit
import AVFoundation
import CoreImage
import SwiftUI
import WebKit

/// 线程安全的取消标志：后台线程（DispatchQueue）里无法直接读 Task.isCancelled，
/// 由 withTaskCancellationHandler 的 onCancel 置位，转码循环轮询它来中断。
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

// MARK: - v2.52 上传超时与看门狗

/// 统一的 COS 网络会话：请求级 30 秒无数据即失败、资源级 180 秒整体封顶，
/// 解决弱网下 URLSession.shared 默认配置「进度条长时间不动、几分钟才报错」的问题。
enum CosNetwork {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg)
    }()

    /// 带 delegate 的同配置会话（字节级进度上传需要自己的 delegate）
    static func makeSession(delegate: URLSessionDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    /// 整体看门狗：超过 seconds 未完成直接抛错，不再无限等待转码/上传
    static func run<T>(seconds: TimeInterval,
                       _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CosUploader.CosError.uploadFailed("操作超时（\(Int(seconds)) 秒），已挂到任务中心，可点重试")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - 钥匙串存取（COS 密钥等敏感配置）

/// v1.3：分享压缩开关默认开启——未设置过时按开启处理（省流量、省 COS 费用）
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
    static let bucket = "cos.bucket"
    static let region = "cos.region"
    static let secretId = "cos.secretId"
    static let secretKey = "cos.secretKey"
    static let customDomain = "cos.customDomain"   // v1.19：自定义域名（可空），空 = 用 COS 默认域名
    static let shareName = "share.name"            // v1.21：分享名片-姓名（可空，空 = 梁涛）
    static let sharePhone = "share.phone"          // v1.21：分享名片-电话（可空，空 = 13288251132）
    static let adminPassword = "cloud.adminPassword"  // v1.40：后台口令改存钥匙串（重装 App 不丢，避免云端后台 401）
}

enum KeychainStore {
    private static let service = "com.zfgj.housekeeper"

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

// MARK: - COS 配置

struct CosConfig {
    let bucket: String
    let region: String
    let secretId: String
    let secretKey: String
    let customDomain: String   // v1.19：自定义域名（如 cdn.example.com），空 = 用默认域名
    /// 临时凭证（STS）会话令牌；永久密钥场景为空串。非空时预签名会带上
    /// x-cos-security-token 并参与签名，secretId/secretKey 此时为临时密钥。
    let sessionToken: String = ""

    var isUsingSTS: Bool { !sessionToken.isEmpty }

    var isValid: Bool {
        !bucket.isEmpty && !region.isEmpty && !secretId.isEmpty && !secretKey.isEmpty
    }

    /// 从服务器签发的临时凭证构造（媒体上传专用；App 不持久化任何永久密钥）
    static func sts(_ c: HouseCosCredential) -> CosConfig {
        CosConfig(bucket: c.bucket, region: c.region, secretId: c.secretId,
                  secretKey: c.secretKey, customDomain: "",
                  sessionToken: c.sessionToken)
    }

    /// 从钥匙串读取配置（自动去掉首尾空格，避免复制粘贴带入空白导致签名失败）
    static func load() -> CosConfig? {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let bucket = (KeychainStore.load(KeychainKey.bucket) ?? "").trimmingCharacters(in: trimSet)
        let region = (KeychainStore.load(KeychainKey.region) ?? "").trimmingCharacters(in: trimSet)
        let secretId = (KeychainStore.load(KeychainKey.secretId) ?? "").trimmingCharacters(in: trimSet)
        let secretKey = (KeychainStore.load(KeychainKey.secretKey) ?? "").trimmingCharacters(in: trimSet)
        let customDomain = (KeychainStore.load(KeychainKey.customDomain) ?? "").trimmingCharacters(in: trimSet)
        let config = CosConfig(bucket: bucket, region: region, secretId: secretId, secretKey: secretKey, customDomain: customDomain)
        if config.isValid { return config }
        // v2.68：扩展进程读不到主 App 钥匙串——用云函数取回、仅内存持有的配置
        return extensionConfig
    }

    /// v2.68：分享扩展内存态 COS 配置（cosCfg 取回后赋值；绝不写钥匙串/UserDefaults/文件）
    static var extensionConfig: CosConfig?

    /// v2.68：分享扩展经云函数 cosCfg 取 COS 配置（k=hash 门禁，与后台同级信任）。
    /// 密钥只在本进程内存停留，扩展退出即释放；客户端签名/传输代码零改动复用。
    static func fetchForExtension() async throws -> CosConfig {
        if let cached = extensionConfig, cached.isValid { return cached }
        var base = CloudConfig.functionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // v2.70：镜像未写（覆盖安装后主 App 没启动过）时用默认地址兜底，不再阻塞分享
        if base.isEmpty { base = SharedBridge.fallbackFunctionURL }
        let hash = SharedBridge.mirroredPasswordHash
        guard !base.isEmpty, !hash.isEmpty,
              var comp = URLComponents(string: base) else {
            throw CosUploader.CosError.uploadFailed("分享配置未就绪：请先打开一次公寓管家并完成云端配置")
        }
        comp.queryItems = [.init(name: "act", value: "cosCfg"), .init(name: "k", value: hash)]
        guard let url = comp.url else {
            throw CosUploader.CosError.uploadFailed("云函数地址无效")
        }
        let (data, response) = try await CosNetwork.session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CosUploader.CosError.uploadFailed("取分享配置失败（口令或网络问题）")
        }
        struct Resp: Codable {
            let ok: Bool
            let bucket: String?
            let region: String?
            let secretId: String?
            let secretKey: String?
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        let trimSet = CharacterSet.whitespacesAndNewlines
        let bucket = (r.bucket ?? "").trimmingCharacters(in: trimSet)
        let region = (r.region ?? "").trimmingCharacters(in: trimSet)
        let sid = (r.secretId ?? "").trimmingCharacters(in: trimSet)
        let skey = (r.secretKey ?? "").trimmingCharacters(in: trimSet)
        guard r.ok, !bucket.isEmpty, !region.isEmpty, !sid.isEmpty, !skey.isEmpty else {
            throw CosUploader.CosError.uploadFailed("分享配置响应无效")
        }
        let cfg = CosConfig(bucket: bucket, region: region, secretId: sid, secretKey: skey,
                            customDomain: SharedBridge.mirroredCustomDomain)
        extensionConfig = cfg
        return cfg
    }
}

// MARK: - 分享模式（v1.21：脱敏 / 完整 双模板、双缓存、双链接）

/// masked = 脱敏版（发给找房客户）：只显示户型 + 位置导航 + 实拍 + 名片，隐藏房号/价格/房东
/// full   = 完整版（发给同事）：显示房号/房东/价格/密码/户型/备注全部信息
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

/// 微信二维码存储：设置页「名片信息」上传保存为 Documents/备份/qrcode.png（v1.30 随数据一起进「备份」子文件夹）。
/// 分享时若已设置二维码，统一压缩后上传 COS 固定路径 h/_qrcode/qr.jpg（覆盖写），
/// 所有 H5 名片板块用该固定路径的签名 URL 引用——二维码更换后，
/// 之前已发出的分享链接会自动显示新二维码（路径不变，读取的是当前对象内容），无需重新分享。
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
/// 背景（实测桶数据）：iPhone 拍的视频本地可能是 .mov（QuickTime），但上传时统一转码成 .mp4，
/// 所以**云端 h/ 里的视频永远是 .mp4**；同一逻辑视频在本地/账本可能叫 .mov、在桶里叫 .mp4。
/// 图片则不转码、不改名，后缀原样保留。
enum MediaNaming {
    /// 云端对象名：视频统一 .mp4（转码结果），图片/其它保持原名。
    static func cloudName(fileName: String, kind: String) -> String {
        kind == "video" ? ((fileName as NSString).deletingPathExtension) + ".mp4" : fileName
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

// MARK: - 腾讯云 COS V5 预签名上传（HMAC-SHA1，零第三方依赖）

enum CosUploader {

    /// 分享链接有效期：永久（10 年，COS 预签名 URL 上限内足够长，视为长期有效）
    static let shareLinkExpires: Int = 3650 * 86400

    /// v1.25：HTML 模板版本号。每次修改 H5 页面模板（buildMaskedHTML / buildFullHTML / buildCollectionHTML /
    /// mediaBlockHTML 等）后必须 +1——缓存校验会比对模板版本，版本变了旧缓存自动失效，
    /// 下次分享自动重新生成并上传新页面，无需任何手动操作。
    /// 这就解决了「改了网页设计但房源信息没变化、缓存命中还是旧链接」的问题。
    /// v1.27：名片板块改版（二维码 + 新底色）→ 2→3；且二维码是否存在也纳入缓存校验（qrcodeSet），
    /// 用户设置/清除二维码后旧缓存自动失效重新生成页面。
    /// v1.28：二维码下方新增「长按二维码加我好友」小字提示 → 3→4
    /// v1.29：视频统一转 mp4 上传（安卓/微信可播），云端视频路径改 .mp4 → 4→5，旧缓存全部失效重传
    static let htmlTemplateVersion = 5

    enum CosError: LocalizedError {
        case invalidConfig
        case missingMedia
        case customDomainMissing      // v1.20：未填自定义域名，微信无法渲染卡片
        case uploadFailed(String)
        case responseInvalid

        var errorDescription: String? {
            switch self {
            case .invalidConfig:
                return "云存储配置不完整，请先在设置页填写并保存验证"
            case .missingMedia:
                return "这套房源还没有照片或视频，先编辑添加素材再分享"
            case .customDomainMissing:
                return "未填写自定义域名，分享链接会被微信识别成文件而不是卡片。请到设置页把自定义域名填入「自定义域名」栏并保存"
            case .uploadFailed(let msg):
                return "上传失败：" + msg
            case .responseInvalid:
                return "上传服务返回异常，请稍后重试"
            }
        }
    }

    /// 为房源生成 H5 分享卡片（v1.21：按 mode 生成脱敏版 / 完整版，各自独立页面、独立缓存、独立链接）
    /// - v1.17：og 标签 / 媒体 src 全部用绝对签名 URL（10 年有效），微信能抓到封面渲染成卡片
    /// - v1.18：分享页路径改为【无扩展名】h/<roomKey>/share（微信不再按 index.html 文件识别）；
    ///   同一房源媒体与信息未变化时【零上传】直接复用上次链接；只新增媒体/只改信息时仅上传增量
    /// - v1.19（方案 A 准备）：①支持【自定义域名】；②og:image 改用【压缩封面】cover（最长边 400px）；③链接追加版本参数 v
    /// - v1.20：①分享前强制校验自定义域名已填；②host 自动剥离用户误填的 https:// 前缀与尾部斜杠
    /// - v1.21：①分享模式双轨（脱敏/完整），模板按设计稿定稿（隐藏版/完整版）；
    ///   ②缓存按模式分文件（_masked / _full），互不影响、各自增量；升级后脱敏版兼容旧单文件缓存；
    ///   ③媒体排序视频置顶、图片单列（模板要求）；④名片姓名/电话来自设置页（可编辑）；
    ///   ⑤图片改 CSS 背景图渲染 + 全局禁右键/禁长按选择，视频 controlsList=nodownload（防保存下载）
    /// - v1.22：①微信卡片描述：名字电话放在最底下一行（脱敏=位置行+名片行，完整=信息行+名片行）；
    ///   ②完整版信息板块重排：第一行房号+户型、第二行租金+密码（密码：xxx）+房东（最右）、第三行备注；
    ///   ③H5 图片点击放大后支持左右滑动切换上一张/下一张；④视频不自动播放（点击才播，preload=none）；
    ///   ⑤户型标题去重（户型已含「上/下」时不再重复拼接房号后缀）
    /// 入参全部为值类型（ShareMediaFile / ShareHouseInfo），Task 内不触碰 SwiftData 模型，避免跨线程访问闪退
    /// v1.13 需求13：progress 回调（0~1），按「需上传媒体数 + 固定任务」估算总进度；缓存命中复用链接时直接回调 1.0
    /// v2.57（P2-11）：分享缓存命中判断——关键渲染参数（桶/域名/压缩/模板/二维码/水印）
    /// + 媒体清单一致（名字+类型+顺序）+ 房源信息一致（字段级等值比对，等价于信息哈希但更严格）
    /// 全部成立才算命中；命中直接复用上次链接，零上传零页面生成。
    /// shareCard 与 autoRegenerateMaskedShare 共用同一判断，避免两处条件漂移。
    static func shareCacheHitURL(mediaFiles: [ShareMediaFile], roomKey: String, mode: ShareMode, info: ShareHouseInfo, config: CosConfig) async -> URL? {
        let compressOnShare = shareCompressionEnabled
        let hasQR = QrcodeStore.exists()
        guard let cached = ShareCacheStore.load(roomKey: roomKey, mode: mode.rawValue),
              cached.bucket == config.bucket,
              cached.region == config.region,
              (cached.customDomain ?? "") == config.customDomain,
              (cached.compressOnShare ?? false) == compressOnShare,
              (cached.templateVersion ?? 0) == htmlTemplateVersion,
              (cached.qrcodeSet ?? false) == hasQR,
              (cached.watermarkHash ?? "") == watermarkHash(WatermarkSettingsStore.current),
              cached.mediaFiles == mediaFiles,
              cached.info == info,
              let cachedURL = URL(string: cached.shareURL) else { return nil }
        // v2.58（#6）：参数一致还不够——页面对象可能已被删（桶清理/换账号/手动清桶），
        // 命中前 HEAD 一次：200 复用；404 清掉本地缓存、走重建；网络/签名异常（nil）保留旧链接，离线不误删。
        let pagePath = "\(CloudUser.sharePagePrefix)\(roomKey)/\(cachedURL.lastPathComponent)"
        switch await sharePageExists(path: pagePath, config: config) {
        case .some(true):
            return cachedURL
        case .some(false):
            ShareCacheStore.remove(roomKey: roomKey, mode: mode.rawValue)
            return nil
        case .none:
            return cachedURL
        }
    }

    /// v2.58（#6）：HEAD 分享页对象。返回 nil 表示「无法判断」（网络/签名异常），
    /// 调用方应保留缓存而不是误当 404 重建。
    static func sharePageExists(path: String, config: CosConfig) async -> Bool? {
        guard let url = try? presignedURL(for: path, method: "HEAD", expires: 300, headers: [], config: config) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await CosNetwork.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if (200...299).contains(http.statusCode) { return true }
            if http.statusCode == 404 { return false }
            return nil
        } catch {
            return nil
        }
    }

    static func shareCard(mediaFiles: [ShareMediaFile], roomKey: String, info: ShareHouseInfo, mode: ShareMode, config: CosConfig, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard !mediaFiles.isEmpty else { throw CosError.missingMedia }
        // v1.20：微信渲染卡片必须走自定义域名；没填就不生成链接，直接告诉用户去哪填
        guard !config.customDomain.isEmpty else { throw CosError.customDomainMissing }

        // 0. 缓存命中（按模式）：v1.40 第7点简化——用户私有目录里已有缓存且关键渲染参数
        //    （桶/域名/压缩开关/模板版本/二维码/水印）未变 → 直接复用上次链接，零上传；
        //    不再逐项比对媒体清单与房源信息（媒体新增走下方增量上传；信息变化只重生成页面，不重复传媒体）
        //    v2.57（P2-11）：补上「媒体清单一致 + 房源信息一致」两条硬比对——参数没变但媒体/信息变了
        //    时必须重新生成页面（旧逻辑会误命中返回过时链接）；autoRegenerateMaskedShare 也复用同一判断。
        let compressOnShare = shareCompressionEnabled
        let hasQR = QrcodeStore.exists()
        if let cachedURL = await shareCacheHitURL(mediaFiles: mediaFiles, roomKey: roomKey, mode: mode, info: info, config: config) {
            progress?(1.0)
            return cachedURL
        }

        // 1. 确定需上传的媒体：桶/地域未变时只上传新增媒体（媒体对象与信息无关，信息变化只重生成页面与链接）
        var toUpload = mediaFiles
        if let cached = ShareCacheStore.load(roomKey: roomKey, mode: mode.rawValue),
           cached.bucket == config.bucket,
           cached.region == config.region,
           (cached.compressOnShare ?? false) == compressOnShare {
            let cachedSet = Set(cached.mediaFiles)
            toUpload = mediaFiles.filter { !cachedSet.contains($0) }
        }

        // v1.13 需求13：进度按「需上传任务数」估算——媒体（每项含压缩+上传+可能缩略图）1 项 + 封面 1 项 + 二维码 1 项 + 页面 1 项
        let totalTasks = max(1, toUpload.count + (mediaFiles.contains { $0.kind == "image" } ? 1 : 0) + (hasQR ? 1 : 0) + 1)
        var completedTasks = 0
        func reportProgress(_ taskFraction: Double) {
            progress?(min(Double(completedTasks) + taskFraction, Double(totalTasks)) / Double(totalTasks))
        }

        // 2. 媒体排序（v1.21 模板要求）：视频置顶第一位、图片在后
        let ordered = mediaFiles.sorted { lhs, rhs in
            let l = lhs.kind == "video" ? 0 : 1
            let r = rhs.kind == "video" ? 0 : 1
            return l < r
        }

        // 3. 上传新增媒体并生成绝对 GET 签名 URL；视频生成封面播放器（封面用独立首帧图），图片收集 URL 待模板渲染（img 渲染）
        // v1.23：开启「分享时压缩」开关 → 视频压到 720p（H.264 mp4）、图片轻压缩（长边≤1600 JPEG q0.8）后再上传
        // v1.25：视频封面改为独立首帧图（vthumb.jpg）——封面不再用视频 URL 当背景图，彻底避免微信预取视频流；
        //   video 标签无 src 无 poster，微信绝无自动播放的可能，只有点击封面才注入 src 播放
        // v1.40 第2点：上传前先探测桶内是否已有该媒体（HEAD），已有则跳过上传直接引用——换机/清缓存后不再重复覆盖桶内原文件
        // v1.40 第6点：H5 页面/封面/视频首帧图/二维码全部改到用户私有目录 users/<用户名>/，只有房源原始媒体留在共享区 h/<房号>/
        await MediaActivityGate.shared.beginUpload()
        defer { Task { await MediaActivityGate.shared.endUpload() } }
        var videoTags: [String] = []
        var imageAbsURLs: [String] = []
        for item in ordered {
            // v1.29：视频云端路径统一用 .mp4（安卓/微信可播）。本地保留原文件，上传/引用的是 mp4
            let isVideo = item.kind == "video"
            let remoteName = isVideo ? cloudVideoName(for: item.name) : item.name
            let remotePath = "h/\(roomKey)/\(remoteName)"
            if toUpload.contains(item) {
                // v1.40：桶内已存在同一对象 → 跳过上传（复用），不重复覆盖
                if await remoteObjectExists(path: remotePath, config: config) == false {
                    let url = MediaStore.url(for: item.name, roomKey: roomKey)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    var data = try Data(contentsOf: url)
                    var contentType = mimeType(for: item.kind, name: remoteName)
                    if isVideo {
                        // v1.29：无论压缩开关，视频一律转 mp4 上传——安卓微信对 .mov/QuickTime 容器支持差，
                        // mp4（H.264+AAC）iOS/安卓通吃；压缩开关开 → 720p，关 → 原质量转封装（不重编码，秒级）
                        // 转码失败必须抛错：否则原始 mov 字节会以 .mp4 文件名直传，产出微信打不开的假 mp4
                        guard let mp4 = await uploadVideoData(from: url, compress: compressOnShare) else {
                            throw CosError.uploadFailed("视频转码 MP4 失败：\(item.name)")
                        }
                        data = mp4
                        contentType = "video/mp4"
                    } else if compressOnShare, let compressed = compressedImageData(from: url) {
                        data = compressed
                        contentType = "image/jpeg"
                    }
                    do {
                        try await uploadWithProgress(data: data, to: remotePath, contentType: contentType, config: config) { p in
                            // 媒体项自身进度占 1 个任务
                            reportProgress(Double(p))
                        }
                    } catch {
                        // v1.40 第5点：上传失败入队，App 启动/回前台自动补传
                        HouseMediaUploadQueue.enqueue(roomKey: roomKey, fileName: item.name, kind: item.kind)
                        throw error
                    }
                }
                completedTasks += 1
            }
            // v1.25/v1.40：视频首帧封面图——路径改用户私有目录。
            // v2.57（P2-11）：改为先 HEAD 桶内是否已有该缩略图，已有则跳过重新生成与上传
            // （旧逻辑每次重新生成上传，同一套房反复分享/重生成会白白重复传缩略图；
            // 媒体对象换内容会换新文件名，缩略图跟随媒体名走，不会出现旧图配新视频）。
            if isVideo {
                let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(roomKey)/\(item.name).vthumb.jpg"
                if await remoteObjectExists(path: thumbRemotePath, config: config) == false {
                    let localURL = MediaStore.url(for: item.name, roomKey: roomKey)
                    if FileManager.default.fileExists(atPath: localURL.path),
                       let thumbData = makeVideoThumbJPEG(from: localURL) {
                        try? await upload(data: thumbData, to: thumbRemotePath, contentType: "image/jpeg", config: config)
                    }
                }
            }
            let absURL = try presignedGetURL(for: remotePath, expires: shareLinkExpires, config: config).absoluteString
            if isVideo {
                // v1.25：video 无 src、无 poster、无 autoplay；封面用独立首帧图；点击封面 playVideo 才注入 src 并播放
                let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(roomKey)/\(item.name).vthumb.jpg"
                let thumbURL = (try? presignedGetURL(for: thumbRemotePath, expires: shareLinkExpires, config: config).absoluteString) ?? absURL
                videoTags.append("<div class=\"vwrap\" onclick=\"playVideo(this,'\(absURL)')\"><div class=\"vthumb\" style=\"background-image:url('\(thumbURL)')\"></div><div class=\"vplay\">▶</div><video class=\"v\" controls controlsList=\"nodownload\" disablepictureinpicture playsinline webkit-playsinline preload=\"none\"></video></div>")
            } else {
                imageAbsURLs.append(absURL)
            }
        }
        guard !videoTags.isEmpty || !imageAbsURLs.isEmpty else { throw CosError.missingMedia }

        // 4. 压缩封面（v1.19）：第一张照片压缩成最长边 400px JPEG 上传为 h/<roomKey>/cover（两模式共用）
        // v1.40 第6点：封面改存用户私有目录 users/<用户名>/shares/<房号>/cover（仅自己页面引用，微信 og:image 用签名 URL）
        var coverSrc = imageAbsURLs.first ?? ""
        if let firstImage = mediaFiles.first(where: { $0.kind == "image" }),
           let coverData = makeCoverJPEG(from: MediaStore.url(for: firstImage.name, roomKey: roomKey)) {
            let coverPath = "\(CloudUser.sharePagePrefix)\(roomKey)/cover"
            do {
                try await uploadWithProgress(data: coverData, to: coverPath, contentType: "image/jpeg", config: config) { p in
                    reportProgress(Double(p))
                }
                coverSrc = try presignedGetURL(for: coverPath, expires: shareLinkExpires, config: config).absoluteString
            } catch {
                // 封面失败不阻塞：沿用第一张原图
            }
            completedTasks += 1
        }

        // 4.1 名片微信二维码（v1.27）：设置页已上传时，压成小图覆盖写到用户私有目录 users/<用户名>/qrcode.jpg；
        //     v1.40 第6点：从公共 h/_qrcode/qr.jpg 迁移到用户目录，避免其他用户读到自己的二维码
        var qrSrc = ""
        if hasQR, let qrData = makeQRCodeJPEG() {
            try? await uploadWithProgress(data: qrData, to: CloudUser.qrPath, contentType: "image/jpeg", config: config) { p in
                reportProgress(Double(p))
            }
            qrSrc = (try? presignedGetURL(for: CloudUser.qrPath, expires: shareLinkExpires, config: config).absoluteString) ?? ""
            completedTasks += 1
        }

        // 5. 生成并上传分享页。v1.36：文件名=房号+模式+日期时间（空 app 无存量链接，直接换新命名）。
        //    链接追加版本参数 v（内容更新 → v 变 → 微信重新抓卡片）
        //    v1.40 第6点：页面改存用户私有目录 users/<用户名>/shares/<房号>/
        let wm = Self.watermarkOverlayHTML(WatermarkSettingsStore.current)
        let pagePath = "\(CloudUser.sharePagePrefix)\(roomKey)/\(Self.safeFileName(info.displayRoomNo))_\(mode.modeLabel)_\(Self.shareTimeTag()).html"
        let shareURL = try presignedGetURL(for: pagePath, expires: shareLinkExpires, config: config)
        let versionedURL = appendVersionParameter(shareURL, version: "\(Int(Date().timeIntervalSince1970))")

        // 名片姓名/电话：优先取设置页保存值（调用方已填入 info），缺失/旧版缓存时回退默认值
        let name = (info.name ?? "").isEmpty ? "梁涛" : info.name!
        let phone = (info.phone ?? "").isEmpty ? "13288251132" : info.phone!

        let html: String
        switch mode {
        case .masked:
            // 微信卡片：标题=户型（突出）；描述=位置行 + 名字电话行（最底下一行）
            let title = layoutTitle(info.layout, roomNo: info.displayRoomNo)
            let desc = "利保米兰公馆\n\(name)-\(phone)"
            html = buildMaskedHTML(
                title: title, desc: desc,
                name: name, phone: phone,
                videoTags: videoTags, imageURLs: imageAbsURLs,
                coverSrc: coverSrc, qrSrc: qrSrc, shareLink: versionedURL.absoluteString,
                wm: wm, trackScript: Self.cloudTrackScript(room: info.displayRoomNo, mode: mode.modeLabel)
            )
        case .full:
            let title = "\(info.displayRoomNo) · \(info.layout.isEmpty ? "房源" : info.layout)"
            let desc = "\(info.priceText) · \(info.landlord.isEmpty ? "房东信息见页内" : info.landlord)\n\(name)-\(phone)"
            html = buildFullHTML(
                title: title, desc: desc,
                info: info, name: name, phone: phone,
                videoTags: videoTags, imageURLs: imageAbsURLs,
                coverSrc: coverSrc, qrSrc: qrSrc, shareLink: versionedURL.absoluteString,
                wm: wm, trackScript: Self.cloudTrackScript(room: info.displayRoomNo, mode: mode.modeLabel)
            )
        }
        try await uploadWithProgress(data: Data(html.utf8), to: pagePath, contentType: "text/html; charset=utf-8", config: config) { p in
            // 页面是最后一项：占剩余任务
            reportProgress(Double(p))
        }
        completedTasks += 1
        progress?(1.0)

        // 6. 更新缓存（按模式分文件；含自定义域名、压缩开关、模板版本与水印哈希，任一变化后旧缓存自动失效）
        ShareCacheStore.save(roomKey: roomKey, mode: mode.rawValue, record: ShareCacheRecord(
            mediaFiles: mediaFiles,
            info: info,
            shareURL: versionedURL.absoluteString,
            bucket: config.bucket,
            region: config.region,
            customDomain: config.customDomain,
            compressOnShare: compressOnShare,
            templateVersion: htmlTemplateVersion,
            qrcodeSet: hasQR,
            watermarkHash: Self.watermarkHash(WatermarkSettingsStore.current)
        ))

        // v1.36：分享记录云端化——异步写桶内分享记录索引（失败不阻塞分享主流程）
        Task {
            try? await Self.appendShareRecord(roomKey: roomKey, displayRoomNo: info.displayRoomNo, mode: mode, url: versionedURL.absoluteString, config: config)
        }

        return versionedURL
    }

    /// v1.22：多选分享 → 生成【合集 H5 卡片】。一次分享一个链接，好友点开看到 N 套房源列表，
    /// 点某套进入该套详情（视频置顶、图片单列、名片底部）。脱敏/完整两模式各自独立合集页面与缓存。
    /// 缓存：媒体+信息+配置全同 → 零上传复用上次链接；否则全量上传覆盖写（与单套共享媒体对象路径）。
    /// v1.13 需求13：progress 回调（0~1），按「所有套的需上传媒体数 + 固定任务」估算总进度
    static func shareCollection(rooms: [ShareCollectionItem], mode: ShareMode, config: CosConfig, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard !config.customDomain.isEmpty else { throw CosError.customDomainMissing }
        let validRooms = rooms.filter { !$0.mediaFiles.isEmpty }
        guard !validRooms.isEmpty else { throw CosError.missingMedia }
        let profile = loadShareProfile()
        let name = profile.name
        let phone = profile.phone

        // 0. 集合缓存键：模式 + 房号排序拼接（房号变化 → 键变化 → 自动新链接）
        // v1.23：压缩开关纳入缓存校验——开关变化 → 合集重新压缩上传
        // v1.25：①模板版本纳入校验——模板改动 → 旧合集缓存自动失效重新生成；
        //   ②合集房源比较改为【顺序无关】（Set）——多选点选顺序变化不再误判为变化导致重传
        // v1.27：二维码是否存在（qrcodeSet）纳入校验——设置/清除二维码后旧合集缓存自动失效
        let compressOnShare = shareCompressionEnabled
        let hasQR = QrcodeStore.exists()
        let sortedKeys = validRooms.map { $0.roomKey }.sorted().joined(separator: "_")
        let cacheKey = "collection_\(sortedKeys)"
        let cacheMode = "collection-\(mode.rawValue)"
        if let cached = ShareCacheStore.load(roomKey: cacheKey, mode: cacheMode),
           cached.bucket == config.bucket,
           cached.region == config.region,
           (cached.customDomain ?? "") == config.customDomain,
           (cached.compressOnShare ?? false) == compressOnShare,
           (cached.templateVersion ?? 0) == htmlTemplateVersion,
           (cached.qrcodeSet ?? false) == hasQR,
           (cached.watermarkHash ?? "") == Self.watermarkHash(WatermarkSettingsStore.current),
           cached.info.name == name,
           cached.info.phone == phone,
           Set(cached.collectionRooms ?? []) == Set(validRooms),
           let url = URL(string: cached.shareURL) {
            progress?(1.0)
            return url
        }

        // v1.13 需求13：进度按「所有套的需上传媒体数 + 每套封面 + 二维码 + 页面」估算总任务数
        let mediaTaskCount = validRooms.reduce(0) { $0 + $1.mediaFiles.count }
        let coverTaskCount = validRooms.filter { $0.mediaFiles.contains { $0.kind == "image" } }.count
        let totalTasks = max(1, mediaTaskCount + coverTaskCount + (hasQR ? 1 : 0) + 1)
        var completedTasks = 0
        func reportProgress(_ taskFraction: Double) {
            progress?(min(Double(completedTasks) + taskFraction, Double(totalTasks)) / Double(totalTasks))
        }

        // 1. 上传每套媒体（覆盖写，与单套分享共享 h/<roomKey>/<name> 路径）+ 每套封面
        // v1.40 第2点：上传前先探测桶内是否已有该媒体（HEAD），已有则跳过上传直接引用
        // v1.40 第6点：封面/视频首帧图/合集页/二维码全部改用户私有目录 users/<用户名>/
        var prepared: [PreparedRoom] = []
        for item in validRooms {
            let ordered = item.mediaFiles.sorted { lhs, rhs in
                let l = lhs.kind == "video" ? 0 : 1
                let r = rhs.kind == "video" ? 0 : 1
                return l < r
            }
            var videoTags: [String] = []
            var imageAbsURLs: [String] = []
            for m in ordered {
                let isVideo = m.kind == "video"
                let remoteName = isVideo ? cloudVideoName(for: m.name) : m.name
                let remotePath = "h/\(item.roomKey)/\(remoteName)"
                if await remoteObjectExists(path: remotePath, config: config) == false {
                    let url = MediaStore.url(for: m.name, roomKey: item.roomKey)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    var data = try Data(contentsOf: url)
                    var contentType = mimeType(for: m.kind, name: remoteName)
                    if isVideo {
                        // v1.29：视频统一转 mp4 上传（安卓/微信可播）；压缩开 → 720p，关 → 原质量转封装
                        if let mp4 = await uploadVideoData(from: url, compress: compressOnShare) {
                            data = mp4
                            contentType = "video/mp4"
                        }
                    } else if compressOnShare, let compressed = compressedImageData(from: url) {
                        data = compressed
                        contentType = "image/jpeg"
                    }
                    do {
                        try await uploadWithProgress(data: data, to: remotePath, contentType: contentType, config: config) { p in
                            reportProgress(Double(p))
                        }
                    } catch {
                        // v1.40 第5点：上传失败入队，App 启动/回前台自动补传
                        HouseMediaUploadQueue.enqueue(roomKey: item.roomKey, fileName: m.name, kind: m.kind)
                        throw error
                    }
                }
                // v1.25/v1.40：视频首帧封面图——每个 H5 页面都重新生成上传（不检测），路径改用户私有目录
                if isVideo {
                    let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(item.roomKey)/\(m.name).vthumb.jpg"
                    let localURL = MediaStore.url(for: m.name, roomKey: item.roomKey)
                    if FileManager.default.fileExists(atPath: localURL.path),
                       let thumbData = makeVideoThumbJPEG(from: localURL) {
                        try? await upload(data: thumbData, to: thumbRemotePath, contentType: "image/jpeg", config: config)
                    }
                }
                completedTasks += 1
                let absURL = try presignedGetURL(for: remotePath, expires: shareLinkExpires, config: config).absoluteString
                if isVideo {
                    // v1.25：video 无 src、无 poster、无 autoplay；封面用独立首帧图；点击封面 playVideo 才注入 src 并播放
                    let thumbRemotePath = "\(CloudUser.sharePagePrefix)\(item.roomKey)/\(m.name).vthumb.jpg"
                    let thumbURL = (try? presignedGetURL(for: thumbRemotePath, expires: shareLinkExpires, config: config).absoluteString) ?? absURL
                    videoTags.append("<div class=\"vwrap\" onclick=\"playVideo(this,'\(absURL)')\"><div class=\"vthumb\" style=\"background-image:url('\(thumbURL)')\"></div><div class=\"vplay\">▶</div><video class=\"v\" controls controlsList=\"nodownload\" disablepictureinpicture playsinline webkit-playsinline preload=\"none\"></video></div>")
                } else {
                    imageAbsURLs.append(absURL)
                }
            }
            var coverSrc = imageAbsURLs.first ?? ""
            if let firstImage = item.mediaFiles.first(where: { $0.kind == "image" }),
               let coverData = makeCoverJPEG(from: MediaStore.url(for: firstImage.name, roomKey: item.roomKey)) {
                let coverPath = "\(CloudUser.sharePagePrefix)\(item.roomKey)/cover"
                do {
                    try await uploadWithProgress(data: coverData, to: coverPath, contentType: "image/jpeg", config: config) { p in
                        reportProgress(Double(p))
                    }
                    coverSrc = try presignedGetURL(for: coverPath, expires: shareLinkExpires, config: config).absoluteString
                } catch {
                }
                completedTasks += 1
            }
            prepared.append(PreparedRoom(item: item, videoTags: videoTags, imageURLs: imageAbsURLs, coverSrc: coverSrc))
        }
        guard !prepared.isEmpty else { throw CosError.missingMedia }

        // 2. 生成并上传合集页。v1.36：文件名=首套房号+模式+日期时间（空 app 无存量链接，直接换新命名）
        // v1.40 第6点：合集页改存用户私有目录 users/<用户名>/shares/_collection/
        let collectionCover = prepared.first?.coverSrc ?? ""
        // v1.27/v1.40：名片微信二维码——用户私有目录覆盖写，旧合集链接自动显示新二维码
        var qrSrc = ""
        if hasQR, let qrData = makeQRCodeJPEG() {
            try? await uploadWithProgress(data: qrData, to: CloudUser.qrPath, contentType: "image/jpeg", config: config) { p in
                reportProgress(Double(p))
            }
            qrSrc = (try? presignedGetURL(for: CloudUser.qrPath, expires: shareLinkExpires, config: config).absoluteString) ?? ""
            completedTasks += 1
        }
        let wm = Self.watermarkOverlayHTML(WatermarkSettingsStore.current)
        let firstRoomLabel = prepared.first?.item.displayRoomNo ?? "合集"
        let pagePath = "\(CloudUser.sharePagePrefix)_collection/\(Self.safeFileName(firstRoomLabel))_\(mode.modeLabel)_\(Self.shareTimeTag()).html"
        let html = buildCollectionHTML(rooms: prepared, mode: mode, name: name, phone: phone, coverSrc: collectionCover, qrSrc: qrSrc,
                                       wm: wm, trackScript: Self.cloudTrackScript(room: firstRoomLabel, mode: mode.modeLabel))
        try await uploadWithProgress(data: Data(html.utf8), to: pagePath, contentType: "text/html; charset=utf-8", config: config) { p in
            reportProgress(Double(p))
        }
        completedTasks += 1
        progress?(1.0)

        let shareURL = try presignedGetURL(for: pagePath, expires: shareLinkExpires, config: config)
        let versionedURL = appendVersionParameter(shareURL, version: "\(Int(Date().timeIntervalSince1970))")

        // 3. 更新集合缓存
        ShareCacheStore.save(roomKey: cacheKey, mode: cacheMode, record: ShareCacheRecord(
            mediaFiles: validRooms.flatMap { $0.mediaFiles },
            info: ShareHouseInfo(
                displayRoomNo: "", towerLabel: "", layout: "", statusLabel: "",
                priceText: "", landlord: "", password: "", remark: "",
                name: name, phone: phone
            ),
            shareURL: versionedURL.absoluteString,
            bucket: config.bucket,
            region: config.region,
            customDomain: config.customDomain,
            compressOnShare: compressOnShare,
            collectionRooms: validRooms,
            templateVersion: htmlTemplateVersion,
            qrcodeSet: hasQR,
            watermarkHash: Self.watermarkHash(WatermarkSettingsStore.current)
        ))

        // v1.36：分享记录云端化——异步写桶内分享记录索引（失败不阻塞分享主流程）
        Task {
            try? await Self.appendShareRecord(roomKey: firstRoomLabel, displayRoomNo: firstRoomLabel, mode: mode, url: versionedURL.absoluteString, config: config)
        }

        return versionedURL
    }

    /// v1.20：连接自检（设置页「保存并验证」调用）。
    /// ①用当前配置上传一个测试文件到桶 → 验证桶名/地域/密钥/签名；
    /// ②再用访问域名（自定义域名或默认域名）读取该文件 → 验证域名解析 + HTTPS 证书 + 私有桶签名访问。
    /// 全部通过返回实际使用的访问域名；任一环节失败抛出带具体错误码的详细信息。
    static func verifyConnection(config: CosConfig) async throws -> String {
        let testPath = "h/_verify/connect.txt"
        let testData = Data("connect-ok-\(Int(Date().timeIntervalSince1970))".utf8)

        // 1. 上传测试对象：失败 = 桶名/地域/密钥/签名有误（错误信息里带 COS 错误码）
        try await upload(data: testData, to: testPath, contentType: "text/plain", config: config)

        // 2. 用访问域名读取测试对象：失败 = 自定义域名未绑定/未生效/证书异常（HTTP 错误或证书错误）
        let getURL = try presignedGetURL(for: testPath, expires: 120, config: config)
        var request = URLRequest(url: getURL)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CosError.uploadFailed("网络响应无效")
        }
        guard (200...299).contains(http.statusCode), String(data: data, encoding: .utf8)?.hasPrefix("connect-ok") == true else {
            let detail = extractCosError(from: data)
            throw CosError.uploadFailed("读取测试文件失败 HTTP \(http.statusCode)（" + (detail.isEmpty ? "请确认自定义域名已在存储桶「域名与传输管理」绑定并生效（状态为上线/已解析）" : detail) + "）")
        }
        return host(for: config)
    }

    /// 读设置页保存的分享名片信息（姓名/电话）；未设置时用默认值
    /// 默认：梁涛 / 13288251132（名片、微信卡片描述、拨打电话、复制按钮四处统一）
    static func loadShareProfile() -> (name: String, phone: String) {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let name = (KeychainStore.load(KeychainKey.shareName) ?? "").trimmingCharacters(in: trimSet)
        let phone = (KeychainStore.load(KeychainKey.sharePhone) ?? "").trimmingCharacters(in: trimSet)
        return (name.isEmpty ? "梁涛" : name, phone.isEmpty ? "13288251132" : phone)
    }

    // MARK: - HTML 模板（v1.21 设计稿定稿：脱敏版）

    /// v1.28：二维码列（二维码 + 下方小字「长按二维码加我好友」），无二维码时返回空串（该行不显示）
    private static func qrColumnHTML(qrSrc: String) -> String {
        guard !qrSrc.isEmpty else { return "" }
        return "<div class=\"qr-col\"><img class=\"qr\" src=\"\(qrSrc)\" alt=\"微信二维码\"><div class=\"qr-tip\">长按二维码加我好友</div></div>"
    }

    /// 脱敏版（隐藏版）：户型大字 → 位置+导航 → 实拍（视频置顶、图片单列）→ 名片 → 底栏
    /// 无房号/价格/房东/密码/备注；图片用 CSS 背景图渲染（微信长按背景图无「保存图片」），全局禁右键/禁长按选择
    /// v1.27：名片板块换浅蓝底色；微信二维码（真实 <img>，可长按被微信识别）放左侧，原居中信息右移
    private static func buildMaskedHTML(title: String, desc: String, name: String, phone: String, videoTags: [String], imageURLs: [String], coverSrc: String, qrSrc: String, shareLink: String, wm: String = "", trackScript: String = "") -> String {
        let mediaBlock = mediaBlockHTML(videoTags: videoTags, imageURLs: imageURLs, wm: wm)
        let coverMeta = coverSrc.isEmpty ? "" : "<meta property=\"og:image\" content=\"\(coverSrc)\">"
        let urlMeta = shareLink.isEmpty ? "" : "<meta property=\"og:url\" content=\"\(shareLink)\">"
        let galleryJS = imageURLs.map { "'\($0)'" }.joined(separator: ",")
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:title" content="\(escapeHTML(title))">
        <meta property="og:description" content="\(escapeHTML(desc))">
        \(coverMeta)
        \(urlMeta)
        <title>\(escapeHTML(title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;margin:0;background:#f4f5f7;color:#1c1c1e;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;}
        .wrap{max-width:640px;margin:0 auto;padding:0 16px 16px;}
        .hero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;}
        .type{font-size:30px;font-weight:700;margin:0 0 14px;}
        .loc{display:flex;align-items:center;gap:8px;color:rgba(255,255,255,.92);text-decoration:none;}
        .loc-name{font-size:15px;}
        .nav-pill{display:inline-flex;align-items:center;gap:4px;background:rgba(255,255,255,.18);border-radius:999px;padding:6px 12px;font-size:13px;margin-left:auto;}
        .sec{font-size:15px;color:#3a3a3c;margin:18px 4px 10px;font-weight:600;}
        .media{background:#fff;border-radius:16px;padding:12px;}
        .vwrap{position:relative;width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;margin-bottom:10px;background:#000;cursor:pointer;}
        .vthumb{position:absolute;inset:0;background-size:cover;background-position:center;}
        .vplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;color:#fff;font-size:28px;border:2px solid rgba(255,255,255,.85);}
        .vwrap video{width:100%;height:100%;display:none;background:#000;}
        .vwrap.playing .vthumb,.vwrap.playing .vplay{display:none;}
        .vwrap.playing video{display:block;}
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;position:relative;}
        .cell{width:100%;height:100%;object-fit:cover;display:block;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .card{background:linear-gradient(180deg,#f7fafd,#e9f1f9);border:1px solid #dfe9f3;border-radius:16px;padding:14px;margin-top:12px;}
        .qr-wrap{display:flex;align-items:center;gap:14px;}
        .qr-wrap.center{justify-content:center;}
        .qr-col{display:flex;flex-direction:column;align-items:center;gap:3px;flex-shrink:0;}
        .qr-tip{font-size:10px;color:#8e8e93;text-align:center;max-width:108px;white-space:nowrap;line-height:1.3;}
        .qr{width:108px;height:108px;border-radius:10px;object-fit:cover;flex-shrink:0;background:#fff;border:1px solid #e3e3e8;-webkit-touch-callout:default;-webkit-user-select:text;user-select:text;-webkit-user-drag:auto;}
        .card-info{flex:1;min-width:0;text-align:center;}
        .tag{color:#8e8e93;font-size:12px;margin-bottom:10px;}
        .row{display:flex;align-items:center;justify-content:center;gap:8px;}
        .name{font-size:17px;font-weight:600;}
        .num{font-size:16px;font-weight:600;color:#b8860b;}
        .note{color:#8e8e93;font-size:12px;margin:10px 0 14px;}
        .btns{display:flex;gap:10px;justify-content:center;}
        .btn{flex:1;max-width:220px;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;text-decoration:none;}
        .btn.call{background:#1f3a5f;color:#fff;}
        .btn.copy{background:#f0f0f2;color:#1c1c1e;border:none;}
        .foot{text-align:center;color:#8e8e93;font-size:12px;padding:18px 0 26px;}
        #toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 18px;border-radius:8px;font-size:14px;z-index:999;display:none;}
        #lb{position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:999;display:none;}
        #lbImg{position:absolute;inset:0;background-size:contain;background-position:center;background-repeat:no-repeat;}
        #lbPrev{position:absolute;left:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbNext{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbClose{position:absolute;top:12px;right:12px;color:#fff;font-size:26px;padding:10px;cursor:pointer;user-select:none;}
        #lbCnt{position:absolute;bottom:22px;left:0;right:0;text-align:center;color:rgba(255,255,255,.85);font-size:14px;user-select:none;}
        </style>
        </head>
        <body oncontextmenu="return false">
        <div class="wrap">
        <section class="hero">
          <h1 class="type">\(escapeHTML(title))</h1>
          <a class="loc" href="https://uri.amap.com/search?keyword=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E5%AF%93" target="_blank" rel="noopener">
            <span class="loc-name">利保米兰公馆</span>
            <span class="nav-pill"><svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a7 7 0 0 0-4 12.7V17a1 1 0 0 0 2 0v-1h4v1a1 1 0 0 0 2 0v-2.3A7 7 0 0 0 12 2zm0 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10zm0 3a2 2 0 1 0 0 4 2 2 0 0 0 0-4z"/></svg>导航</span>
          </a>
        </section>
        <h2 class="sec">实拍 · 点击放大</h2>
        \(mediaBlock)
        <section class="card">
          <div class="\(qrWrapClass)">
            \(qrCol)
            <div class="card-info">
              <div class="tag">米兰租赁管家 · 专业省心租好房</div>
              <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
              <div class="note">微信同号 · 24小时可约看房</div>
              <div class="btns">
                <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
              </div>
            </div>
          </div>
        </section>
        <div class="foot">更多优质房源请与我联系-\(escapeHTML(phone))</div>
        </div>
        <div class="mask" id="mask" style="display:none" onclick="hideModal()"><img id="modalImg" src="" alt=""></div>
        <div id="toast"></div>
        <div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
        <script>
        var GALLERY=[\(galleryJS)];var gi=0;
        function playVideo(w,src){var v=w.querySelector('video');if(!v.src){v.src=src;}var p=v.play();if(p&&p.catch){p.catch(function(){});}w.className=w.className+' playing';}
        function openImg(i){gi=i;show();}
        function show(){var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}
        function lbPrev(){gi=(gi-1+GALLERY.length)%GALLERY.length;show();}
        function lbNext(){gi=(gi+1)%GALLERY.length;show();}
        function lbClose(){document.getElementById('lb').style.display='none';}
        var _sx=0;(function(){var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){_sx=e.touches[0].clientX},{passive:true});d.addEventListener('touchend',function(e){var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){dx<0?lbNext():lbPrev();}},{passive:true});})();
        function toast(msg){var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){t.style.display='none'},1600);}
        function showModal(src){
          document.getElementById("modalImg").src = src;
          document.getElementById("mask").style.display = "flex";
        }
        function hideModal(){ document.getElementById("mask").style.display = "none"; }
        document.getElementById("list").addEventListener("click", function(e){
          var card = e.target.closest(".card");
          if(!card) return;
          var h = ROOMS[parseInt(card.getAttribute("data-i"))];
          if(!h) return;
          if(h.share){ location.href = h.share; return; }
          if(h.cover){ showModal(h.cover, h.layout); }
        });
        function copyPhone(){var p='\(phone)';function done(){toast('已复制 '+p)}function fb(){var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(p).then(done,fb)}else{fb()}}
        </script>
        \(trackScript)
        </body>
        </html>
        """
    }

    // MARK: - v1.50 公开选房页静态壳（与单房分享 H5 同机制：存 COS、链接走自定义域名，微信正常打开+卡片）

    /// 取本地第一套房的封面云端路径（用于选房页 og:image，与分享 H5 同款封面）：
    /// 优先视频首帧图 users/<用户名>/shares/<房号>/<视频名>.vthumb.jpg；无视频则第一张图 h/<房号>/<文件名>
    private static func firstRoomCoverRemotePath() -> String {
        let dir = MediaStore.mediaDirectory()
        guard let houseDirs = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return "" }
        for hd in houseDirs.sorted() {
            var isDir: ObjCBool = false
            let hpath = dir.appendingPathComponent(hd)
            guard FileManager.default.fileExists(atPath: hpath.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let mediaNames = (try? FileManager.default.contentsOfDirectory(atPath: hpath.path)) ?? []
            for mn in mediaNames.sorted() {
                let lower = mn.lowercased()
                if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v") {
                    return "users/\(CloudUser.safeName)/shares/\(hd)/\(mn).vthumb.jpg"
                }
            }
            for mn in mediaNames.sorted() {
                let lower = mn.lowercased()
                if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".heic") || lower.hasSuffix(".webp") {
                    return "h/\(hd)/\(mn)"
                }
            }
        }
        return ""
    }

    /// 生成公开选房页静态壳 HTML：
    /// - 存桶 users/<用户名>/rooms/index.html，链接用 presignedGetURL（自动走自定义域名——微信按网页渲染并抓卡片）
    /// - 页面 JS 每次打开/刷新实时 fetch 云函数 ?act=rooms_json&u=<用户名> 渲染最新房源/名片/二维码，改完刷新即最新
    /// - og:image 优先微信二维码（10 年签名），其次本地第一套封面；og:title/description 供微信卡片
    static func buildRoomsShellHTML(config: CosConfig, shellURL: String) -> String {
        let u = CloudUser.safeName
        let uEsc = u.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let base = CloudConfig.functionURL
        var cd = config.customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        for pre in ["https://", "http://"] where cd.lowercased().hasPrefix(pre) {
            cd = String(cd.dropFirst(pre.count))
        }
        while cd.hasSuffix("/") { cd.removeLast() }
        let cdEsc = cd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // v1.55：jsUrlBase 供选房页访问埋点用（track 走同一云函数，按用户名分文件统计）
        let jsUrlBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsUrl = jsUrlBase + "?act=rooms_json&u=" + uEsc + "&cd=" + cdEsc
        let pageUrl = base + "?act=rooms&u=" + uEsc
        // og:image 用本地第一套房封面（与分享 H5 同款，云端必存在）；og:url 用壳自身签名链接（微信按此抓取）
        var og = ""
        let coverPath = firstRoomCoverRemotePath()
        if !coverPath.isEmpty,
           let cv = try? presignedGetURL(for: coverPath, expires: 3650 * 86400, config: config).absoluteString {
            og = cv
        }
        let ogMeta = og.isEmpty ? "" : "<meta property=\"og:image\" content=\"\(og)\">"
        let urlMeta = "<meta property=\"og:url\" content=\"\(shellURL)\">"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>米兰公馆 · 在租房源</title>
        <meta name="description" content="米兰公馆在租房源，实时更新，户型直达">
        <meta property="og:type" content="website">
        <meta property="og:title" content="米兰公馆 · 在租房源">
        <meta property="og:description" content="实时更新的在租房源列表，点击查看户型。更多优质房源请与我联系。">
        \(ogMeta)
        \(urlMeta)
        <style>
        *{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent;}
        html,body{background:#f4f5f7;color:#1a1c20;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",system-ui,sans-serif;}
        html,body{height:100%;}
        body{max-width:560px;margin:0 auto;padding:0 16px 24px;display:flex;flex-direction:column;min-height:100%;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-user-drag:none;}
        body *{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-user-drag:none;}
        .main{flex:1 0 auto;width:100%;}
        .head{display:flex;align-items:center;justify-content:space-between;padding:16px 2px 6px;}
        h1{font-size:19px;font-weight:700;color:#1a1c20;letter-spacing:.5px;}
        .refresh{color:#1f7a4d;font-size:14px;font-weight:600;background:none;border:none;padding:6px 8px;}
        .filters{display:flex;gap:8px;flex-wrap:wrap;padding:10px 2px 4px;}
        .chip{padding:5px 13px;border-radius:15px;background:#eef0f2;color:#5b616e;font-size:13px;border:none;}
        .chip.on{background:#1f7a4d;color:#fff;font-weight:600;}
        #count{font-size:13px;color:#8a919e;padding:4px 2px 2px;}
        #loading{text-align:center;color:#8a919e;padding:50px 0;font-size:14px;}
        .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;padding:12px 0;}
        .card{position:relative;border-radius:12px;overflow:hidden;background:#fff;aspect-ratio:1/1;box-shadow:0 1px 4px rgba(0,0,0,.06);}
        .cover{position:absolute;inset:0;}
        .cover img{width:100%;height:100%;object-fit:cover;display:block;}
        .ph{width:100%;height:100%;background:linear-gradient(135deg,#dfe3e8,#c6cdd6);}
        .play{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:46px;height:46px;border-radius:50%;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;}
        .play::after{content:"";border-left:14px solid #fff;border-top:9px solid transparent;border-bottom:9px solid transparent;margin-left:3px;}
        .type-tag{position:absolute;left:8px;bottom:8px;background:rgba(0,0,0,.55);color:#fff;font-size:12px;padding:3px 9px;border-radius:10px;}
        #empty{display:none;text-align:center;color:#8a919e;padding:60px 0;font-size:14px;}
        #mask{display:none;position:fixed;inset:0;background:rgba(0,0,0,.92);z-index:50;align-items:center;justify-content:center;}
        #mask img{max-width:92%;max-height:88%;border-radius:8px;}
        #mask .x{position:absolute;top:44px;right:18px;color:#fff;font-size:30px;line-height:1;padding:8px;}
        #toast{position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:9px 16px;border-radius:8px;font-size:13px;opacity:0;pointer-events:none;transition:opacity .2s;z-index:60;}
        #toast.show{opacity:1;}
        .person{margin-top:auto;background:#fff;border-radius:12px;padding:14px 14px 12px;box-shadow:0 1px 4px rgba(0,0,0,.06);}
        .person .top{display:flex;gap:12px;align-items:flex-start;}
        .person .avatar{width:48px;height:48px;border-radius:50%;background:#1f7a4d;color:#fff;display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:700;flex-shrink:0;}
        .person .nm{font-size:16px;font-weight:700;}
        .person .ph-t{font-size:14px;color:#5b616e;margin-top:2px;}
        .person .btns{display:flex;gap:10px;margin-top:12px;}
        .person .btn{flex:1;text-align:center;padding:10px 0;border-radius:10px;font-size:14px;}
        .person .call{background:#1f7a4d;color:#fff;font-weight:600;}
        .person .copy{background:#f0f2f4;color:#1a1c20;}
        .qr-row{display:none;margin-top:10px;background:#fff;border-radius:12px;padding:12px;text-align:center;}
        .qr-row img{width:110px;height:110px;border-radius:6px;}
        .qr-row p{font-size:12px;color:#8a919e;margin-top:6px;}
        </style>
        </head>
        <body>
        <div class="main">
          <div class="head"><h1>米兰公馆 · 在租房源</h1><button class="refresh" id="refreshBtn">刷新</button></div>
          <div class="filters" id="filters"></div>
          <div id="count"></div>
          <div id="loading">加载中...</div>
          <div class="grid" id="list"></div>
          <div id="empty">暂无待租房源</div>
        </div>
        <div class="person" id="cardShare">
          <div class="top">
            <div class="avatar" id="avatar">梁</div>
            <div>
              <div class="nm" id="nameText">梁涛</div>
              <div class="ph-t" id="phoneText">13288251132</div>
              <div style="font-size:12px;color:#8a919e;margin-top:2px;">微信同号 · 24小时可约看房</div>
            </div>
          </div>
          <div class="btns">
            <div class="btn call" id="callBtn">拨打电话</div>
            <div class="btn copy" id="copyBtn">复制电话</div>
          </div>
        </div>
        <div class="qr-row" id="qrCol"><img id="qrImg" alt="二维码"><p>扫码加微信 直接看房</p></div>
        <div id="mask" onclick="this.style.display='none'"><span class="x">×</span><img id="modalImg" alt=""></div>
        <div id="toast"></div>
        <script>
        var FETCH_URL = "\(jsUrl)";
        var ROOMS = [];
        var curFilter = "全部";
        function esc(s){ var d=document.createElement("div"); d.textContent=(s||""); return d.innerHTML; }
        function render(){
          var rows = ROOMS;
          if(curFilter !== "全部"){ rows = ROOMS.filter(function(h){ return h.layout === curFilter; }); }
          document.getElementById("count").textContent = "共 " + rows.length + " 套待租房源" + (curFilter !== "全部" ? "（"+curFilter+"）" : "");
          var list = document.getElementById("list");
          list.innerHTML = rows.map(function(h,i){
            var cover = h.cover || "";
            var inner = cover ? '<img class="cv" src="'+cover+'" alt="" loading="lazy" onerror="this.remove()">' : '<div class="ph"></div>';
            return '<div class="card" data-i="'+i+'"><div class="cover">'+inner+'<span class="play"></span><span class="type-tag">'+esc(h.layout)+'</span></div></div>';
          }).join("");
          document.getElementById("empty").style.display = rows.length ? "none" : "block";
          document.getElementById("loading").style.display = "none";
        }
        function buildFilters(){
          var kinds = ["全部"];
          ROOMS.forEach(function(h){ if(kinds.indexOf(h.layout) < 0) kinds.push(h.layout); });
          document.getElementById("filters").innerHTML = kinds.map(function(k){
            return '<span class="chip'+(curFilter===k?" on":"")+'" data-k="'+k+'">'+k+'</span>';
          }).join("");
        }
        var toastTimer;
        function showToast(msg){
          var t = document.getElementById("toast");
          t.textContent = msg; t.classList.add("show");
          clearTimeout(toastTimer);
          toastTimer = setTimeout(function(){ t.classList.remove("show"); }, 1600);
        }
        function showModal(src){
          document.getElementById("modalImg").src = src;
          document.getElementById("mask").style.display = "flex";
        }
        document.getElementById("list").addEventListener("click", function(e){
          var card = e.target.closest(".card");
          if(!card) return;
          var h = ROOMS[parseInt(card.getAttribute("data-i"))];
          if(!h) return;
          if(h.share){ location.href = h.share; return; }
          if(h.cover){ showModal(h.cover); }
        });
        function copyPhone(){
          var p = document.getElementById("phoneText").textContent;
          function done(){ showToast("已复制 "+p); }
          function fb(){
            var i = document.createElement("input");
            i.value = p; document.body.appendChild(i); i.select();
            i.setSelectionRange(0,999); document.execCommand("copy"); i.remove(); done();
          }
          if(navigator.clipboard && window.isSecureContext){ navigator.clipboard.writeText(p).then(done,fb); }
          else { fb(); }
        }
        function load(){
          document.getElementById("loading").style.display = "block";
          document.getElementById("list").innerHTML = "";
          document.getElementById("empty").style.display = "none";
          fetch(FETCH_URL).then(function(r){ return r.json(); }).then(function(d){
            ROOMS = (d && d.rooms) || [];
            buildFilters(); render();
            var name = (d && d.name) || "梁涛"; var phone = (d && d.phone) || "13288251132";
            document.getElementById("nameText").textContent = name;
            document.getElementById("phoneText").textContent = phone;
            var a = document.getElementById("avatar"); a.textContent = name.length ? name[0] : "梁";
            if(d && d.qr){ document.getElementById("qrCol").style.display = "block"; document.getElementById("qrImg").src = d.qr; }
            else { document.getElementById("qrCol").style.display = "none"; }
            showToast("已刷新");
            TRACK();
          }).catch(function(){
            document.getElementById("loading").style.display = "none";
            showToast("刷新失败，请检查网络");
          });
        }
        function TRACK(){
          try{
            var b = "\(jsUrlBase)"; if(!b || b.indexOf("http") !== 0) return;
            var img = new Image();
            img.src = b + "?act=track&room=rooms&mode=rooms&ref=" + encodeURIComponent((document.referrer||"").slice(0,120)) + "&t=" + Date.now() + "&uname=\(uEsc)";
          }catch(e){}
        }
        document.getElementById("filters").addEventListener("click", function(e){
          var chip = e.target.closest(".chip");
          if(!chip) return;
          curFilter = chip.getAttribute("data-k");
          buildFilters(); render();
        });
        document.getElementById("refreshBtn").addEventListener("click", load);
        document.getElementById("copyBtn").addEventListener("click", copyPhone);
        document.getElementById("callBtn").addEventListener("click", function(){
          var p = document.getElementById("phoneText").textContent;
          location.href = "tel:" + p.replace(/[^0-9]/g,"");
        });
        load();
        </script>
        </body>
        </html>
"""

    }

    // MARK: - HTML 模板（v1.21 设计稿定稿：完整版）

    /// 完整版（不隐藏版）：v1.22 信息板块重排为三行——第一行：房号(左) + 户型(右)；第二行：租金 + 密码（密码：xxx）+ 房东（最右）；
    /// 第三行：备注（有才显示，空则整行隐藏）。实拍 → 名片 → 底栏
    private static func buildFullHTML(title: String, desc: String, info: ShareHouseInfo, name: String, phone: String, videoTags: [String], imageURLs: [String], coverSrc: String, qrSrc: String, shareLink: String, wm: String = "", trackScript: String = "") -> String {
        let mediaBlock = mediaBlockHTML(videoTags: videoTags, imageURLs: imageURLs, wm: wm)
        let coverMeta = coverSrc.isEmpty ? "" : "<meta property=\"og:image\" content=\"\(coverSrc)\">"
        let urlMeta = shareLink.isEmpty ? "" : "<meta property=\"og:url\" content=\"\(shareLink)\">"
        let galleryJS = imageURLs.map { "'\($0)'" }.joined(separator: ",")
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"

        let host = info.landlord.isEmpty ? "" : "<span class=\"host\">\(escapeHTML(info.landlord))</span>"
        let pw = info.password.isEmpty ? "" : "<span class=\"pw\">密码：\(escapeHTML(info.password))</span>"
        let remarkLine = info.remark.isEmpty ? "" : "<div class=\"remark\">\(escapeHTML(info.remark))</div>"
        let layoutText = info.layout.isEmpty ? "房源" : escapeHTML(info.layout)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:title" content="\(escapeHTML(title))">
        <meta property="og:description" content="\(escapeHTML(desc))">
        \(coverMeta)
        \(urlMeta)
        <title>\(escapeHTML(title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;margin:0;background:#f4f5f7;color:#1c1c1e;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;}
        .wrap{max-width:640px;margin:0 auto;padding:0 16px 16px;}
        .hero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;}
        .l1{display:flex;justify-content:space-between;align-items:baseline;}
        .room{font-size:30px;font-weight:700;}
        .price{font-size:30px;font-weight:700;color:#f5c46b;}
        .l2{display:flex;align-items:baseline;gap:14px;margin-top:12px;}
        .pw{font-size:18px;color:rgba(255,255,255,.9);}
        .layout2{font-size:18px;color:rgba(255,255,255,.9);}
        .host{margin-left:auto;font-size:18px;color:rgba(255,255,255,.9);}
        .remark{margin-top:10px;font-size:13px;color:rgba(255,255,255,.7);}
        .sec{font-size:15px;color:#3a3a3c;margin:18px 4px 10px;font-weight:600;}
        .media{background:#fff;border-radius:16px;padding:12px;}
        .vwrap{position:relative;width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;margin-bottom:10px;background:#000;cursor:pointer;}
        .vthumb{position:absolute;inset:0;background-size:cover;background-position:center;}
        .vplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;color:#fff;font-size:28px;border:2px solid rgba(255,255,255,.85);}
        .vwrap video{width:100%;height:100%;display:none;background:#000;}
        .vwrap.playing .vthumb,.vwrap.playing .vplay{display:none;}
        .vwrap.playing video{display:block;}
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;position:relative;}
        .cell{width:100%;height:100%;object-fit:cover;display:block;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .card{background:linear-gradient(180deg,#f7fafd,#e9f1f9);border:1px solid #dfe9f3;border-radius:16px;padding:14px;margin-top:12px;}
        .qr-wrap{display:flex;align-items:center;gap:14px;}
        .qr-wrap.center{justify-content:center;}
        .qr-col{display:flex;flex-direction:column;align-items:center;gap:3px;flex-shrink:0;}
        .qr-tip{font-size:10px;color:#8e8e93;text-align:center;max-width:108px;white-space:nowrap;line-height:1.3;}
        .qr{width:108px;height:108px;border-radius:10px;object-fit:cover;flex-shrink:0;background:#fff;border:1px solid #e3e3e8;-webkit-touch-callout:default;-webkit-user-select:text;user-select:text;-webkit-user-drag:auto;}
        .card-info{flex:1;min-width:0;text-align:center;}
        .tag{color:#8e8e93;font-size:12px;margin-bottom:10px;}
        .row{display:flex;align-items:center;justify-content:center;gap:8px;}
        .name{font-size:17px;font-weight:600;}
        .num{font-size:16px;font-weight:600;color:#b8860b;}
        .note{color:#8e8e93;font-size:12px;margin:10px 0 14px;}
        .btns{display:flex;gap:10px;justify-content:center;}
        .btn{flex:1;max-width:220px;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;text-decoration:none;}
        .btn.call{background:#1f3a5f;color:#fff;}
        .btn.copy{background:#f0f0f2;color:#1c1c1e;border:none;}
        .foot{text-align:center;color:#8e8e93;font-size:12px;padding:18px 0 26px;}
        #toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 18px;border-radius:8px;font-size:14px;z-index:999;display:none;}
        #lb{position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:999;display:none;}
        #lbImg{position:absolute;inset:0;background-size:contain;background-position:center;background-repeat:no-repeat;}
        #lbPrev{position:absolute;left:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbNext{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbClose{position:absolute;top:12px;right:12px;color:#fff;font-size:26px;padding:10px;cursor:pointer;user-select:none;}
        #lbCnt{position:absolute;bottom:22px;left:0;right:0;text-align:center;color:rgba(255,255,255,.85);font-size:14px;user-select:none;}
        </style>
        </head>
        <body oncontextmenu="return false">
        <div class="wrap">
        <section class="hero">
          <div class="l1"><span class="room">\(escapeHTML(info.displayRoomNo))</span><span class="price">\(escapeHTML(info.priceText))</span></div>
          <div class="l2">\(pw)<span class="layout2">\(layoutText)</span>\(host)</div>
          \(remarkLine)
        </section>
        <h2 class="sec">实拍 · 点击放大</h2>
        \(mediaBlock)
        <section class="card">
          <div class="\(qrWrapClass)">
            \(qrCol)
            <div class="card-info">
              <div class="tag">米兰租赁管家 · 专业省心租好房</div>
              <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
              <div class="note">微信同号 · 24小时可约看房</div>
              <div class="btns">
                <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
              </div>
            </div>
          </div>
        </section>
        <div class="foot">更多优质房源请与我联系-\(escapeHTML(phone))</div>
        </div>
        <div class="mask" id="mask" style="display:none" onclick="hideModal()"><img id="modalImg" src="" alt=""></div>
        <div id="toast"></div>
        <div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
        <script>
        var GALLERY=[\(galleryJS)];var gi=0;
        function playVideo(w,src){var v=w.querySelector('video');if(!v.src){v.src=src;}var p=v.play();if(p&&p.catch){p.catch(function(){});}w.className=w.className+' playing';}
        function openImg(i){gi=i;show();}
        function show(){var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}
        function lbPrev(){gi=(gi-1+GALLERY.length)%GALLERY.length;show();}
        function lbNext(){gi=(gi+1)%GALLERY.length;show();}
        function lbClose(){document.getElementById('lb').style.display='none';}
        var _sx=0;(function(){var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){_sx=e.touches[0].clientX},{passive:true});d.addEventListener('touchend',function(e){var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){dx<0?lbNext():lbPrev();}},{passive:true});})();
        function toast(msg){var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){t.style.display='none'},1600);}
        function showModal(src){
          document.getElementById("modalImg").src = src;
          document.getElementById("mask").style.display = "flex";
        }
        function hideModal(){ document.getElementById("mask").style.display = "none"; }
        document.getElementById("list").addEventListener("click", function(e){
          var card = e.target.closest(".card");
          if(!card) return;
          var h = ROOMS[parseInt(card.getAttribute("data-i"))];
          if(!h) return;
          if(h.share){ location.href = h.share; return; }
          if(h.cover){ showModal(h.cover, h.layout); }
        });
        function copyPhone(){var p='\(phone)';function done(){toast('已复制 '+p)}function fb(){var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(p).then(done,fb)}else{fb()}}
        </script>
        \(trackScript)
        </body>
        </html>
        """
    }

    // MARK: - v1.22 合集 H5（多选分享：一次链接，N 套房源列表 + 各自详情）

    /// 合集页：列表（封面+房号+租金+户型）→ 点某套进入详情（视频置顶、图片单列、名片在详情底部）；
    /// 脱敏/完整按模式渲染详情信息区。所有图片进入统一 GALLERY 支持左右滑动查看。
    private struct PreparedRoom {
        let item: ShareCollectionItem
        let videoTags: [String]
        let imageURLs: [String]
        let coverSrc: String
    }

    private static func buildCollectionHTML(rooms: [PreparedRoom], mode: ShareMode, name: String, phone: String, coverSrc: String, qrSrc: String, wm: String = "", trackScript: String = "") -> String {
        let count = rooms.count
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"
        // og
        let title: String
        let desc: String
        switch mode {
        case .masked:
            title = "已为你挑选\(count)套优质房源"
            desc = "利保米兰公馆\n\(name)-\(phone)"
        case .full:
            let minPrice = rooms.map { $0.item.priceText }.min() ?? ""
            title = "已为你挑选\(count)套优质房源"
            desc = (minPrice.isEmpty ? "精选\(count)套房源" : "精选\(count)套房源 · 起租\(minPrice)") + "\n\(name)-\(phone)"
        }
        let coverMeta = coverSrc.isEmpty ? "" : "<meta property=\"og:image\" content=\"\(coverSrc)\">"

        // 列表项：v1.23 脱敏版只显示户型（隐藏房号/价格），完整版显示房号 + 价格·户型
        var listItems: [String] = []
        var detailsJS: [String] = []
        var gallery: [String] = []
        var cursor = 0
        for (index, room) in rooms.enumerated() {
            // v1.25：缩略图改用 <img> 标签渲染（微信 WebView 对背景图/动态注入元素的 background-image 加载不可靠，
            // <img> 是原生图片加载最稳的方式）；draggable=false + touch-callout:none 防长按保存
            let cover = room.coverSrc.isEmpty ? "" : " src=\"\(room.coverSrc)\""
            let metaHTML: String
            if mode == .masked {
                metaHTML = """
                <div class="meta">
                  <div class="rno">\(escapeHTML(room.item.layout.isEmpty ? "房源" : room.item.layout))</div>
                  <div class="sub2">利保米兰公馆</div>
                </div>
                """
            } else {
                metaHTML = """
                <div class="meta">
                  <div class="rno">\(escapeHTML(room.item.displayRoomNo))</div>
                  <div class="sub2">\(escapeHTML(room.item.priceText)) · \(escapeHTML(room.item.layout.isEmpty ? "房源" : room.item.layout))</div>
                </div>
                """
            }
            listItems.append("""
            <div class="item" onclick="showDetail(\(index))">
              <img class="thumb"\(cover) draggable="false" alt="">
              \(metaHTML)
            </div>
            """)

            let detail = collectionDetailHTML(item: room.item, mode: mode, videoTags: room.videoTags, imageURLs: room.imageURLs, startIndex: cursor, name: name, phone: phone, qrSrc: qrSrc, wm: wm)
            cursor += room.imageURLs.count
            gallery.append(contentsOf: room.imageURLs)
            // JS 单引号字符串转义：反斜杠 → \\ 、单引号 → \' 、换行 → \n（JS 字符串字面量不允许未转义换行）
            let escaped = detail
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            detailsJS.append("'" + escaped + "'")
        }
        let galleryJS = gallery.map { "'\($0)'" }.joined(separator: ",")
        let itemsHTML = listItems.joined(separator: "\n")
        let roomsJS = detailsJS.joined(separator: ",")

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:title" content="\(escapeHTML(title))">
        <meta property="og:description" content="\(escapeHTML(desc))">
        \(coverMeta)
        <title>\(escapeHTML(title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;margin:0;background:#f4f5f7;color:#1c1c1e;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent;}
        .wrap{max-width:640px;margin:0 auto;padding:0 16px 16px;}
        .hero2{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px;margin-top:14px;}
        .coll-title{font-size:26px;font-weight:700;margin:0 0 8px;}
        .coll-sub{font-size:14px;color:rgba(255,255,255,.85);}
        .items{margin-top:12px;}
        .item{display:flex;gap:12px;background:#fff;border-radius:14px;padding:12px;margin-bottom:10px;align-items:center;}
        .thumb{width:96px;height:72px;border-radius:10px;object-fit:cover;display:block;background-color:#e8e8ec;flex-shrink:0;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .meta{flex:1;min-width:0;}
        .rno{font-size:17px;font-weight:700;color:#1c1c1e;}
        .sub2{font-size:13px;color:#8e8e93;margin-top:4px;}
        .back{display:block;width:100%;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;background:#fff;color:#1f3a5f;border:1px solid #dfe1e6;margin:14px 0 4px;text-decoration:none;}
        .dhero{background:linear-gradient(135deg,#1f3a5f,#2d5f8a);color:#fff;border-radius:16px;padding:20px 20px 16px;margin-top:14px;}
        .type{font-size:30px;font-weight:700;margin:0 0 14px;}
        .loc{display:flex;align-items:center;gap:8px;color:rgba(255,255,255,.92);text-decoration:none;}
        .loc-name{font-size:15px;}
        .nav-pill{display:inline-flex;align-items:center;gap:4px;background:rgba(255,255,255,.18);border-radius:999px;padding:6px 12px;font-size:13px;margin-left:auto;}
        .l1{display:flex;justify-content:space-between;align-items:baseline;}
        .room{font-size:30px;font-weight:700;}
        .price{font-size:30px;font-weight:700;color:#f5c46b;}
        .l2{display:flex;align-items:baseline;gap:14px;margin-top:12px;}
        .pw{font-size:18px;color:rgba(255,255,255,.9);}
        .layout2{font-size:18px;color:rgba(255,255,255,.9);}
        .host{margin-left:auto;font-size:18px;color:rgba(255,255,255,.9);}
        .remark{margin-top:10px;font-size:13px;color:rgba(255,255,255,.7);}
        .sec{font-size:15px;color:#3a3a3c;margin:18px 4px 10px;font-weight:600;}
        .media{background:#fff;border-radius:16px;padding:12px;}
        .vwrap{position:relative;width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;margin-bottom:10px;background:#000;cursor:pointer;}
        .vthumb{position:absolute;inset:0;background-size:cover;background-position:center;}
        .vplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;color:#fff;font-size:28px;border:2px solid rgba(255,255,255,.85);}
        .vwrap video{width:100%;height:100%;display:none;background:#000;}
        .vwrap.playing .vthumb,.vwrap.playing .vplay{display:none;}
        .vwrap.playing video{display:block;}
        .cellwrap{width:100%;aspect-ratio:4/3;border-radius:10px;overflow:hidden;background-color:#e8e8ec;margin-bottom:10px;cursor:pointer;position:relative;}
        .cell{width:100%;height:100%;object-fit:cover;display:block;pointer-events:none;-webkit-user-drag:none;-webkit-touch-callout:none;}
        .card{background:linear-gradient(180deg,#f7fafd,#e9f1f9);border:1px solid #dfe9f3;border-radius:16px;padding:14px;margin-top:12px;}
        .qr-wrap{display:flex;align-items:center;gap:14px;}
        .qr-wrap.center{justify-content:center;}
        .qr-col{display:flex;flex-direction:column;align-items:center;gap:3px;flex-shrink:0;}
        .qr-tip{font-size:10px;color:#8e8e93;text-align:center;max-width:108px;white-space:nowrap;line-height:1.3;}
        .qr{width:108px;height:108px;border-radius:10px;object-fit:cover;flex-shrink:0;background:#fff;border:1px solid #e3e3e8;-webkit-touch-callout:default;-webkit-user-select:text;user-select:text;-webkit-user-drag:auto;}
        .card-info{flex:1;min-width:0;text-align:center;}
        .tag{color:#8e8e93;font-size:12px;margin-bottom:10px;}
        .row{display:flex;align-items:center;justify-content:center;gap:8px;}
        .name{font-size:17px;font-weight:600;}
        .num{font-size:16px;font-weight:600;color:#b8860b;}
        .note{color:#8e8e93;font-size:12px;margin:10px 0 14px;}
        .btns{display:flex;gap:10px;justify-content:center;}
        .btn{flex:1;max-width:220px;padding:12px 0;border-radius:999px;font-size:15px;font-weight:600;text-align:center;text-decoration:none;}
        .btn.call{background:#1f3a5f;color:#fff;}
        .btn.copy{background:#f0f0f2;color:#1c1c1e;border:none;}
        .foot{text-align:center;color:#8e8e93;font-size:12px;padding:18px 0 26px;}
        #toast{position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 18px;border-radius:8px;font-size:14px;z-index:999;display:none;}
        #lb{position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:999;display:none;}
        #lbImg{position:absolute;inset:0;background-size:contain;background-position:center;background-repeat:no-repeat;}
        #lbPrev{position:absolute;left:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbNext{position:absolute;right:6px;top:50%;transform:translateY(-50%);color:#fff;font-size:44px;padding:10px 16px;cursor:pointer;user-select:none;}
        #lbClose{position:absolute;top:12px;right:12px;color:#fff;font-size:26px;padding:10px;cursor:pointer;user-select:none;}
        #lbCnt{position:absolute;bottom:22px;left:0;right:0;text-align:center;color:rgba(255,255,255,.85);font-size:14px;user-select:none;}
        </style>
        </head>
        <body oncontextmenu="return false">
        <div class="wrap">
        <div id="listView">
          <div class="hero2">
            <h1 class="coll-title">\(escapeHTML(title))</h1>
            <div class="coll-sub">点击房源卡片查看详情</div>
          </div>
          <div class="items">
        \(itemsHTML)
          </div>
          <!-- v1.26：合集列表页底部也加名片（拨打电话/复制电话），与单套分享页一致 -->
          <!-- v1.27：名片板块换浅蓝底色 + 微信二维码（真实 img，可长按被微信识别）放左侧，信息右移 -->
          <section class="card">
            <div class="\(qrWrapClass)">
              \(qrCol)
              <div class="card-info">
                <div class="tag">米兰租赁管家 · 专业省心租好房</div>
                <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
                <div class="note">微信同号 · 24小时可约看房</div>
                <div class="btns">
                  <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                  <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
                </div>
              </div>
            </div>
          </section>
          <div class="foot">更多优质房源请与我联系-\(escapeHTML(phone))</div>
        </div>
        <div id="detailView" style="display:none">
          <button class="back" type="button" onclick="showList()">‹ 返回房源列表</button>
          <div id="detailBody"></div>
          <button class="back" type="button" onclick="showList()">返回房源列表</button>
        </div>
        </div>
        <div class="mask" id="mask" style="display:none" onclick="hideModal()"><img id="modalImg" src="" alt=""></div>
        <div id="toast"></div>
        <div id="lb"><div id="lbImg"></div><div id="lbPrev" onclick="lbPrev()">‹</div><div id="lbNext" onclick="lbNext()">›</div><div id="lbClose" onclick="lbClose()">✕</div><div id="lbCnt"></div></div>
        <script>
        var GALLERY=[\(galleryJS)];var gi=0;
        function playVideo(w,src){var v=w.querySelector('video');if(!v.src){v.src=src;}var p=v.play();if(p&&p.catch){p.catch(function(){});}w.className=w.className+' playing';}
        var ROOMS=[\(roomsJS)];
        function showDetail(i){document.getElementById('listView').style.display='none';document.getElementById('detailView').style.display='block';document.getElementById('detailBody').innerHTML=ROOMS[i];window.scrollTo(0,0);}
        function showList(){document.getElementById('detailView').style.display='none';document.getElementById('listView').style.display='block';window.scrollTo(0,0);}
        function openImg(i){gi=i;show();}
        function show(){var d=document.getElementById('lb');document.getElementById('lbImg').style.backgroundImage="url('"+GALLERY[gi]+"')";document.getElementById('lbCnt').textContent=(gi+1)+' / '+GALLERY.length;d.style.display='block';}
        function lbPrev(){gi=(gi-1+GALLERY.length)%GALLERY.length;show();}
        function lbNext(){gi=(gi+1)%GALLERY.length;show();}
        function lbClose(){document.getElementById('lb').style.display='none';}
        var _sx=0;(function(){var d=document.getElementById('lb');d.addEventListener('touchstart',function(e){_sx=e.touches[0].clientX},{passive:true});d.addEventListener('touchend',function(e){var dx=e.changedTouches[0].clientX-_sx;if(Math.abs(dx)>50){dx<0?lbNext():lbPrev();}},{passive:true});})();
        function toast(msg){var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){t.style.display='none'},1600);}
        function showModal(src){
          document.getElementById("modalImg").src = src;
          document.getElementById("mask").style.display = "flex";
        }
        function hideModal(){ document.getElementById("mask").style.display = "none"; }
        document.getElementById("list").addEventListener("click", function(e){
          var card = e.target.closest(".card");
          if(!card) return;
          var h = ROOMS[parseInt(card.getAttribute("data-i"))];
          if(!h) return;
          if(h.share){ location.href = h.share; return; }
          if(h.cover){ showModal(h.cover, h.layout); }
        });
        function copyPhone(){var p='\(phone)';function done(){toast('已复制 '+p)}function fb(){var i=document.createElement('input');i.value=p;document.body.appendChild(i);i.select();i.setSelectionRange(0,999);document.execCommand('copy');i.remove();done()}if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(p).then(done,fb)}else{fb()}}
        </script>
        \(trackScript)
        </body>
        </html>
        """
    }

    /// 合集单套详情 HTML：脱敏=户型+导航；完整=房号+户型 / 价格+密码+房东 / 备注。媒体：视频置顶、图片单列。
    /// v1.26：详情底部也加名片（拨打电话/复制电话），与单套分享页一致
    /// v1.27：详情名片同样带微信二维码（真实 <img>，可长按识别）+ 浅蓝底色
    private static func collectionDetailHTML(item: ShareCollectionItem, mode: ShareMode, videoTags: [String], imageURLs: [String], startIndex: Int, name: String, phone: String, qrSrc: String, wm: String = "") -> String {
        var parts: [String] = []
        let qrCol = qrColumnHTML(qrSrc: qrSrc)
        let qrWrapClass = qrSrc.isEmpty ? " qr-wrap center" : " qr-wrap"
        parts.append("<div class=\"dhero\">")
        if mode == .masked {
            parts.append("<div class=\"type\">\(escapeHTML(item.layout.isEmpty ? "房源" : item.layout))</div>")
            parts.append("""
            <a class="loc" href="https://uri.amap.com/search?keyword=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E5%AF%93" target="_blank" rel="noopener">
              <span class="loc-name">利保米兰公馆</span>
              <span class="nav-pill">导航</span>
            </a>
            """)
        } else {
            parts.append("<div class=\"l1\"><span class=\"room\">\(escapeHTML(item.displayRoomNo))</span><span class=\"price\">\(escapeHTML(item.priceText))</span></div>")
            var l2 = "<div class=\"l2\">"
            if !item.password.isEmpty { l2 += "<span class=\"pw\">密码：\(escapeHTML(item.password))</span>" }
            l2 += "<span class=\"layout2\">\(escapeHTML(item.layout.isEmpty ? "房源" : item.layout))</span>"
            if !item.landlord.isEmpty { l2 += "<span class=\"host\">\(escapeHTML(item.landlord))</span>" }
            l2 += "</div>"
            parts.append(l2)
            if !item.remark.isEmpty { parts.append("<div class=\"remark\">\(escapeHTML(item.remark))</div>") }
        }
        parts.append("</div>")
        var media = "<h2 class=\"sec\">实拍 · 点击放大</h2><div class=\"media\">"
        for tag in videoTags { media += tag }
        // v1.25：图片用 <img> 渲染（修复空白），img 自身 pointer-events:none + 外层 div 点击放大——防长按保存
        // v2.15：首屏前 3 张立即加载，其余 loading="lazy"——滚动到才下载，避免一打开把十几张图全拉下来
        for (offset, url) in imageURLs.enumerated() {
            let loadAttr = offset < 3 ? "loading=\"eager\"" : "loading=\"lazy\""
            media += "<div class=\"cellwrap\" onclick=\"openImg(\(startIndex + offset))\"><img class=\"cell\" src=\"\(url)\" \(loadAttr) decoding=\"async\" draggable=\"false\" alt=\"\">\(wm)</div>"
        }
        media += "</div>"
        parts.append(media)
        // v1.26：详情页底部名片（与单套分享页一致），名字电话来自设置页
        parts.append("""
        <section class="card">
          <div class="\(qrWrapClass)">
            \(qrCol)
            <div class="card-info">
              <div class="tag">米兰租赁管家 · 专业省心租好房</div>
              <div class="row"><span class="name">\(escapeHTML(name))</span><span class="num">\(escapeHTML(phone))</span></div>
              <div class="note">微信同号 · 24小时可约看房</div>
              <div class="btns">
                <a class="btn call" href="tel:\(escapeHTML(phone))">拨打电话</a>
                <button class="btn copy" type="button" onclick="copyPhone()">复制电话</button>
              </div>
            </div>
          </div>
        </section>
        """)
        return parts.joined(separator: "")
    }

    /// 媒体块：视频封面播放器原样输出（置顶），图片用 <img> 渲染（单列、防长按保存、点击放大进 GALLERY）
    /// v1.25：图片从 background-image div 改为 <img>（修复微信 WebView 缩略图空白）；
    ///   img 包在 .cellwrap 里且自身 pointer-events:none——长按落在外层 div 上，微信不会弹「保存图片」
    private static func mediaBlockHTML(videoTags: [String], imageURLs: [String], wm: String = "") -> String {
        var parts: [String] = []
        for tag in videoTags { parts.append(tag) }
        // v2.15：同 collectionDetailHTML，首屏 3 张立即加载、其余懒加载
        for (index, url) in imageURLs.enumerated() {
            let loadAttr = index < 3 ? "loading=\"eager\"" : "loading=\"lazy\""
            parts.append("<div class=\"cellwrap\" onclick=\"openImg(\(index))\"><img class=\"cell\" src=\"\(url)\" \(loadAttr) decoding=\"async\" draggable=\"false\" alt=\"\">\(wm)</div>")
        }
        guard !parts.isEmpty else { return "" }
        return "<div class=\"media\">" + parts.joined(separator: "") + "</div>"
    }

    /// 户型标题：户型 + 房号中的上下层后缀（如「单间 · 上层」）；无后缀只显示户型
    /// v1.26：户型本身已含「上/下」楼层词（如「单间下层」「独立厨房下层」）时不再拼接后缀，
    /// 彻底避免「独立厨房下层 · 下」这类重复；仅当户型完全不含上下层信息时才补后缀
    private static func layoutTitle(_ layout: String, roomNo: String) -> String {
        let suffix = roomNo.filter { !$0.isNumber && $0 != "-" && $0 != " " && $0 != "." && $0 != "/" }
        var title = layout.isEmpty ? "房源" : layout
        if !suffix.isEmpty {
            // 户型里已带上下层字样（上/下）→ 后缀信息已包含在户型内，不再拼接
            let hasFloorWord = title.contains("上") || title.contains("下")
            if !hasFloorWord, !title.hasSuffix(suffix) {
                title += " · " + suffix
            }
        }
        return title
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - v1.25 视频首帧封面图

    /// 从视频提取首帧生成 JPEG 封面（最长边 640px、质量 0.72，通常几十 KB）。
    /// v1.25：分享页视频封面改用独立首帧图——页面加载只下载小封面图，绝不预取视频流，
    /// 微信没有任何机会自动播放/预载视频；只有用户点击封面 playVideo 才注入视频 src。
    /// 提取失败返回 nil，调用方回退用视频 URL 本身当封面（微信可显示首帧）。
    private static func makeVideoThumbJPEG(from url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        let image = UIImage(cgImage: cgImage)
        let maxSide: CGFloat = 640
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxSide / max(w, h), 1)
        let target = CGSize(width: max(Int(w * scale), 1), height: max(Int(h * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.72)
    }

    /// v1.29：用 UIGraphicsImageRenderer 缩放并输出 JPEG（替代已废弃的 UIGraphicsBeginImageContextWithOptions，
    /// 内存管理更优，避免隐式全局图形上下文在后台线程的告警）
    private static func scaledJPEG(_ image: UIImage, target: CGSize, quality: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - 上传 / 预签名

    /// v1.29：按「媒体类型 + 云端文件扩展名」返回正确 Content-Type。
    /// 修复旧版视频恒返回 video/quicktime 的问题——安卓微信对 video/quicktime（.mov 容器）支持差，
    /// 而 mp4 云端路径应标 video/mp4，否则安卓端可能拒绝播放。
    private static func mimeType(for kind: String, name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if kind == "video" {
            switch ext {
            case "mov": return "video/quicktime"   // 云端已统一转 mp4，此分支仅作兜底
            case "m4v": return "video/x-m4v"
            default: return "video/mp4"
            }
        }
        switch ext {
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        default: return "image/jpeg"
        }
    }

    /// 视频云端文件名统一为 .mp4（安卓/微信可播），本地文件名保持原样（保存 mov/mp4 原文件）。
    /// v2.37：统一走 MediaNaming.cloudName，命名口径只在一处维护。
    private static func cloudVideoName(for localName: String) -> String {
        MediaNaming.cloudName(fileName: localName, kind: "video")
    }

    internal static func upload(data: Data, to remotePath: String, contentType: String, config: CosConfig) async throws {
        let url = try presignedPutURL(for: remotePath, contentType: contentType, config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (respData, response) = try await CosNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // 读取 COS 返回的 XML 错误码（SignatureDoesNotMatch / InvalidAccessKeyId / AccessDenied 等），精确定位 403 原因
            let detail = extractCosError(from: respData)
            let statusText: String
            if let http = response as? HTTPURLResponse {
                statusText = "HTTP \(http.statusCode)"
            } else {
                statusText = "网络响应无效"
            }
            throw CosError.uploadFailed(statusText + (detail.isEmpty ? "" : "（" + detail + "）"))
        }
    }

    /// v2.9（P1-6）：文件流式上传——URLSession.uploadTask(fromFile:) 由系统按文件句柄分块读取，
    /// 不把整个媒体读进内存，大视频/大图上传不再 OOM 闪退。返回前校验 COS 响应码。
    internal static func uploadFile(_ fileURL: URL, to remotePath: String, contentType: String, config: CosConfig) async throws {
        let url = try presignedPutURL(for: remotePath, contentType: contentType, config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (respData, response) = try await CosNetwork.session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = extractCosError(from: respData)
            let statusText: String
            if let http = response as? HTTPURLResponse {
                statusText = "HTTP \(http.statusCode)"
            } else {
                statusText = "网络响应无效"
            }
            throw CosError.uploadFailed(statusText + (detail.isEmpty ? "" : "（" + detail + "）"))
        }
    }

    /// v2.9（P1-6）：带字节级进度的文件流式上传（分享/补传大媒体时显示百分比；同样不整读进内存）
    internal static func uploadFileWithProgress(_ fileURL: URL, to remotePath: String, contentType: String, config: CosConfig, progress: @escaping (Double) -> Void, speed: ((Double) -> Void)? = nil) async throws {
        let url = try presignedPutURL(for: remotePath, contentType: contentType, config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = CosUploadProgressDelegate(onProgress: progress, onSpeed: speed)
        let session = CosNetwork.makeSession(delegate: delegate)
        let task = session.uploadTask(with: request, fromFile: fileURL)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.onCompletion = { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
            task.resume()
        }
    }

    /// v1.40 第2点：HEAD 探测桶内对象是否存在（省流量，不下载对象体）
    static func remoteObjectExists(path: String, config: CosConfig) async -> Bool {
        guard let url = try? presignedURL(for: path, method: "HEAD", expires: 300, headers: [], config: config) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await CosNetwork.session.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// v1.40 第5点：上传单个房源媒体到共享区 h/<房号>/（图片直传；视频转 mp4 + 用户区首帧图）。
    /// 供 HouseMediaUploadQueue 自动补传；与 shareCard 内媒体上传逻辑保持一致。
    /// v2.52：加阶段回调（转码/上传）、字节进度、断网快速失败、整体看门狗、手动取消响应。
    static func uploadHouseMedia(fileName: String,
                                 kind: String,
                                 roomKey: String,
                                 config: CosConfig,
                                 compress: Bool,
                                 onStage: ((String) -> Void)? = nil,
                                 onTranscodeProgress: ((Double) -> Void)? = nil,
                                 onBytes: ((Double) -> Void)? = nil,
                                 onSpeed: ((Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        // 断网快速失败：最多等 1 秒防瞬态，仍不可达就直接挂任务中心，不傻等
        guard await NetworkMonitor.shared.awaitReachable(timeout: 1.0) else {
            throw CosError.uploadFailed("网络不可用，已挂到任务中心，联网后可点重试")
        }
        let url = MediaStore.url(for: fileName, roomKey: roomKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CosError.uploadFailed("本地文件不存在")
        }
        let isVideo = kind == "video"
        let remoteName = isVideo ? cloudVideoName(for: fileName) : fileName
        let remotePath = "h/\(roomKey)/\(remoteName)"
        // 桶内已存在 → 幂等跳过（不重复覆盖）
        if await remoteObjectExists(path: remotePath, config: config) { return }
        let contentType = mimeType(for: kind, name: remoteName)
        let work: () async throws -> Void = {
            if isVideo {
                // 转码失败（返回 nil）时绝不能把原始 .mov 字节以 .mp4 文件名/video/mp4 直传——
                // 那会产出微信无法播放的「假 mp4」。失败直接抛错，保留本地文件待重试。
                onStage?("视频转码中")
                guard let mp4 = await uploadVideoData(from: url, compress: compress, onProgress: onTranscodeProgress) else {
                    throw CosError.uploadFailed("视频转码 MP4 失败，已取消上传")
                }
                try Task.checkCancellation()
                onStage?("视频上传中")
                try await uploadWithProgress(data: mp4, to: remotePath, contentType: "video/mp4",
                                             config: config, progress: { onBytes?($0) },
                                             speed: { onSpeed?($0) })
            } else if compress, let compressed = compressedImageData(from: url) {
                onStage?("图片上传中")
                try await uploadWithProgress(data: compressed, to: remotePath, contentType: "image/jpeg",
                                             config: config, progress: { onBytes?($0) },
                                             speed: { onSpeed?($0) })
            } else {
                onStage?("图片上传中")
                try await uploadFileWithProgress(url, to: remotePath, contentType: contentType,
                                                 config: config, progress: { onBytes?($0) },
                                                 speed: { onSpeed?($0) })
            }
            // 视频同步补用户区首帧图（每次重新生成，与分享逻辑一致）
            if isVideo, let thumbData = makeVideoThumbJPEG(from: url) {
                try? await upload(data: thumbData, to: "\(CloudUser.sharePagePrefix)\(roomKey)/\(fileName).vthumb.jpg",
                                  contentType: "image/jpeg", config: config)
            }
        }
        // 整体看门狗：视频 180 秒、图片 90 秒必须出结果（成功或失败），不再无限等待
        try await CosNetwork.run(seconds: isVideo ? 180 : 90, work)
    }

    /// v1.13 需求13：带字节级进度的上传（房源分享上传到桶时显示百分比）。
    /// progress 0~1 回调（后台线程回调，调用方自行切主线程）。
    internal static func uploadWithProgress(data: Data, to remotePath: String, contentType: String, config: CosConfig, progress: @escaping (Double) -> Void, speed: ((Double) -> Void)? = nil) async throws {
        let url = try presignedPutURL(for: remotePath, contentType: contentType, config: config)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let delegate = CosUploadProgressDelegate(onProgress: progress, onSpeed: speed)
        let session = CosNetwork.makeSession(delegate: delegate)
        let task = session.uploadTask(with: request, from: data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.onCompletion = { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
            task.resume()
        }
    }

    /// 从 COS 错误响应 XML 中提取 Error Code 与 Message
    internal static func extractCosError(from data: Data) -> String {        guard let text = String(data: data, encoding: .utf8) else { return "" }
        func value(of tag: String) -> String? {
            guard let start = text.range(of: "<\(tag)>")?.upperBound,
                  let end = text[start...].range(of: "</\(tag)>")?.lowerBound else { return nil }
            return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let code = value(of: "Code") ?? ""
        let message = value(of: "Message") ?? ""
        if code.isEmpty { return "" }
        return message.isEmpty ? "错误码 \(code)" : "错误码 \(code)：\(message)"
    }

    /// v1.19：配置了自定义域名就用它（Host 与签名都指向自定义域名，微信按网页抓取）；
    /// 未配置时回退 COS 默认域名（2024 年后新建桶默认域名强制下载，微信会识别成文件——仅作兜底）
    /// v1.20：自动剥离用户误填的 https:// / http:// 前缀和尾部斜杠
    internal static func host(for config: CosConfig) -> String {
        var domain = config.customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !domain.isEmpty {
            for prefix in ["https://", "http://"] {
                if domain.lowercased().hasPrefix(prefix) {
                    domain = String(domain.dropFirst(prefix.count))
                }
            }
            while domain.hasSuffix("/") {
                domain.removeLast()
            }
            return domain
        }
        return "\(config.bucket).cos.\(config.region).myqcloud.com"
    }

    /// PUT 预签名：Content-Type 参与签名（COS 要求请求携带的 header 必须在签名中，否则返回 403）
    internal static func presignedPutURL(for path: String, contentType: String, config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: "PUT", expires: 3600, headers: [("content-type", contentType)], config: config)
    }

    /// GET 预签名：只签 host（下载/访问链接不带自定义 header）
    internal static func presignedGetURL(for path: String, expires: Int, config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: "GET", expires: expires, headers: [], config: config)
    }

    /// v1.13：ListObjectsV2 列出桶内对象（前缀匹配，分页自动翻页）。
    /// 返回 [(对象路径, 大小, 修改时间)]，路径为含前缀的完整对象 key（如 backups/快速_xxx.zip）。
    /// 用途：①备份查看页「刷新」实时同步桶内备份；②回收站彻底删除房源时列出 h/<房号>/ 前缀对象
    /// delimiter 传 "/" 时只返回该前缀下的「直接对象」（不含子目录内对象），用于跳过 backups/media/ 海量媒体镜像
    internal static func listObjects(prefix: String, delimiter: String? = nil, config: CosConfig) async throws -> [(name: String, size: Int64, date: Date)] {
        var result: [(name: String, size: Int64, date: Date)] = []
        var continuationToken: String?
        repeat {
            var params: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("encoding-type", "url")]
            if let delimiter = delimiter {
                params.append(("delimiter", delimiter))
            }
            if let token = continuationToken {
                params.append(("continuation-token", token))
            }
            let url = try presignedURL(for: "", method: "GET", expires: 300, headers: [], params: params, config: config)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw CosError.uploadFailed("云端列表获取失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）" + extractCosError(from: data))
            }
            guard let xml = String(data: data, encoding: .utf8) else { break }
            // 解析 <Contents> 块：<Key>…</Key><LastModified>…</LastModified><Size>…</Size>
            let blocks = extractContentsBlocks(from: xml)
            for block in blocks {
                guard let key = tagValue("Key", in: block) else { continue }
                let size = Int64(tagValue("Size", in: block) ?? "0") ?? 0
                let date = parseCOSDate(tagValue("LastModified", in: block))
                result.append((name: percentDecode(key), size: size, date: date))
            }
            // v1.71：解析 <CommonPrefixes><Prefix>…</Prefix></CommonPrefixes>——delimiter="/" 时
            // COS 用 CommonPrefixes 返回「目录子项」（如 h/1-2059/），方案 A 账本 fetchAll 依赖它列房号目录。
            let prefixBlocks = extractCommonPrefixes(from: xml)
            for pref in prefixBlocks {
                result.append((name: percentDecode(pref), size: 0, date: .distantPast))
            }
            // 分页：IsTruncated=true 且带 NextContinuationToken
            if let truncated = tagValue("IsTruncated", in: xml), truncated == "true",
               let next = tagValue("NextContinuationToken", in: xml), !next.isEmpty {
                continuationToken = percentDecode(next)
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil
        return result
    }

    /// 从 ListObjectsV2 响应 XML 中切出所有 <Contents>…</Contents> 块
    private static func extractContentsBlocks(from xml: String) -> [String] {
        var blocks: [String] = []
        var rest = xml[...]
        while let start = rest.range(of: "<Contents>"), let end = rest[start.upperBound...].range(of: "</Contents>") {
            blocks.append(String(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return blocks
    }

    /// v1.71：解析 XML 中全部 <CommonPrefixes> 块的 <Prefix> 值（delimiter="/" 时的目录子项）
    private static func extractCommonPrefixes(from xml: String) -> [String] {
        var results: [String] = []
        var rest = xml[...]
        while let start = rest.range(of: "<CommonPrefixes>"), let end = rest[start.upperBound...].range(of: "</CommonPrefixes>") {
            let block = String(rest[start.upperBound..<end.lowerBound])
            if let p = tagValue("Prefix", in: block) {
                results.append(p)
            }
            rest = rest[end.upperBound...]
        }
        return results
    }

    /// 取 XML 单标签文本
    private static func tagValue(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>")?.upperBound,
              let end = xml[start...].range(of: "</\(tag)>")?.lowerBound else { return nil }
        return String(xml[start..<end])
    }

    /// COS LastModified 格式：2026-10-23T01:26:00.000Z（ISO8601）
    /// b119：补 .withFractionalSeconds——COS 时间戳带毫秒（.000Z），默认 ISO8601 解析失败返回 .distantPast，
    /// 导致轻量变更感知的基线里时间恒为 distantPast、大小不变时永远检测不到变化（变更感知「没生效」的根因）
    private static func parseCOSDate(_ text: String?) -> Date {
        guard let text = text, !text.isEmpty else { return .distantPast }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text) ?? .distantPast
    }

    /// encoding-type=url 时 Key/Token 为百分号编码，解码回原样
    private static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// COS V5 签名：q-sign-algorithm=sha1;q-ak=...;q-sign-time=...;q-key-time=...;q-header-list=...;q-url-param-list=...;q-signature=...
    /// 关键（严格按 COS 官方规范文档 436/7778 及官方 Python SDK cos_auth.py）：
    /// 1. HttpString = HttpMethod\nUriPathname\nHttpParameters\nHttpHeaders\n —— 恰好 3 个换行分隔 4 段，末尾再一个换行（参数为空时是两个连续换行）
    /// 2. 【根因修复】UriPathname 必须用【未编码】的原样路径参与签名（服务端会用解码后的请求路径重算校验）；
    ///    实际请求 URL 的 path 才做百分号编码
    /// 3. HttpHeaders 的 key 小写、value 按 RFC3986 编码、按字典序拼接
    /// 4. q-header-list 用分号分隔参与签名的 header key
    internal static func presignedURL(for path: String, method: String, expires: Int, headers: [(String, String)], config: CosConfig) throws -> URL {
        try presignedURL(for: path, method: method, expires: expires, headers: headers, params: [], config: config)
    }

    /// v1.13：带 URL query 参数的预签名（ListObjects 等需要）。query 参数 key 按字典序参与 HttpParameters 段与 q-url-param-list。
    internal static func presignedURL(for path: String, method: String, expires: Int, headers: [(String, String)], params: [(String, String)], config: CosConfig) throws -> URL {
        let now = Int(Date().timeIntervalSince1970)
        let signTime = "\(now);\(now + expires)"
        let keyTime = signTime

        let hostValue = host(for: config)
        let rawPath = "/" + path
        // 请求 URL 的路径做百分号编码（保留 /），中文房号目录会被编码
        let encodedPath = rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath

        // 组装签名 headers：key 小写、value RFC3986 编码，排序后拼接
        var pairs = headers.map { (key: $0.0.lowercased(), value: urlEncode($0.1)) }
        pairs.append(("host", hostValue.lowercased()))
        pairs.sort { $0.key < $1.key }
        let headerList = pairs.map(\.key).joined(separator: ";")
        let headerValue = pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        // v1.13：URL query 参数（ListObjects 等）——key 原样（已小写）、value RFC3986 编码，按字典序
        // 临时凭证：x-cos-security-token 必须作为 URL 参数参与签名，COS 才认可
        var allParams = params
        if config.isUsingSTS {
            allParams.append(("x-cos-security-token", config.sessionToken))
        }
        let sortedParams = allParams.map { (key: $0.0.lowercased(), value: urlEncode($0.1)) }.sorted { $0.key < $1.key }
        let paramList = sortedParams.map(\.key).joined(separator: ";")
        let paramValue = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        let signKey = HMAC_SHA1(key: config.secretKey, message: keyTime)
        // HttpString 段结构：method\n路径\n参数\n请求头\n（参数为空时是两个连续换行）
        // 路径必须用未编码的 rawPath 参与签名（官方规范），请求 URL 才用 encodedPath
        let httpString = "\(method.lowercased())\n\(rawPath)\n\(paramValue)\n\(headerValue)\n"
        let sha1Http = SHA1(hexString: httpString)
        let stringToSign = "sha1\n\(signTime)\n\(sha1Http)\n"
        let signature = HMAC_SHA1(key: signKey, message: stringToSign)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = hostValue
        comps.percentEncodedPath = encodedPath
        // query 拼接：业务参数 + 签名参数
        var queryParts = sortedParams.map { "\($0.key)=\($0.value)" }
        queryParts.append("q-sign-algorithm=sha1&q-ak=\(config.secretId)&q-sign-time=\(signTime)&q-key-time=\(keyTime)&q-header-list=\(headerList)&q-url-param-list=\(paramList)&q-signature=\(signature)")
        comps.percentEncodedQuery = queryParts.joined(separator: "&")
        guard let url = comps.url else { throw CosError.invalidConfig }
        return url
    }

    /// RFC 3986 严格百分号编码（保留 A-Z a-z 0-9 - _ . ~）
    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? s
    }

    // MARK: - v1.19 新增：压缩封面 / 版本参数

    /// 生成微信 og:image 压缩封面：最长边 400px、JPEG 质量 0.72（通常几十 KB），微信服务端秒抓
    private static func makeCoverJPEG(from url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let maxSide: CGFloat = 400
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxSide / max(w, h), 1)
        let target = CGSize(width: max(Int(w * scale), 1), height: max(Int(h * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.72)
    }

    // MARK: - v1.27 名片微信二维码压缩

    /// 生成名片二维码上传图：先居中裁剪成正方形（保证 H5 上 object-fit:cover 不裁掉二维码主体），
    /// 再缩到长边 400px、JPEG q0.85（清晰且省流量）。读取失败返回 nil，调用方跳过二维码显示。
    private static func makeQRCodeJPEG() -> Data? {
        guard let data = QrcodeStore.loadData(),
              let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        // 1. 居中裁剪成正方形
        let x = (image.size.width - side) / 2
        let y = (image.size.height - side) / 2
        let cropFormat = UIGraphicsImageRendererFormat.default()
        cropFormat.scale = 1
        let cropRenderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: cropFormat)
        let cropped = cropRenderer.image { _ in
            image.draw(in: CGRect(x: -x, y: -y, width: image.size.width, height: image.size.height))
        }
        // 2. 缩到最长边 400
        let maxSide: CGFloat = 400
        let scale = min(maxSide / side, 1)
        let target = CGSize(width: max(Int(side * scale), 1), height: max(Int(side * scale), 1))
        return scaledJPEG(cropped, target: target, quality: 0.85)
    }

    // MARK: - v1.23 分享时压缩（视频 720p / 图片轻压缩）

    /// v2.15：视频压缩对齐实测样本参数——长边 960（横屏 960×540、竖屏 540×960）、H.264 平均码率 1.0 Mbps、
    /// AAC 96 kbps、faststart。旧实现用 AVAssetExportSession 的 1280x720 预设，只降分辨率不控码率，
    /// 28 秒素材仍输出 9.6 Mbps / 34MB；新实现同素材约 3.9MB（约原来的 1/9）。
    /// 源视频长边不足 960 时不放大；压缩失败返回 nil，调用方回退原文件。
    private static func compressedVideoData(from url: URL, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        let asset = AVURLAsset(url: url)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let duration = (try? await asset.load(.duration)) ?? CMTime(value: 1, timescale: 1)
        let durationSeconds = CMTimeGetSeconds(duration)
        let safeDuration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 1
        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first

        let longSide = max(naturalSize.width, naturalSize.height)
        guard longSide > 0 else { return nil }
        let shrink = min(960.0 / Double(longSide), 1.0)
        var outW = Int((Double(naturalSize.width) * shrink).rounded())
        var outH = Int((Double(naturalSize.height) * shrink).rounded())
        outW -= outW % 2
        outH -= outH % 2
        outW = max(outW, 2)
        outH = max(outH, 2)

        // 码率按像素面积等比缩放：960×540 = 1.0 Mbps，更小的片子相应降低，下限 400 kbps
        let pixelRatio = min(Double(outW * outH) / Double(960 * 540), 1.0)
        let videoBitrate = max(Int(1_000_000 * pixelRatio), 400_000)
        let fps = nominalFPS > 1 ? max(Int(nominalFPS.rounded()), 15) : 30

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any]
        ]

        guard let writer = try? AVAssetWriter(outputURL: temp, fileType: .mp4),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ] as [String: Any]
        )

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { return nil }
        reader.add(videoOutput)

        // 音频同样按样本参数重编码：解成 PCM → AAC 96 kbps
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 96_000
            ]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                audioOutput = out
                audioInput = input
            }
        }

        guard writer.startWriting(), reader.startReading() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        let cancelFlag = CancellationFlag()
        let finished: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue(label: "cos.video.compress").async {
                var ok = true
                let deadline = Date().addingTimeInterval(170)
                var lastProgressAt = Date.distantPast

                func drainAudio() {
                    guard let input = audioInput, let output = audioOutput else { return }
                    while input.isReadyForMoreMediaData, let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) {
                            ok = false
                            return
                        }
                    }
                }

                while ok {
                    if cancelFlag.isCancelled {
                        ok = false
                        break
                    }
                    if Date() > deadline {
                        ok = false
                        break
                    }
                    if !videoInput.isReadyForMoreMediaData {
                        drainAudio()
                        Thread.sleep(forTimeInterval: 0.002)
                        continue
                    }
                    guard let sample = videoOutput.copyNextSampleBuffer() else { break }
                    // v2.60：按帧时间戳推进转码百分比；每 100ms 最多回调一次，避免主线程被刷屏。
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    let fraction = pts.isFinite ? min(max(pts / safeDuration, 0), 1) : 0
                    let now = Date()
                    if now.timeIntervalSince(lastProgressAt) >= 0.1 {
                        lastProgressAt = now
                        onProgress?(fraction)
                    }
                    autoreleasepool {
                        guard let srcBuffer = CMSampleBufferGetImageBuffer(sample),
                              let pool = adaptor.pixelBufferPool else {
                            ok = false
                            return
                        }
                        var dstRef: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstRef) == kCVReturnSuccess,
                              let dst = dstRef else {
                            ok = false
                            return
                        }
                        let sourceImage = CIImage(cvPixelBuffer: srcBuffer)
                        let scaleX = CGFloat(outW) / CGFloat(CVPixelBufferGetWidth(srcBuffer))
                        let scaleY = CGFloat(outH) / CGFloat(CVPixelBufferGetHeight(srcBuffer))
                        let scaled = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                        ciContext.render(scaled, to: dst, bounds: outRect, colorSpace: colorSpace)
                        if !adaptor.append(dst, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample)) {
                            ok = false
                        }
                    }
                    drainAudio()
                }

                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                if ok, writer.status == .writing {
                    writer.endSession(atSourceTime: duration)
                    writer.finishWriting {
                        let completed = writer.status == .completed
                        if completed { onProgress?(1.0) }
                        cont.resume(returning: completed)
                    }
                } else {
                    writer.cancelWriting()
                    reader.cancelReading()
                    cont.resume(returning: false)
                }
            }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
        guard finished, let data = try? Data(contentsOf: temp) else { return nil }
        return data
    }

    /// v1.29：视频上传数据统一转 mp4（安卓/微信可播）：
    /// - 压缩开关开 → 先手动重编码控码率；异常时回退系统 720p 导出，避免个别 mov/HEVC 素材卡在手动 reader/writer
    /// - 压缩开关关 → 原质量转封装（先 passthrough 只换容器、秒级完成且画质零损失；失败回退原质量重编码）
    /// - 源已是 mp4 且不压缩 → 直接读原数据（零处理）
    private static func uploadVideoData(from url: URL, compress: Bool, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        if !compress, url.pathExtension.lowercased() == "mp4" {
            onProgress?(1.0)
            return try? Data(contentsOf: url)
        }
        if compress {
            if let data = await compressedVideoData(from: url, onProgress: onProgress) {
                return data
            }
            if Task.isCancelled { return nil }
            if let data = await exportedCompressedVideoData(from: url, onProgress: onProgress) {
                return data
            }
            if Task.isCancelled { return nil }
            return await mp4ContainerData(from: url, onProgress: onProgress)
        }
        return await mp4ContainerData(from: url, onProgress: onProgress)
    }

    /// v2.60 兜底：手动 AVAssetReader/Writer 对部分 HEVC/可变帧率素材不稳时，回到旧版系统导出预设。
    /// 系统导出会完成容器重封装与兼容性转码，宁可体积略大，也不能让视频必然上传失败。
    private static func exportedCompressedVideoData(from url: URL, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        export.outputURL = temp
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await runExportWithProgress(export, from: 0, to: 1, onProgress: onProgress)
        guard export.status == .completed, let data = try? Data(contentsOf: temp) else { return nil }
        return data
    }

    /// 原质量转 mp4 封装：先 passthrough（不重编码，mov→mp4 秒级，画质零损失），
    /// 不适用时回退 AVAssetExportPresetHighestQuality 原质量重编码。全失败返回 nil，调用方保留原文件。
    private static func mp4ContainerData(from url: URL, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        let asset = AVURLAsset(url: url)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            export.outputURL = temp
            export.outputFileType = .mp4
            await runExportWithProgress(export, from: 0, to: 0.5, onProgress: onProgress)
            if export.status == .completed, let data = try? Data(contentsOf: temp) {
                onProgress?(1.0)
                return data
            }
            if Task.isCancelled { return nil }
        }

        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) {
            export.outputURL = temp
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await runExportWithProgress(export, from: 0.5, to: 1.0, onProgress: onProgress)
            if export.status == .completed, let data = try? Data(contentsOf: temp) {
                return data
            }
        }
        return nil
    }

    /// v2.60：AVAssetExportSession 没有逐帧回调，用 100ms 轮询 progress 把转码百分比送给卡片；
    /// `from/to` 用于 passthrough → 原质量重编码的两次尝试，避免回退时进度归零。
    private static func runExportWithProgress(_ export: AVAssetExportSession,
                                              from start: Double,
                                              to end: Double,
                                              onProgress: ((Double) -> Void)?) async {
        let poll = Task {
            while !Task.isCancelled {
                let status = export.status
                guard status == .exporting || status == .waiting else { break }
                let p = min(max(Double(export.progress), 0), 1)
                onProgress?(start + (end - start) * p)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }
        } onCancel: {
            export.cancelExport()
        }
        poll.cancel()
        onProgress?(end)
    }

    /// 图片轻压缩：长边压到 ≤1600px、JPEG 质量 0.8（参照微信「不加载原图」的画质，不过度压缩，观感基本无损）
    private static func compressedImageData(from url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let maxSide: CGFloat = 1600
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxSide / max(w, h), 1)
        if scale >= 1 {
            return image.jpegData(compressionQuality: 0.8)
        }
        let target = CGSize(width: max(Int(w * scale), 1), height: max(Int(h * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.8)
    }

    /// 在签名 URL 上追加版本参数 v。v 不参与签名（q-url-param-list 为空，COS 服务端忽略未声明参数，签名仍有效）；
    /// 内容更新后 v 变化 → 微信把链接当新链接重新抓取 og，避免命中旧卡片缓存
    private static func appendVersionParameter(_ url: URL, version: String) -> URL {
        let s = url.absoluteString + "&v=" + version
        return URL(string: s) ?? url
    }

    // MARK: - 加密原语（HMAC-SHA1 / SHA1 hex）

    private static func HMAC_SHA1(key: String, message: String) -> String {
        let keyData = Data(key.utf8)
        let msgData = Data(message.utf8)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: msgData, using: SymmetricKey(data: keyData))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func SHA1(hexString: String) -> String {
        let data = Data(hexString.utf8)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - v1.13 上传进度 Delegate（分享上传百分比进度）

private final class CosUploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    private let onSpeed: ((Double) -> Void)?
    var onCompletion: ((Error?) -> Void)?
    private var lastReported: Double = -1
    /// 实时网速：只保留最近约 1 秒的累计字节采样，用滑动窗口算瞬时速度，再做指数平滑。
    private var speedSamples: [(time: TimeInterval, bytes: Int64)] = []
    private var smoothedBytesPerSecond: Double = 0
    private var lastSpeedReportAt: TimeInterval = 0

    init(onProgress: @escaping (Double) -> Void, onSpeed: ((Double) -> Void)? = nil) {
        self.onProgress = onProgress
        self.onSpeed = onSpeed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        reportSpeed(totalBytesSent: totalBytesSent)
        let p = min(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 1.0)
        if p - lastReported >= 0.01 || p >= 1.0 {
            lastReported = p
            onProgress(p)
        }
    }

    /// 1 秒滑动窗口 + 0.75/0.25 指数平滑，避免单次 bytesSent 抖动导致速度乱跳。
    /// UI 最多每 0.5 秒收一次，既跟手又不频繁刷新主线程。
    private func reportSpeed(totalBytesSent: Int64) {
        let now = Date().timeIntervalSinceReferenceDate
        speedSamples.append((now, totalBytesSent))
        while let first = speedSamples.first, now - first.time > 1.0 {
            speedSamples.removeFirst()
        }
        guard let first = speedSamples.first, speedSamples.count >= 2 else { return }
        let elapsed = now - first.time
        let deltaBytes = totalBytesSent - first.bytes
        guard elapsed >= 0.2, deltaBytes > 0 else { return }
        let instant = Double(deltaBytes) / elapsed
        smoothedBytesPerSecond = smoothedBytesPerSecond <= 0
            ? instant
            : smoothedBytesPerSecond * 0.75 + instant * 0.25
        guard now - lastSpeedReportAt >= 0.5 else { return }
        lastSpeedReportAt = now
        onSpeed?(smoothedBytesPerSecond)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?(error)
    }
}

// MARK: - v1.22 合集分享值类型

/// 多选分享合集里的单套房源数据（值类型，Task 内安全传递 + 集合缓存 JSON 编解码）
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

// MARK: - v1.36 分享页水印（CSS 叠加，不动原图、不加桶存储）

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

    static let defaultText = "梁涛-13288251132"
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

// MARK: - v1.38 网页后台刷新（清缓存 + 版本戳）
// App 内「管理后台」是原生界面（直接读云函数接口，天然最新）；safari 打开的网页后台靠版本参数绕缓存。
// 网页后台每次改动（重新部署云函数 admin.html）后，点一次「刷新网页后台缓存」即可让浏览器下次强制取最新页，无需重新构建 App。

enum WebCache {
    private static let stampKey = "cloud.webCacheStamp"
    /// 网页版本戳：每次「刷新网页后台」都更新，safari 打开后台 URL 带上它 → 浏览器缓存立即失效
    static var stamp: String {
        UserDefaults.standard.string(forKey: stampKey) ?? "20261023"
    }
    /// 清 App 内 WebView 缓存 + 更新版本戳
    static func clear(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set("\(Int(Date().timeIntervalSince1970))", forKey: stampKey)
        // v2.68：WKWebsiteDataStore 在 App Extension 不可用，扩展进程只更新版本戳
        #if !APP_EXTENSION
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                 modifiedSince: .distantPast) {
            DispatchQueue.main.async { completion?() }
        }
        #else
        DispatchQueue.main.async { completion?() }
        #endif
    }
}

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

// MARK: - v1.36 水印 / 埋点 / 分享记录辅助（扩展）

extension CosUploader {
    /// 水印设置哈希（缓存校验用；djb2 稳定字符串哈希，不依赖进程内 hashValue）
    static func watermarkHash(_ wm: WatermarkSettings) -> String {
        let s = "\(wm.enabled)|\(wm.text)|\(wm.fontSize)|\(wm.opacity)|\(wm.position.rawValue)|\(wm.offsetX)|\(wm.offsetY)"
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h)
    }

    /// 生成单张图片上的水印覆盖层（空文本或关闭 → 返回空串不渲染）
    static func watermarkOverlayHTML(_ wm: WatermarkSettings) -> String {
        guard wm.enabled, !wm.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let x = max(0, wm.offsetX)
        let y = max(0, wm.offsetY)
        let placement: String
        switch wm.position {
        case .bottomRight: placement = "right:\(x)px;bottom:\(y)px;"
        case .bottomLeft: placement = "left:\(x)px;bottom:\(y)px;"
        case .topRight: placement = "right:\(x)px;top:\(y)px;"
        case .topLeft: placement = "left:\(x)px;top:\(y)px;"
        }
        return "<div class=\"wm\" style=\"position:absolute;\(placement)color:rgba(255,255,255,\(wm.opacity));font-size:\(wm.fontSize)px;font-weight:500;line-height:1;text-shadow:0 1px 2px rgba(0,0,0,.35);pointer-events:none;user-select:none;z-index:2;max-width:70%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;\">\(escapeHTML(wm.text))</div>"
    }

    /// H5 埋点脚本（静默收集，不需用户同意）：GET 云函数 ?act=track&room=&mode=&ref=&t=&uname=
    /// v1.46 统计隔离：埋点带当前用户名，云端按用户分文件统计，互不干扰
    static func cloudTrackScript(room: String, mode: String) -> String {
        let url = CloudConfig.functionURL
        let roomEsc = escapeHTML(room)
        let modeEsc = escapeHTML(mode)
        let unameEsc = escapeHTML(CloudUser.username)
        return "<script>(function(){try{var u='\(url)';if(!u||u.indexOf('http')!==0)return;var k='gy_tk_'+encodeURIComponent('\(roomEsc)')+'_'+encodeURIComponent('\(modeEsc)');var now=Date.now(),last=0;try{last=parseInt(localStorage.getItem(k)||'0',10)||0;}catch(e){}if(now-last<30000)return;try{localStorage.setItem(k,String(now));}catch(e){}var r=(document.referrer||'').slice(0,120);var img=new Image();img.src=u+'?act=track&room='+encodeURIComponent('\(roomEsc)')+'&mode='+encodeURIComponent('\(modeEsc)')+'&ref='+encodeURIComponent(r)+'&t='+now+'&uname='+encodeURIComponent('\(unameEsc)');}catch(e){}})();</script>"
    }

    /// 文件名安全化：保留中文/字母/数字/-/_，其余替换为 -（房号 → 分享页文件名）
    static func safeFileName(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " || ch == "." || ch == "/" || ch == ":" || ch == "," || ch == "，" { out.append("-") }
        }
        return out.isEmpty ? "house" : out
    }

    /// 分享页文件名日期时间戳（yyyyMMddHHmmss）
    static func shareTimeTag() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// 读取桶内对象（GET 签名，短时效）
    static func fetchObjectData(path: String, config: CosConfig) async throws -> Data {
        let url = try presignedGetURL(for: path, expires: 300, config: config)
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)"])
        }
        // v1.42：区分「对象不存在(404)」与「其他读取失败」——404 供 fetchAll 判空，
        //         网络/HTTP 错误必须上抛，绝不能再被当作「云端没有数据」（此前 try? 吞错导致断网误删本地房源）
        if http.statusCode == 404 { throw CosObjectNotFoundError(path: path) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)（HTTP \(http.statusCode)）"])
        }
        return data
    }

    /// v2.62（B8）：带 ETag 的对象读取。
    /// - 有本地副本时带 `If-None-Match`，服务端返回 304 就直接用副本，不重复传数据；
    /// - 无副本 / 304 但副本缺失 → 普通 GET，并落盘内容与 ETag；
    /// - 404 语义与 `fetchObjectData` 完全一致（抛 `CosObjectNotFoundError`），绝不吞成「对象为空」。
    static func fetchObjectDataCached(path: String, cacheKey: String, config: CosConfig) async throws -> Data {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloud-ledger-etag", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyHash = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24).description
        let dataURL = dir.appendingPathComponent("\(keyHash).json")
        let etagURL = dir.appendingPathComponent("\(keyHash).etag")
        let cachedData = try? Data(contentsOf: dataURL)
        let cachedETag = (try? String(contentsOf: etagURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: try presignedGetURL(for: path, expires: 300, config: config))
        if cachedData != nil, let cachedETag, !cachedETag.isEmpty {
            request.setValue(cachedETag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)"])
        }
        if http.statusCode == 304 {
            if let cachedData { return cachedData }
            // 副本不在了：重发一次无条件请求
            let (plainData, plainResp) = try await URLSession.shared.data(
                from: try presignedGetURL(for: path, expires: 300, config: config))
            guard let plainHTTP = plainResp as? HTTPURLResponse else {
                throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)"])
            }
            if plainHTTP.statusCode == 404 { throw CosObjectNotFoundError(path: path) }
            guard plainHTTP.statusCode == 200 else {
                throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)（HTTP \(plainHTTP.statusCode)）"])
            }
            try? plainData.write(to: dataURL)
            if let etag = plainHTTP.value(forHTTPHeaderField: "ETag") {
                try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
            }
            return plainData
        }
        if http.statusCode == 404 { throw CosObjectNotFoundError(path: path) }
        guard http.statusCode == 200 else {
            throw NSError(domain: "CosUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败: \(path)（HTTP \(http.statusCode)）"])
        }
        try? data.write(to: dataURL)
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
        }
        return data
    }

    /// v1.36：分享记录云端化——读改写桶内分享记录
    /// v1.24 改为按用户名隔离：h/_share_records_<用户名>.json，各用户只看自己发的分享
    /// v1.40 第6点：迁移到用户私有目录 users/<用户名>/share_records.json（读取兼容旧路径）
    static func appendShareRecord(roomKey: String, displayRoomNo: String, mode: ShareMode, url: String, config: CosConfig) async throws {
        let path = CloudUser.shareRecordPath
        var records: [[String: String]] = []
        if let data = try? await fetchObjectData(path: path, config: config),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            records = arr
        } else if let data = try? await fetchObjectData(path: CloudUser.legacyShareRecordPath, config: config),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            // v1.40：旧路径有记录（升级前分享过）→ 先读取并随本次一并写入新路径，完成平滑迁移
            records = arr
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "zh_CN")
        records.append([
            "roomKey": roomKey,
            "room": displayRoomNo,
            "mode": mode.modeLabel,
            "time": df.string(from: Date()),
            "url": url
        ])
        if records.count > 500 { records = Array(records.suffix(500)) }
        guard let json = try? JSONSerialization.data(withJSONObject: records) else { return }
        try await upload(data: json, to: path, contentType: "application/json", config: config)
        // v1.40 B5：新路径写入成功后删除旧路径记录，避免桶里新旧两份重复（旧版 App 的兼容读取已废弃）
        if let legacyURL = try? presignedURL(for: CloudUser.legacyShareRecordPath, method: "DELETE", expires: 600, headers: [], config: config) {
            var req = URLRequest(url: legacyURL)
            req.httpMethod = "DELETE"
            if let (_, resp) = try? await URLSession.shared.data(for: req) {
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 204 || http.statusCode == 404 {
                    // 删除成功或已不存在，均视为已清理
                }
            }
        }
    }
}

// MARK: - v1.36 水印设置页（设置 → 房源分享 → 分享水印）

struct WatermarkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var text: String
    @State private var fontSize: Double
    @State private var opacity: Double
    @State private var position: WatermarkPosition
    @State private var offsetX: Double
    @State private var offsetY: Double
    @State private var showPreview = false
    @State private var savedFlash = false

    init() {
        let wm = WatermarkSettingsStore.current
        _enabled = State(initialValue: wm.enabled)
        _text = State(initialValue: wm.text)
        _fontSize = State(initialValue: wm.fontSize)
        _opacity = State(initialValue: wm.opacity)
        _position = State(initialValue: wm.position)
        _offsetX = State(initialValue: wm.offsetX)
        _offsetY = State(initialValue: wm.offsetY)
    }

    private var draft: WatermarkSettings {
        WatermarkSettings(enabled: enabled, text: text, fontSize: fontSize, opacity: opacity, position: position, offsetX: offsetX, offsetY: offsetY)
    }

    var body: some View {
        Form {
            Section {
                // v1.41：Toggle 改用显式 Binding——set 时立即用新值写 store，
                // 不再依赖 onChange 的闭包捕获时序，开关「即拨即生效、返回即显示最新状态」
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        enabled = newValue
                        var wm = WatermarkSettingsStore.current
                        wm.enabled = newValue
                        WatermarkSettingsStore.current = wm
                    }
                )) {
                    Text("分享页加水印")
                }
            } footer: {
                Text("开启后，新生成的分享 H5 会在每张图片右下角叠加水印；已分享出去的旧链接不受影响。关闭即保存，下次分享不带水印。")
            }

            Section("水印内容") {
                TextField("水印文本", text: $text)
                    .textInputAutocapitalization(.never)
                Text("默认：\(WatermarkSettings.defaultText)").font(.footnote).foregroundStyle(.secondary)
            }

            Section("样式") {
                VStack(alignment: .leading) {
                    Text("字号：\(Int(fontSize)) px")
                    Slider(value: $fontSize, in: 10...28, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("透明度：\(Int(opacity * 100))%")
                    Slider(value: $opacity, in: 0.1...0.9, step: 0.05)
                }
                Picker("位置", selection: $position) {
                    ForEach(WatermarkPosition.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }
                VStack(alignment: .leading) {
                    Text("水平偏移：\(Int(offsetX)) pt")
                    Slider(value: $offsetX, in: 0...40, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("垂直偏移：\(Int(offsetY)) pt")
                    Slider(value: $offsetY, in: 0...40, step: 1)
                }
            }

            Section {
                Button("预览效果") { showPreview = true }
                Button("保存") {
                    WatermarkSettingsStore.current = draft
                    savedFlash = true
                    dismiss()
                }
                Button("恢复默认样式", role: .destructive) {
                    // v1.40 第1点：只重置文本与样式，不强制打开开关（此前「清除」把开关强制开成 true，用户以为关不掉）
                    text = WatermarkSettings.defaultText
                    fontSize = 14
                    opacity = 0.5
                    position = .bottomRight
                    offsetX = 12
                    offsetY = 12
                    WatermarkSettingsStore.current = draft
                    savedFlash = true
                    dismiss()
                }
            } footer: {
                Text("恢复默认 = 重置水印文本与样式；开关状态保持不变。")
            }
        }
        .navigationTitle("分享水印")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPreview) {
            WatermarkPreviewView(settings: draft)
        }
    }
}

/// 水印预览：模拟分享页里的多张实拍图（利保米兰公馆 · 2-2334），
/// v1.17 需求4：水印叠加在【每张图片】的右下角（与真实 H5 的 mediaBlockHTML 一致），而非页面右下角
struct WatermarkPreviewView: View {
    let settings: WatermarkSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        // 模拟分享页头
                        HStack {
                            Text("利保米兰公馆").font(.headline)
                            Spacer()
                            Text("2-2334").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.white)
                        // 模拟图片区：三张实拍图，每张各自叠加水印
                        VStack(spacing: 12) {
                            sampleImageCard
                            sampleImageCard
                            sampleImageCard
                        }
                        .padding()
                        Text("水印叠加在每张图片的\(settings.position.label)（与真实分享页一致）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom)
                    }
                    .background(Color.white)
                }
            }
            .navigationTitle("水印预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 单张模拟实拍图（右下/四角按设置叠加水印）
    private var sampleImageCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.6, blue: 0.8), Color(red: 0.25, green: 0.4, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 220)
            Text("实拍图示意").font(.caption).foregroundStyle(.white.opacity(0.7)).padding(12)
            watermarkLayer
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var watermarkLayer: some View {
        if settings.enabled && !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let x = max(0, settings.offsetX)
            let y = max(0, settings.offsetY)
            let align: Alignment = switch settings.position {
            case .bottomRight: .bottomTrailing
            case .bottomLeft: .bottomLeading
            case .topRight: .topTrailing
            case .topLeft: .topLeading
            }
            Text(settings.text)
                .font(.system(size: CGFloat(settings.fontSize), weight: .medium))
                .foregroundStyle(.white.opacity(settings.opacity))
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .padding(.trailing, settings.position == .bottomRight || settings.position == .topRight ? CGFloat(x) : 0)
                .padding(.leading, settings.position == .bottomLeft || settings.position == .topLeft ? CGFloat(x) : 0)
                .padding(.bottom, settings.position == .bottomRight || settings.position == .bottomLeft ? CGFloat(y) : 0)
                .padding(.top, settings.position == .topRight || settings.position == .topLeft ? CGFloat(y) : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
                .allowsHitTesting(false)
        }
    }
}

#if !APP_EXTENSION // v2.68：App 内管理后台 UI 依赖 CloudBackupService 全量/RemoteConfigAdminView/UIApplication，扩展不编译
// MARK: - v1.36 App 内管理后台（首页快捷操作 → 管理后台）

/// 云函数返回的获客统计
struct AdminStats: Codable {
    struct ByItem: Codable { let date: String?; let room: String?; let mode: String?; let count: Int }
    struct RecentItem: Codable { let t: String; let room: String; let mode: String; let ref: String }
    let ok: Bool
    let total: Int
    let today: Int
    let byDate: [ByItem]
    let byRoom: [ByItem]
    let byMode: [ByItem]
    let recent: [RecentItem]
}

/// 云函数返回的分享记录
struct AdminShares: Codable {
    let ok: Bool
    let records: [AdminShareRecord]
}
struct AdminShareRecord: Codable, Identifiable {
    var id: String { url }
    let room: String
    let mode: String
    let time: String
    let url: String
}

/// 桶浏览条目（当前层聚合：目录 / 文件）
struct BucketEntry: Identifiable {
    var id: String { name }
    let name: String
    let isDir: Bool
    let size: Int64
    let date: Date?
    let objectCount: Int
}

// MARK: - v1.22 云函数桶浏览 / 储存用量 / 清空统计接口（App 原生后台与网页后台一致）
struct AdminListResponse: Codable {
    let ok: Bool
    let prefix: String
    let dirs: [AdminDir]
    let files: [AdminFile]
}
struct AdminDir: Codable {
    let name: String
    let isDir: Bool
}
struct AdminFile: Codable {
    let key: String
    let name: String
    let size: Int
    let date: String
    let isDir: Bool
}
struct UsageResponse: Codable {
    let ok: Bool
    let total: Int
    let total_files: Int
    let parts: [UsagePart]
}
struct UsagePart: Codable {
    let name: String
    let size: Int
}
struct ClearStatsResponse: Codable {
    let ok: Bool
    let deleted: Int
}

struct AdminDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var stats: AdminStats?
    @State private var shares: [AdminShareRecord] = []
    @State private var statsError: String?
    @State private var loading = false

    // 桶管理
    @State private var bucketPrefix = ""
    @State private var bucketEntries: [BucketEntry] = []
    @State private var bucketLoading = false
    @State private var bucketError: String?
    @State private var copiedKey: String?
    // v1.22 储存用量 / 清空访问统计
    @State private var usage: UsageResponse?
    @State private var usageError: String?
    @State private var confirmClearStats = false
    @State private var clearStatsTip: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("板块", selection: $tab) {
                    Text("获客分析").tag(0)
                    Text("分享记录").tag(1)
                    Text("桶管理").tag(2)
                    Text("远程配置").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if tab == 0 {
                    statsView
                } else if tab == 1 {
                    sharesView
                } else if tab == 2 {
                    bucketView
                } else {
                    // v1.81 远程配置原生化：App 内直接编辑（公告/开关/参数/文案/帮助/更新日志）
                    RemoteConfigAdminView()
                }
            }
            .navigationTitle("管理后台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        // v1.37：原生后台免登录；想用网页版（可手机电脑自适应）可一键跳浏览器，URL 带版本参数强制取最新后台页
                        Button {
                            openWebBackend()
                        } label: {
                            Image(systemName: "safari")
                        }
                        Button {
                            loadAll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear(perform: loadAll)
            .alert("确认清空访问统计？", isPresented: $confirmClearStats) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { clearStats() }
            } message: {
                Text("将删除桶 statistics/ 下全部统计文件（含 test101 等测试记录），重新累计。")
            }
            .alert("清空访问统计", isPresented: Binding(
                get: { clearStatsTip != nil },
                set: { if !$0 { clearStatsTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(clearStatsTip ?? "")
            }
        }
    }

    private func loadAll() {
        loadStats()
        loadShares()
        loadUsage()
        if tab == 2 { loadBucket() }
    }

    /// v1.38：在系统浏览器打开云端后台网页（带免登录口令 + 动态版本戳，网页改动后浏览器强制取最新）
    private func openWebBackend() {
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "\(CloudConfig.functionURL)?act=admin&k=\(CloudConfig.passwordHash)&u=\(u)&v=\(WebCache.stamp)") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: 获客分析

    private var statsView: some View {
        Group {
            if let stats = stats {
                List {
                    // v1.23 清空访问统计按钮（储存用量已移到「桶管理」页）
                    Section {
                        Button("清空访问统计", role: .destructive) {
                            confirmClearStats = true
                        }
                        .font(.subheadline)
                    }
                    Section {
                        HStack {
                            StatCard(title: "累计访问", value: "\(stats.total)")
                            StatCard(title: "今日访问", value: "\(stats.today)")
                        }
                        .listRowInsets(EdgeInsets())
                        .padding(.horizontal)
                    }
                    Section("按日期") {
                        ForEach(stats.byDate, id: \.date) { item in
                            HStack {
                                Text(item.date ?? "—").font(.subheadline)
                                Spacer()
                                Text("\(item.count)").bold().foregroundStyle(.tint)
                            }
                        }
                    }
                    Section("按房号") {
                        ForEach(stats.byRoom, id: \.room) { item in
                            HStack {
                                Text(item.room ?? "—").font(.subheadline)
                                Spacer()
                                Text("\(item.count)").bold().foregroundStyle(.tint)
                            }
                        }
                    }
                    Section("按模式") {
                        ForEach(stats.byMode, id: \.mode) { item in
                            HStack {
                                Text(item.mode ?? "—").font(.subheadline)
                                Spacer()
                                Text("\(item.count)").bold().foregroundStyle(.tint)
                            }
                        }
                    }
                    Section {
                        ForEach(Array(stats.recent.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.room).font(.subheadline).bold()
                                    Text(item.mode).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(item.t).font(.caption).foregroundStyle(.secondary)
                                }
                                if !item.ref.isEmpty {
                                    Text("来源：\(item.ref)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        Text("最近访问")
                    } footer: {
                        // v1.46 统计隔离：明确提示当前统计归属
                        Text("统计仅包含当前用户名「\(CloudUser.displayName)」名下埋点，各用户互不干扰。")
                    }
                }
                .listStyle(.insetGrouped)
            } else if let statsError = statsError {
                ContentUnavailableView {
                    Label("统计加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(statsError)
                } actions: {
                    Button("重试") { loadStats() }
                }
            } else {
                ProgressView("加载统计…")
            }
        }
    }

    /// v1.40 第4点（B4）：云函数请求失败的统一文案——401 明确提示后台口令不匹配，跳转设置页修改
    private func cloudFunctionError(_ resp: URLResponse?, fallback: String) -> String {
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            return "后台口令不匹配（请到 设置→云端配置→后台口令 修改后重试）"
        }
        if let http = resp as? HTTPURLResponse {
            return "云函数请求失败（HTTP \(http.statusCode)），请确认函数已部署且地址正确"
        }
        return fallback
    }

    private func loadStats() {
        stats = nil
        statsError = nil
        // v1.46 统计隔离：带当前用户名，云端只返回该用户的统计
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=stats&k=\(CloudConfig.passwordHash)&u=\(u)") else {
            statsError = "云函数地址无效"
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data,
                  let obj = try? JSONDecoder().decode(AdminStats.self, from: data), obj.ok else {
                DispatchQueue.main.async { statsError = self.cloudFunctionError(resp, fallback: "云函数未返回有效数据（请确认函数已部署）") }
                return
            }
            DispatchQueue.main.async { stats = obj }
        }.resume()
    }

    // MARK: 分享记录

    /// v1.41：分享记录加载完成标志——云函数返回「空记录」时不再无限转圈（此前的三分支缺空态，永远 ProgressView）
    @State private var sharesLoaded = false

    private var sharesView: some View {
        Group {
            if !shares.isEmpty {
                List {
                    Section {
                        ForEach(shares) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(r.room).font(.subheadline).bold()
                                    Text(r.mode).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.tint.opacity(0.12)).clipShape(Capsule())
                                    Spacer()
                                    Text(r.time).font(.caption).foregroundStyle(.secondary)
                                }
                                Button {
                                    UIPasteboard.general.string = r.url
                                    copiedKey = r.url
                                } label: {
                                    Label(copiedKey == r.url ? "已复制" : "复制链接", systemImage: copiedKey == r.url ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                }
                                .foregroundStyle(.tint)
                            }
                        }
                    } footer: {
                        Text("分享记录按用户名隔离存于云端桶（users/<用户名>/share_records.json），各用户只看自己发的分享。")
                    }
                }
                .listStyle(.insetGrouped)
            } else if sharesLoaded {
                // v1.41：空记录终态——「还没有分享过」而非一直转圈
                ContentUnavailableView {
                    Label("暂无分享记录", systemImage: "square.and.arrow.up")
                } description: {
                    Text("分享过房源后，记录会显示在这里。")
                } actions: {
                    Button("刷新") { loadShares() }
                }
            } else if let statsError = statsError {
                ContentUnavailableView {
                    Label("记录加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(statsError)
                } actions: {
                    Button("重试") { loadShares() }
                }
            } else {
                ProgressView("加载分享记录…")
            }
        }
    }

    private func loadShares() {
        shares = []
        statsError = nil
        sharesLoaded = false
        // v1.24：按用户名读自己的分享记录（云函数 do_shares 按 u 过滤）
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=shares&k=\(CloudConfig.passwordHash)&u=\(u)") else {
            statsError = "云函数地址无效"
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data,
                  let obj = try? JSONDecoder().decode(AdminShares.self, from: data), obj.ok else {
                DispatchQueue.main.async { statsError = self.cloudFunctionError(resp, fallback: "云函数未返回分享记录（请确认函数已部署）") }
                return
            }
            DispatchQueue.main.async {
                shares = obj.records
                sharesLoaded = true
            }
        }.resume()
    }

    // MARK: 桶管理

    private var bucketView: some View {
        Group {
            if let config = CosConfig.load(), config.isValid {
                VStack(alignment: .leading, spacing: 0) {
                    if !bucketPrefix.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Button {
                                    bucketPrefix = ""
                                    loadBucket()
                                } label: {
                                    Text("桶根").font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                ForEach(breadcrumbs, id: \.self) { crumb in
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    Button {
                                        bucketPrefix = crumb
                                        loadBucket()
                                    } label: {
                                        Text(crumb.split(separator: "/").last.map(String.init) ?? crumb).font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                    }
                    List {
                        // v1.23 桶储存用量（从获客分析移到桶管理）+ 访问腾讯云储存桶
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("桶储存用量").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { loadUsage() } label: { Image(systemName: "arrow.clockwise") }
                                        .foregroundStyle(.tint)
                                        .buttonStyle(.borderless)
                                }
                                if let usage = usage {
                                    HStack {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(usage.total), countStyle: .file))
                                            .font(.system(size: 24, weight: .bold, design: .rounded))
                                        Text("\(usage.total_files) 个文件").font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(usage.parts, id: \.name) { p in
                                        HStack {
                                            Text(p.name).font(.subheadline)
                                            Spacer()
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file))
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                } else if let usageError = usageError {
                                    HStack {
                                        Text("用量加载失败").font(.subheadline).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("重试") { loadUsage() }.font(.subheadline).buttonStyle(.borderless)
                                    }
                                } else {
                                    ProgressView("加载用量…")
                                }
                            }
                            Button {
                                openCOSConsole()
                            } label: {
                                Label("访问腾讯云储存桶（浏览器登录）", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderless)
                        }
                        Section {
                            ForEach(bucketEntries) { entry in
                                if entry.isDir {
                                    Button {
                                        bucketPrefix = entry.name
                                        loadBucket()
                                    } label: {
                                        HStack {
                                            Image(systemName: "folder").foregroundStyle(.tint)
                                            Text(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)
                                            Spacer()
                                            Text("\(entry.objectCount) 个对象").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "doc").foregroundStyle(.secondary)
                                            Text(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)
                                                .font(.subheadline).lineLimit(1)
                                            Spacer()
                                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if let date = entry.date {
                                            Text(date.formatted(date: .numeric, time: .shortened))
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        HStack(spacing: 12) {
                                            Button {
                                                UIPasteboard.general.string = "\(sharePrefix)\(entry.name)"
                                                copiedKey = entry.name
                                            } label: {
                                                Label(copiedKey == entry.name ? "已复制" : "复制下载链接", systemImage: copiedKey == entry.name ? "checkmark" : "doc.on.doc")
                                                    .font(.caption)
                                            }
                                            .foregroundStyle(.tint)
                                            .buttonStyle(.borderless)
                                            Button(role: .destructive) {
                                                confirmDelete(entry: entry)
                                            } label: {
                                                Label("删除", systemImage: "trash").font(.caption)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text(bucketPrefix.isEmpty ? "桶内对象（含子目录逐级展开）" : "当前目录：\(bucketPrefix.isEmpty ? "桶根" : bucketPrefix)")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            } else {
                ContentUnavailableView {
                    Label("未配置云存储", systemImage: "server.rack")
                } description: {
                    Text("请先在 设置 → 房源分享 → 远程配置 填写 COS 密钥并验证")
                }
            }
        }
    }

    private var sharePrefix: String {
        if let config = CosConfig.load(), !config.customDomain.isEmpty {
            return "https://\(config.customDomain)/"
        }
        return ""
    }

    /// v1.23 跳转腾讯云 COS 控制台（浏览器登录后可直接管理储存桶）
    private func openCOSConsole() {
        if let url = URL(string: "https://console.cloud.tencent.com/cos/bucket") {
            UIApplication.shared.open(url)
        }
    }

    private var breadcrumbs: [String] {
        let segs = bucketPrefix.split(separator: "/").map(String.init)
        var crumbs: [String] = []
        var path = ""
        for s in segs {
            path = path.isEmpty ? s : path + "/" + s
            crumbs.append(path + "/")
        }
        return crumbs
    }

    private func loadBucket() {
        bucketLoading = true
        bucketError = nil
        let prefix = bucketPrefix
        // v1.22 改走云函数 adminList（与网页后台一致）：点进房源文件夹自动展开 media/，图片视频直接显示
        let esc = prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=adminList&k=\(CloudConfig.passwordHash)&prefix=\(esc)") else {
            bucketError = "云函数地址无效"
            bucketLoading = false
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data,
                  let obj = try? JSONDecoder().decode(AdminListResponse.self, from: data), obj.ok else {
                DispatchQueue.main.async { bucketError = self.cloudFunctionError(resp, fallback: "云函数未返回桶数据（请确认函数已部署）"); bucketLoading = false }
                return
            }
            let iso = ISO8601DateFormatter()
            var entries: [BucketEntry] = []
            for d in obj.dirs {
                entries.append(BucketEntry(name: d.name, isDir: true, size: 0, date: nil, objectCount: 0))
            }
            for f in obj.files {
                entries.append(BucketEntry(name: f.name, isDir: false, size: Int64(f.size),
                                           date: iso.date(from: f.date), objectCount: 1))
            }
            DispatchQueue.main.async {
                bucketEntries = entries
                bucketLoading = false
            }
        }.resume()
    }

    /// v1.22 拉取桶储存用量（云函数 usage）
    private func loadUsage() {
        usage = nil
        usageError = nil
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=usage&k=\(CloudConfig.passwordHash)") else {
            usageError = "云函数地址无效"
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data, let obj = try? JSONDecoder().decode(UsageResponse.self, from: data), obj.ok else {
                DispatchQueue.main.async { usageError = self.cloudFunctionError(resp, fallback: "用量加载失败（请确认函数已部署）") }
                return
            }
            DispatchQueue.main.async { usage = obj }
        }.resume()
    }

    /// v1.22 清空访问统计（云函数 clearStats）
    /// v1.46 统计隔离：带当前用户名，只清空当前用户的统计
    private func clearStats() {
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=clearStats&k=\(CloudConfig.passwordHash)&u=\(u)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let msg: String
            if let data = data, let obj = try? JSONDecoder().decode(ClearStatsResponse.self, from: data), obj.ok {
                msg = "已清空 \(obj.deleted) 个统计文件，访问统计已清零"
            } else {
                msg = "清空失败，请稍后再试"
            }
            DispatchQueue.main.async {
                confirmClearStats = false
                clearStatsTip = msg
                loadStats()
                loadUsage()
            }
        }.resume()
    }

    private func confirmDelete(entry: BucketEntry) {
        guard let config = CosConfig.load(), config.isValid else { return }
        let title: String
        let message: String
        // v1.40 第12点：桶管理删除只删云端对象，本地文件一律保留（此前文案「本地与云端同步生效」误导）
        if entry.isDir {
            title = "删除云端目录 \(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)"
            message = "仅删除云端该目录下 \(entry.objectCount) 个对象，本机文件不受影响。删除后不可恢复，确认？"
        } else {
            title = "删除云端文件 \(entry.name.split(separator: "/").last.map(String.init) ?? entry.name)"
            message = "仅删除云端该对象，本机文件不受影响。删除后不可恢复，确认？"
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "仅删云端", style: .destructive) { _ in
            Task {
                do {
                    if entry.isDir {
                        let objects = try await CosUploader.listObjects(prefix: entry.name, config: config)
                        for o in objects {
                            try? await CloudBackupService.deleteRemoteObject(name: o.name, config: config)
                        }
                        try? await CloudBackupService.deleteRemoteObject(name: entry.name, config: config)
                    } else {
                        try await CloudBackupService.deleteRemoteObject(name: entry.name, config: config)
                    }
                    await MainActor.run { loadBucket() }
                } catch {
                    await MainActor.run { bucketError = "删除失败：\(error.localizedDescription)" }
                }
            }
        })
        topViewController()?.present(alert, animated: true)
    }

    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

/// 获客分析顶部指标卡
struct StatCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif // !APP_EXTENSION（管理后台 UI）

// MARK: - v1.19 多用户（用户名）

/// 每台设备一个用户名：操作日志 / 分享 / 统计都带着它；桶内私有数据按用户名分目录隔离。
/// 房源共享走公共区 h/，不受用户名影响。
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
    /// v1.24：多用户数据隔离——用户名不设默认（默认空，不预填「涛」），强制用户自行设置。
    /// 隔离路径里空用户名用「未设置」占位，绝不落到公共前缀（避免不同设备误共用同一目录互相覆盖）。
    /// 返回去首尾空白的用户名；为空返回「未设置」。
    static var safeName: String {
        let t = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未设置" : t
    }
    // MARK: v1.40 云端按用户名分目录（第6点：一个用户名一个文件夹，该用户名下所有私有数据都在里面）
    /// 用户私有根目录：users/<用户名>/
    static var userRootPrefix: String { "users/\(safeName)/" }
    /// 用户私有分享产物（H5 页面 / 封面 / 视频首帧图）：users/<用户名>/shares/
    static var sharePagePrefix: String { "users/\(safeName)/shares/" }
    /// 用户私有名片二维码：users/<用户名>/qrcode.jpg（原公共 h/_qrcode/qr.jpg，避免他用户读到）
    static var qrPath: String { "users/\(safeName)/qrcode.jpg" }
    /// 云端备份隔离前缀：users/<用户名>/backups/（v1.40 从 backups/<用户名>/ 迁移，旧路径读取时兼容）
    static var backupPrefix: String { "users/\(safeName)/backups/" }
    /// 分享记录隔离路径：users/<用户名>/share_records.json（v1.40 从 h/_share_records_<用户名>.json 迁移，读取兼容旧路径）
    static var shareRecordPath: String { "users/\(safeName)/share_records.json" }
    /// v1.40：旧版分享记录路径（读取兼容，迁移期只读）
    static var legacyShareRecordPath: String { "h/_share_records_\(safeName).json" }
    /// v1.40：全量备份的媒体镜像（按 sha1 去重，v1.40 起收进用户目录）：users/<用户名>/media/
    static var mediaMirrorPrefix: String { "users/\(safeName)/media/" }
    /// v1.24：旧版媒体镜像前缀（读取兼容，迁移期只读；不再写入）
    static var legacyMediaMirrorPrefix: String { "backups/media/" }
}

// MARK: - v1.37 云端操作记录（操作日志云端区）
// 同桶多用户对桶的操作（增删改房源、删桶文件、清空统计等）统一记到桶 h/_ops.json，带用户名。
// App 操作日志分「本机操作」（本地）+「云端操作」（桶记录，显示操作者用户名）。

struct CloudOpEntry: Codable, Identifiable, Hashable {
    var id: String { "\(t)|\(op)|\(room)|\(user)|\(detail)" }
    let t: String
    let op: String
    let room: String
    let user: String
    let detail: String
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
    static var isConfigured: Bool {
        !CloudConfig.functionURL.isEmpty && !CloudConfig.passwordHash.isEmpty
    }
    private static var baseURL: URL? { URL(string: CloudConfig.functionURL) }

    /// 本机发起云端操作 → 写一条云端操作记录（带当前用户名）。
    /// v2.67：入口不阻塞调用方，后台等待响应并校验结果；失败入待补队列，启动/回前台自动补推。
    static func log(category: String, action: String, result: String, detail: String, room: String = "") {
        guard isConfigured, baseURL != nil else { return }
        let item = CloudOpPendingQueue.Item(
            category: category, action: action, result: result,
            detail: detail, room: room, uname: CloudUser.username, date: Date())
        Task.detached {
            let ok = await CloudOps.send(item)
            if !ok { CloudOpPendingQueue.enqueue(item) }
        }
    }

    /// 发送单条公共日志，最多 3 次尝试（首次 + 2 次退避 350ms/700ms）；返回是否最终上云成功。
    @discardableResult
    static func send(_ item: CloudOpPendingQueue.Item) async -> Bool {
        guard isConfigured, let base = baseURL else { return false }
        let op = "\(item.category)·\(item.action)·\(item.result)"
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(350 * attempt) * 1_000_000_000)
            }
            do {
                var q = URLComponents()
                q.queryItems = [
                    .init(name: "act", value: "logOp"),
                    .init(name: "k", value: CloudConfig.passwordHash),
                    .init(name: "op", value: op),
                    .init(name: "room", value: item.room),
                    .init(name: "uname", value: item.uname),
                    .init(name: "detail", value: item.detail),
                ]
                guard let query = q.percentEncodedQuery,
                      let url = URL(string: base.absoluteString + "?" + query) else { return false }
                let (data, response) = try await CosNetwork.session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }
                // 对齐电脑端 LooksOk：body 显式 ok=false 才判失败；解析不出 ok 字段视为成功。
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, !ok { continue }
                return true
            } catch {
                continue
            }
        }
        return false
    }

    /// v2.71：分享扩展可靠公共日志——先入共享区待补队再发送、成功才出队。
    /// 扩展进程可能在发送途中被系统回收：fire-and-forget 会丢日志，
    /// 入队在先则 App 启动/回前台 flushPending 必补推，与 v2.67 主 App 口径一致。
    static func logAwait(category: String, action: String, result: String, detail: String = "", room: String = "") async {
        guard isConfigured, baseURL != nil else { return }
        let item = CloudOpPendingQueue.Item(
            category: category, action: action, result: result,
            detail: detail, room: room, uname: CloudUser.username, date: Date())
        CloudOpPendingQueue.enqueue(item)
        let ok = await send(item)
        if ok { CloudOpPendingQueue.remove(item) }
    }

    /// 启动/回前台补推积压的待上云日志；成功出队，仍失败留队等下次。串行发送，避免同时打云函数。
    static func flushPending() async {
        CloudOpPendingQueue.flushExpired()
        guard isConfigured else { return }
        for item in CloudOpPendingQueue.items() {
            let ok = await CloudOps.send(item)
            if ok { CloudOpPendingQueue.remove(item) }
        }
    }

    /// 拉取云端操作记录（日志查看器云端区）
    /// v2.7（P1⑦ 跨账号日志公共区）：不传 u 参数，拉取所有用户的公共日志——
    /// 此前按 u=<自己> 过滤，只能看到自己的操作，另一个用户的记录完全看不到。
    static func fetch(completion: @escaping ([CloudOpEntry]) -> Void) {
        guard isConfigured, let base = baseURL else { completion([]); return }
        guard let url = URL(string: "\(base.absoluteString)?act=ops&k=\(CloudConfig.passwordHash)") else { completion([]); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let obj = try? JSONDecoder().decode(CloudOpsResponse.self, from: data), obj.ok else { completion([]); return }
            completion(obj.records)
        }.resume()
    }

    /// 删除一条云端操作记录（云端区左滑/多选删除）
    static func delete(_ e: CloudOpEntry, completion: (() -> Void)? = nil) {
        guard isConfigured, let base = baseURL else { completion?(); return }
        let u = CloudUser.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var q = URLComponents()
        q.queryItems = [
            .init(name: "act", value: "delOp"), .init(name: "k", value: CloudConfig.passwordHash), .init(name: "u", value: u),
            .init(name: "t", value: e.t), .init(name: "op", value: e.op), .init(name: "room", value: e.room),
            .init(name: "user", value: e.user), .init(name: "detail", value: e.detail),
        ]
        guard let query = q.percentEncodedQuery, let url = URL(string: base.absoluteString + "?" + query) else { completion?(); return }
        URLSession.shared.dataTask(with: url) { _, _, _ in DispatchQueue.main.async { completion?() } }.resume()
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
struct CosObjectNotFoundError: Error, LocalizedError {
    let path: String
    var errorDescription: String? { "云端对象不存在: \(path)" }
}

/// b118（P0③ CAS）：写前校验发现云端记录已被他人更新，放弃覆盖
enum CloudSyncConflict: Error, LocalizedError {
    case recordChanged(roomKey: String, by: String)
    var errorDescription: String? {
        switch self {
        case .recordChanged(let roomKey, let by):
            return "云端「\(roomKey)」刚被 \(by) 更新，已停止覆盖（请刷新后再编辑）"
        }
    }
}

enum CloudHouseSync {
    /// 单套账本对象路径（媒体与账本同目录）
    static func recordPath(roomKey: String) -> String {
        "h/\(roomKey)/info.json"
    }

    static func record(from house: House, username: String) -> CloudHouseRecord {
        CloudHouseRecord(
            roomKey: house.mediaRoomKey,
            roomNo: house.roomNo,
            tower: house.tower,
            landlord: house.landlord,
            layout: house.layout,
            price: house.price,
            password: house.password,
            remark: house.remark,
            status: house.statusRaw,
            updatedAt: house.lastUpdatedAt ?? house.updatedAt,
            updatedBy: CloudUser.signedUsername,   // v2.6：带设备标识（如 "涛(iPhone)"）
            mediaNames: house.mediaItems.map { $0.fileName },
            revision: nil
        )
    }

    /// 拉取云端账本（全量）：
    /// 1) 列 h/ 根下的房号目录（delimiter "/"，只收「h/<房号>/」形式，根下散文件如旧 _houses.json 忽略）；
    /// 2) 并发 GET 每套 info.json；
    /// 3) 某套无 info.json（404）→ 该套无记录，跳过；网络、HTTP 非 404、解析失败一律 throw。
    /// v1.42 语义：列表/读取失败必须报「同步失败」，绝不能被当成「云端没有房源」而误删本地。
    static func fetchAll(config: CosConfig) async throws -> [CloudHouseRecord] {
        // v2.62（B6）：目录列举统一走 listRoomKeys，明细拉取统一走 fetchRecords（并发 16 滑动窗口 + 只重试失败房号）
        let roomKeys = try await listRoomKeys(config: config)
        return try await fetchRecords(keys: roomKeys, config: config)
    }

    /// 拉取单套账本（404 → nil；网络/解析失败 throw）——详情页等只关心单套的场景，避免全量 list+GET
    static func fetchOne(roomKey: String, config: CosConfig) async throws -> CloudHouseRecord? {
        do {
            let data = try await CosUploader.fetchObjectData(path: recordPath(roomKey: roomKey), config: config)
            return try JSONDecoder().decode(CloudHouseRecord.self, from: data)
        } catch let e as CosObjectNotFoundError {
            return nil
        }
    }

    /// 上传单个房源（同房号覆盖写，只写这一套）
    static func uploadOne(house: House, username: String, config: CosConfig) async throws {
        try await upload(record: record(from: house, username: username), config: config)
    }

    /// 上传单条记录（覆盖写单套 info.json，不再读改写全量账本）
    static func upload(record: CloudHouseRecord, config: CosConfig) async throws {
        let data = try JSONEncoder().encode(record)
        try await CosUploader.upload(data: data, to: recordPath(roomKey: record.roomKey), contentType: "application/json", config: config)
    }

    /// v2.6 合并写（防"本地空名单覆盖云端媒体"bug）：
    /// 写前先读云端现有 info.json，把媒体名单合并为「云端 ∪ 本地 − 本次显式删除」，
    /// 字段级（租金/状态/备注等）以本地为准；revision 单调 +1。
    /// b118（P0③ CAS）：写前二次读取校验——读-写窗口内 revision 已变（另一设备刚写入）→ 抛冲突放弃写，
    /// 不再无条件覆盖他人数据；调用方捕获后提示用户刷新后重试。
    /// - removedMedia: 本次编辑显式删除的媒体文件名（来自编辑前快照）；新增房源传空集。
    /// - 返回: (mergedRecord, hadExisting: Bool)——hadExisting=YES 表示云端原本已有该房（调用方可记冲突日志）
    static func uploadGuarded(record: CloudHouseRecord, removedMedia: Set<String> = [], config: CosConfig) async throws -> (CloudHouseRecord, Bool) {
        // v2.39：写前探测绝不能用 try?——网络/权限失败会被当成「云端没有这条记录」，
        // 从而跳过媒体合并、把 revision 重置为 1 并覆盖他人数据。这里只把 404 视为「不存在」，
        // 其余失败一律上抛，由调用方转草稿或提示重试。
        let existing = try await fetchOne(roomKey: record.roomKey, config: config)
        var merged = record
        if let existing {
            let cloudSet = Set(existing.mediaNames)
            let localSet = Set(record.mediaNames)
            // 合并：云端和本地都保留，本次显式删除的排除
            merged.mediaNames = Array(cloudSet.union(localSet).subtracting(removedMedia))
            merged.revision = (existing.revision ?? 0) + 1
            // b118 CAS：写前再读一次云端，revision 已变化（他人刚写入）→ 放弃写、抛冲突
            // v2.39：二次读取失败（弱网）同样必须中止写入——校验不了就不许覆盖
            let fresh = try await fetchOne(roomKey: record.roomKey, config: config)
            if (fresh?.revision ?? 0) != (existing.revision ?? 0) {
                let byName: String = {
                    guard let name = fresh?.updatedBy, !name.isEmpty else { return "其他账号" }
                    return name
                }()
                throw CloudSyncConflict.recordChanged(roomKey: record.roomKey, by: byName)
            }
            // updatedAt 用本地（本地刚保存的最新），updatedBy 已在调用方填好
        } else {
            merged.revision = 1
        }
        try await upload(record: merged, config: config)
        // v2.39：本次自己写入的 revision 记为「本机已见」基线，供详情页/草稿冲突比对
        CloudRevisionStore.remember([merged.roomKey: merged.revision ?? 0])
        // v2.37（#34）：账本写成功后，总清单里这间房的摘要跟着更新（防抖合并，best-effort，不影响主流程）
        await CloudManifestUpdater.shared.scheduleUpsert(
            entry: CloudManifestEntry(record: merged), config: config)
        return (merged, existing != nil)
    }

    /// b118（1-711 死循环收敛）：列出「账本名单里有、但桶 h/<房号>/ 里不存在等价对象」的失效媒体名。
    /// 这类媒体下载永远失败（downloadHouseMedia 对桶中找不到的会跳过不硬下），本地永远缺，
    /// 每次同步都判「云端独有」→ 反复触发下载 → 无限循环（实测 1-711-mov-2b237b6b-1）。
    /// 同步对账收尾时调用，把这些失效引用从云端账本剔除写回，循环即终止。
    // 列桶失败（网络错误）必须抛错，由调用方跳过本次账本剔除；
    // 绝不能把失败吞成空数组——否则账本里的媒体会被误判「桶里不存在」而连锁剔除。
    static func missingLedgerMedia(roomKey: String, expectedNames: [String], config: CosConfig) async throws -> [String] {
        guard !expectedNames.isEmpty else { return [] }
        let objs = try await CosUploader.listObjects(prefix: "h/\(roomKey)/", config: config)
        // v2.37（#11）：用规范键（视频 mov/mp4 归一、图片保留后缀）判断桶里有没有等价对象
        var remoteKeys: Set<String> = []
        for obj in objs {
            let name = (obj.name as NSString).lastPathComponent
            let lower = name.lowercased()
            let isMedia = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif", ".mp4", ".mov"].contains { lower.hasSuffix($0) }
            guard isMedia else { continue }
            remoteKeys.insert(MediaNaming.canonicalKey(name))
        }
        var missing: [String] = []
        for expected in expectedNames {
            if !remoteKeys.contains(MediaNaming.canonicalKey(expected)) { missing.append(expected) }
        }
        return missing
    }

    /// 删除云端某房账本（info.json；整套目录删除由 deleteHouseRemoteFolder 一并处理媒体+账本）
    /// v2.36（#5）：不再用 try? 吞错——404（已删过）由 deleteRemoteObject 视为成功，
    /// 网络/权限等真实失败必须上抛，由调用方决定重试或提示，避免「本地删了、云端账本还在」。
    static func delete(roomKey: String, config: CosConfig) async throws {
        try await CloudBackupService.deleteRemoteObject(name: recordPath(roomKey: roomKey), config: config)
        // v2.37（#34）：账本删成功后，总清单里把这间房摘掉（防抖合并，best-effort）
        await CloudManifestUpdater.shared.scheduleRemove(roomKey: roomKey, config: config)
    }
}

// MARK: - v2.37 云端总清单（#15/#34：把约 128 次检测请求压成 1 次）

/// 总清单里每间房的摘要：只放检测需要的轻量字段（房号/座号/修改时间/修订号/媒体数），不含密码与媒体正文。
struct CloudManifestEntry: Codable, Identifiable {
    var id: String { roomKey }
    var roomKey: String
    var roomNo: String
    var tower: Int
    var updatedAt: Date
    var revision: Int64
    var mediaCount: Int
    /// v2.62：媒体名单指纹（归一化后排序再哈希）。用于识别「数量相同但换了文件」——
    /// 旧口径只比 mediaCount，删 6 个又新增 6 个时数量一致会静默漏检。
    /// 旧清单没有该字段 → 解码为 nil，调用方按「需拉明细」处理，保证不漏。
    var mediaHash: String?
    /// v2.62：字段指纹（房号/座号/房东/户型/租金/密码/备注/状态）。字段改动可直接在清单层发现，
    /// 不必为每套房拉 info.json；同样，nil 视作「需要明细」。
    var fieldsHash: String?

    init(roomKey: String, roomNo: String, tower: Int, updatedAt: Date, revision: Int64, mediaCount: Int,
         mediaHash: String? = nil, fieldsHash: String? = nil) {
        self.roomKey = roomKey
        self.roomNo = roomNo
        self.tower = tower
        self.updatedAt = updatedAt
        self.revision = revision
        self.mediaCount = mediaCount
        self.mediaHash = mediaHash
        self.fieldsHash = fieldsHash
    }

    /// 由单套账本记录抽成摘要
    init(record: CloudHouseRecord) {
        self.init(roomKey: record.roomKey, roomNo: record.roomNo, tower: record.tower,
                  updatedAt: record.updatedAt, revision: record.revision ?? 0,
                  mediaCount: record.mediaNames.count,
                  mediaHash: CloudManifestFingerprint.mediaHash(record.mediaNames),
                  fieldsHash: CloudManifestFingerprint.fieldsHash(record: record))
    }
}

/// v2.62：总清单指纹计算。与 CloudHouseSync.uploadGuarded 的合并语义配套：
/// 媒体按 `MediaNaming.canonicalKey` 归一（.mov/.mp4 视为同一视频），字段按 trim 后拼接。
enum CloudManifestFingerprint {
    static func mediaHash(_ names: [String]) -> String {
        let norm = Set(names.map { MediaNaming.canonicalKey($0) }).sorted()
        return digest(norm.joined(separator: "\n"))
    }

    static func fieldsHash(record: CloudHouseRecord) -> String {
        fieldsHash(roomNo: record.roomNo, tower: record.tower, landlord: record.landlord,
                   layout: record.layout, price: record.price, password: record.password,
                   remark: record.remark, status: record.status)
    }

    static func fieldsHash(roomNo: String, tower: Int, landlord: String, layout: String,
                           price: Int, password: String, remark: String, status: String) -> String {
        let parts = [roomNo, String(tower), landlord, layout, String(price), password, remark, status]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return digest(parts.joined(separator: "\u{1F}"))
    }

    private static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// 云端总清单对象（h/_manifest.json，下划线开头，被 fetchAll 与孤儿扫描天然跳过）
struct CloudManifest: Codable {
    var version: Int
    var revision: Int64
    var generatedAt: Date
    var rooms: [CloudManifestEntry]

    static func fresh() -> CloudManifest {
        CloudManifest(version: 1, revision: 0, generatedAt: Date(), rooms: [])
    }
}

extension CloudHouseSync {
    static func manifestPath() -> String { "h/_manifest.json" }

    /// 拉总清单（404 → nil；网络/解析失败 throw）
    /// v2.65：带 ETag 缓存——清单没变时服务端回 304，直接复用本地副本，省掉每次 37KB 的重复传输。
    static func fetchManifest(config: CosConfig) async throws -> CloudManifest? {
        do {
            let data = try await CosUploader.fetchObjectDataCached(
                path: manifestPath(), cacheKey: "manifest", config: config)
            return try JSONDecoder().decode(CloudManifest.self, from: data)
        } catch let e as CosObjectNotFoundError {
            return nil
        }
    }

    static func writeManifest(_ manifest: CloudManifest, config: CosConfig) async throws {
        let data = try JSONEncoder().encode(manifest)
        try await CosUploader.upload(data: data, to: manifestPath(), contentType: "application/json", config: config)
    }

    /// 用全量账本重建总清单（首次没有清单 / 清单缺失时用）
    @discardableResult
    static func rebuildManifest(config: CosConfig) async throws -> CloudManifest {
        let records = try await fetchAll(config: config)
        let entries = records.map { CloudManifestEntry(record: $0) }.sorted(by: Self.manifestEntryOrdered)
        let manifest = CloudManifest(version: 1, revision: 1, generatedAt: Date(), rooms: entries)
        try await writeManifest(manifest, config: config)
        return manifest
    }

    /// 读-改-写：把待更新/待删除合并进当前清单后整体写回。
    /// 调用方（CloudManifestUpdater actor）已在本设备串行化；跨设备冲突靠「失败后重新读再合并写一次」收敛。
    static func applyManifestChanges(upserts: [String: CloudManifestEntry], removes: Set<String>, config: CosConfig) async throws {
        var manifest = (try await fetchManifest(config: config)) ?? CloudManifest.fresh()
        var entries = Dictionary(manifest.rooms.map { ($0.roomKey, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, entry) in upserts { entries[key] = entry }
        for key in removes { entries[key] = nil }
        manifest.rooms = entries.values.sorted(by: Self.manifestEntryOrdered)
        manifest.revision += 1
        manifest.generatedAt = Date()
        try await writeManifest(manifest, config: config)
    }

    private static func manifestEntryOrdered(_ a: CloudManifestEntry, _ b: CloudManifestEntry) -> Bool {
        if a.tower != b.tower { return a.tower < b.tower }
        return a.roomKey < b.roomKey
    }
}

/// 总清单更新器（actor）：把短时间内多间房的清单改动合并成一次读-改-写（防抖），
/// 批量导入末尾可调用 flush() 强制一次性落盘。全程 best-effort：失败只记日志，不影响房源/账本主流程。
actor CloudManifestUpdater {
    static let shared = CloudManifestUpdater()

    private var pendingUpserts: [String: CloudManifestEntry] = [:]
    private var pendingRemoves: Set<String> = []
    private var config: CosConfig?
    private var scheduled: Task<Void, Never>?

    func scheduleUpsert(entry: CloudManifestEntry, config: CosConfig) {
        self.config = config
        pendingRemoves.remove(entry.roomKey)
        pendingUpserts[entry.roomKey] = entry
        arm()
    }

    func scheduleRemove(roomKey: String, config: CosConfig) {
        self.config = config
        pendingUpserts[roomKey] = nil
        pendingRemoves.insert(roomKey)
        arm()
    }

    /// 批量导入等场景结束后调用：取消防抖、立刻把积压改动一次性写盘
    func flush() async {
        scheduled?.cancel()
        scheduled = nil
        await performFlush()
    }

    private func arm() {
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await self.performFlush()
        }
    }

    private func performFlush() async {
        guard let config = config else { return }
        guard !pendingUpserts.isEmpty || !pendingRemoves.isEmpty else { return }
        let upserts = pendingUpserts
        let removes = pendingRemoves
        pendingUpserts = [:]
        pendingRemoves = []
        do {
            try await CloudHouseSync.applyManifestChanges(upserts: upserts, removes: removes, config: config)
        } catch {
            // 失败重试一次：重新读最新清单再合并（兼顾期间别的设备的写入）
            do {
                try await CloudHouseSync.applyManifestChanges(upserts: upserts, removes: removes, config: config)
            } catch {
                // v2.57（P2-12）：重试仍失败 → 改动塞回队列（不再只留日志把改动丢掉），
                // 下次任何房源操作触发 arm() 时自动随下次写入一并补上；
                // 每次写入前 applyManifestChanges 都会先拉最新清单再合并（读-改-写），不会覆盖他端写入。
                for (key, entry) in upserts { pendingUpserts[key] = entry }
                for key in removes { pendingRemoves.insert(key) }
                BackupLogStore.log(category: "同步", action: "更新总清单", result: "失败",
                                  detail: "总清单本次没写上（\(String(describing: error))），改动已记住，下次操作时自动补写", cloud: true)
            }
        }
    }
}

/// 本地记录「上次看到的云端每间房修订号」（存 UserDefaults），配合总清单做增量检测：
/// 清单里某间房 revision 跟这里记的不一样，就说明云端那间有变化，无需逐间拉详情。
enum CloudRevisionStore {
    private static let storageKey = "cloud_manifest_seen_revisions"

    static func all() -> [String: Int64] {
        let raw = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
        return raw.mapValues { Int64($0) }
    }

    static func seen(_ roomKey: String) -> Int64? { all()[roomKey] }

    static func remember(_ revisions: [String: Int64]) {
        var cur = all()
        for (key, value) in revisions where !key.isEmpty { cur[key] = value }
        UserDefaults.standard.set(cur.mapValues { Int($0) }, forKey: storageKey)
    }

    static func remove(_ roomKey: String) {
        var cur = all()
        guard cur[roomKey] != nil else { return }
        cur[roomKey] = nil
        UserDefaults.standard.set(cur.mapValues { Int($0) }, forKey: storageKey)
    }
}

/// v2.62：本地房源摘要（值类型）。后台增量比对只看它，不碰 SwiftData 模型对象。
/// mediaKeys 已按 `MediaNaming.canonicalKey` 归一（.mov/.mp4 视为同一视频）。
struct LocalHouseSummary {
    var roomKey: String
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var statusRaw: String
    var mediaKeys: Set<String>
}

extension CloudHouseSync {
    /// v2.62：增量拉取结果
    struct IncrementalResult {
        /// 需要明细的房（清单判 suspect + 本地没有的房）；未变化的房不在其中
        var records: [CloudHouseRecord]
        /// 云端权威房号集合（来自目录列举，不是清单）
        var cloudKeys: Set<String>
        /// 被判为「无需拉明细」的房数量（验收用）
        var unchangedCount: Int
        /// 本次是否走了全量（首次 / 24h 到期 / 深度刷新）
        var usedFullScan: Bool
        /// 云端每套房的 revision（供调用方回写检测基线，避免再拉一次清单）
        var revisions: [String: Int64]
    }

    /// 列出云端 h/ 下的房号目录（1 次请求，权威集合；系统保留目录跳过）
    static func listRoomKeys(config: CosConfig) async throws -> [String] {
        let prefix = "h/"
        let objects = try await CosUploader.listObjects(prefix: prefix, delimiter: "/", config: config)
        var roomKeys: [String] = []
        for obj in objects {
            var name = obj.name
            guard name.hasPrefix(prefix) else { continue }
            name.removeFirst(prefix.count)
            guard name.hasSuffix("/") else { continue }
            name.removeLast()
            guard !name.isEmpty, !name.hasPrefix("_") else { continue }
            roomKeys.append(name)
        }
        return roomKeys
    }

    /// v2.62（B1/B4/B5）：增量拉取。
    /// - 权威房号集合来自 `listRoomKeys`（不是清单），避免清单缺失导致「云端已删」误判；
    /// - 清单摘要/指纹一致且 revision 未变的房直接跳过 `info.json`；
    /// - 清单缺失、条目缺指纹、本地没有的房一律拉明细（准确性优先）；
    /// - 每次随机抽 3 套核对清单（防清单本身写错）；
    /// - 首次 / 24h 到期 / `deep` 走全量，并用这批数据重建清单（顺带补齐新指纹）。
    static func fetchIncremental(config: CosConfig,
                                 locals: [String: LocalHouseSummary],
                                 seen: [String: Int64],
                                 deep: Bool) async throws -> IncrementalResult {
        let roomKeys = try await listRoomKeys(config: config)
        let cloudKeys = Set(roomKeys)
        let now = Date().timeIntervalSince1970
        let lastFull = UserDefaults.standard.double(forKey: "cloudFullCheckLastAt")
        let fullDue = deep || lastFull <= 0 || now - lastFull >= 24 * 3600

        if fullDue {
            let records = try await fetchRecords(keys: roomKeys, config: config)
            let currentRevision = (try? await fetchManifest(config: config))?.revision ?? 0
            let manifest = CloudManifest(version: 1, revision: currentRevision + 1,
                                         generatedAt: Date(),
                                         rooms: records.map { CloudManifestEntry(record: $0) })
            // 重建失败不影响本次同步（下次到期会再修）
            try? await writeManifest(manifest, config: config)
            UserDefaults.standard.set(now, forKey: "cloudFullCheckLastAt")
            return IncrementalResult(records: records, cloudKeys: cloudKeys,
                                     unchangedCount: 0, usedFullScan: true,
                                     revisions: Dictionary(uniqueKeysWithValues: records.map { ($0.roomKey, $0.revision ?? 0) }))
        }

        let manifest = try? await fetchManifest(config: config)
        var entryByKey: [String: CloudManifestEntry] = [:]
        for e in (manifest?.rooms ?? []) { entryByKey[e.roomKey] = e }

        var suspect: [String] = []
        var suspectSet: Set<String> = []
        for key in roomKeys {
            guard let local = locals[key] else {
                suspect.append(key); suspectSet.insert(key); continue   // 本地没有 → 必须拉明细
            }
            guard let entry = entryByKey[key] else {
                suspect.append(key); suspectSet.insert(key); continue   // 清单没这条 → 必须拉明细
            }
            if manifestEntryIsSuspect(entry, local: local, seenRevision: seen[key]) {
                suspect.append(key); suspectSet.insert(key)
            }
        }

        // v2.62（B4）：抽样 3 套核对清单，发现「清单与明细不一致」就把该房升级为 suspect，
        // 清单从此会在下次成功写入时被修正。抽样只覆盖被判「无变化」的房；3 个并发，避免串行拖慢刷新。
        let unchangedPool = roomKeys.filter { !suspectSet.contains($0) && locals[$0] != nil }
        let sampleKeys = Array(unchangedPool.shuffled().prefix(3))
        let sampleRecords: [CloudHouseRecord] = await withTaskGroup(of: CloudHouseRecord?.self) { group in
            for key in sampleKeys {
                group.addTask { (try? await fetchOne(roomKey: key, config: config)) ?? nil }
            }
            var out: [CloudHouseRecord] = []
            for await rec in group { if let rec { out.append(rec) } }
            return out
        }
        for rec in sampleRecords {
            guard let entry = entryByKey[rec.roomKey] else { continue }
            if !manifestEntryMatchesRecord(entry, record: rec) {
                suspect.append(rec.roomKey); suspectSet.insert(rec.roomKey)
            }
        }

        let records = suspect.isEmpty ? [] : try await fetchRecords(keys: suspect, config: config)
        // 清单有条目但 info.json 已 404（目录还在、账本已删）→ 从清单摘除，避免这套房每次刷新都被判 suspect。
        // 注意：解析失败会在 fetchRecords 里重试后 throw，走不到这里，所以缺失的只可能是 404。
        let missingKeys = suspectSet.subtracting(Set(records.map { $0.roomKey }))
        // v2.64：顺手回填缺指纹的清单条目。旧清单（v2.62 之前写入）mediaHash / fieldsHash 全是 nil，
        // manifestEntryIsSuspect 会把每条都判成「要拉明细」，于是每次刷新都全量拉一遍（218 套 ≈ 15 秒）；
        // 而这里原来只在 24h 全量分支重建清单，指纹机制长期不生效。本次已拉到明细，直接回填（一次读写）。
        let needsFingerprintBackfill = (manifest?.rooms ?? []).contains { $0.mediaHash == nil || $0.fieldsHash == nil }
        if !missingKeys.isEmpty || needsFingerprintBackfill {
            var upserts: [String: CloudManifestEntry] = [:]
            if needsFingerprintBackfill {
                for rec in records { upserts[rec.roomKey] = CloudManifestEntry(record: rec) }
            }
            try? await applyManifestChanges(upserts: upserts, removes: missingKeys, config: config)
        }
        return IncrementalResult(records: records, cloudKeys: cloudKeys,
                                 unchangedCount: roomKeys.count - suspectSet.count, usedFullScan: false,
                                 revisions: entryByKey.mapValues { $0.revision })
    }

    /// 清单条目是否「需要拉明细」。缺指纹的旧条目一律视为需要，绝不凭数量判同。
    static func manifestEntryIsSuspect(_ entry: CloudManifestEntry, local: LocalHouseSummary, seenRevision: Int64?) -> Bool {
        if entry.tower != local.tower || entry.roomNo != local.roomNo { return true }
        if entry.mediaCount != local.mediaKeys.count { return true }
        guard let mediaHash = entry.mediaHash, let fieldsHash = entry.fieldsHash else { return true }
        if mediaHash != CloudManifestFingerprint.mediaHash(Array(local.mediaKeys)) { return true }
        if fieldsHash != CloudManifestFingerprint.fieldsHash(
            roomNo: local.roomNo, tower: local.tower, landlord: local.landlord,
            layout: local.layout, price: local.price, password: local.password,
            remark: local.remark, status: local.statusRaw) { return true }
        if let seenRevision, seenRevision != entry.revision { return true }
        return false
    }

    /// 抽样核对：清单条目与刚拉到的明细是否一致
    static func manifestEntryMatchesRecord(_ entry: CloudManifestEntry, record: CloudHouseRecord) -> Bool {
        guard let mediaHash = entry.mediaHash, let fieldsHash = entry.fieldsHash else { return false }
        guard entry.mediaCount == record.mediaNames.count else { return false }
        guard mediaHash == CloudManifestFingerprint.mediaHash(record.mediaNames) else { return false }
        return fieldsHash == CloudManifestFingerprint.fieldsHash(record: record)
    }

    /// v2.62（B6/B7）：并发拉明细。并发窗口 16，谁先回来立刻补位；
    /// 单套失败只记录该房号，最后只重试失败的房号（最多 2 次），不整轮重跑。
    static func fetchRecords(keys: [String], config: CosConfig, limit: Int = 16) async throws -> [CloudHouseRecord] {
        guard !keys.isEmpty else { return [] }
        var records: [CloudHouseRecord] = []
        var failures: [String] = []
        var pending = keys
        for attempt in 0...2 {
            let (done, failed) = try await fetchRecordsOnce(keys: pending, config: config, limit: limit)
            records.append(contentsOf: done)
            failures = failed
            if failures.isEmpty { return records }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 400_000_000 * UInt64(attempt + 1))   // 0.4s / 0.8s
                pending = failures
            }
        }
        let sample = failures.prefix(3).joined(separator: "、")
        throw NSError(domain: "CloudHouseSync", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "读取云端账本失败：\(failures.count) 套（\(sample)）"
        ])
    }

    /// 单套拉取结果（用具体类型而不是 Result<_, Error>，避免并发组里的错误类型跨线程传递问题）
    private struct FetchOutcome: @unchecked Sendable {
        var key: String
        var record: CloudHouseRecord?
        var failed: Bool
    }

    private static func fetchRecordsOnce(keys: [String], config: CosConfig, limit: Int) async throws -> ([CloudHouseRecord], [String]) {
        guard !keys.isEmpty else { return ([], []) }
        var records: [CloudHouseRecord] = []
        var failed: [String] = []
        var iterator = keys.makeIterator()
        try await withThrowingTaskGroup(of: FetchOutcome.self) { group in
            var inflight = 0
            for _ in 0..<min(limit, keys.count) {
                guard let key = iterator.next() else { break }
                group.addTask { await fetchOneOutcome(key: key, config: config) }
                inflight += 1
            }
            while inflight > 0 {
                guard let outcome = try await group.next() else { break }
                inflight -= 1
                if outcome.failed {
                    failed.append(outcome.key)
                } else if let rec = outcome.record {
                    records.append(rec)
                }
                if let nextKey = iterator.next() {
                    group.addTask { await fetchOneOutcome(key: nextKey, config: config) }
                    inflight += 1
                }
            }
        }
        return (records, failed)
    }

    private static func fetchOneOutcome(key: String, config: CosConfig) async -> FetchOutcome {
        do {
            // v2.62（B8）：带 ETag 缓存；304 时用本地副本，没变就不重复传数据
            let data = try await CosUploader.fetchObjectDataCached(
                path: recordPath(roomKey: key), cacheKey: key, config: config)
            let rec = try JSONDecoder().decode(CloudHouseRecord.self, from: data)
            return FetchOutcome(key: key, record: rec, failed: false)
        } catch is CosObjectNotFoundError {
            return FetchOutcome(key: key, record: nil, failed: false)   // 该套无账本记录 → 跳过
        } catch {
            return FetchOutcome(key: key, record: nil, failed: true)
        }
    }
}

// MARK: - v1.19 纯云端房源下载到本地

extension CosUploader {
    /// 把云端 h/<roomKey>/ 的媒体下载到本地 MediaStore 目录，返回 (本地文件名, kind)。
    /// v1.37：改为幂等回补——本地已存在同名文件直接跳过，缺失的用云端原名写回（不产生重复文件）。
    /// v1.41：视频名归一化——云端视频统一 .mp4，本地写回 .mov（与账本 mediaNames 的本地原始名一致），
    ///        彻底消除「账本 .mov ↔ 本地磁盘 .mp4」的同步误判（此前每次同步都误报媒体缺失）。
    /// v1.43 重写（修复「每次同步都下载N删N」循环与「本地删文件后刷不回」）：
    ///   - **只下载 expectedNames（云端账本名单）里的文件**——桶目录里多出来的
    ///     非账本对象（视频首帧图 .vthumb.jpg、旧分享页 .html、cover 等）一律不下载、不进记录，
    ///     从源头消除「下载↔删除互抵」的死循环；
    ///   - **落盘名与账本名单完全一致**（视频桶对象 .mp4 ↔ 账本名 .mov/.mp4 按账本名写回），
    ///     同步完成后本地记录 = 账本名单，下次同步零差异；
    ///   - 本地磁盘已有账本名（或桶同名对象）→ 跳过（幂等，不重复下载）。
    static func downloadHouseMedia(roomKey: String, expectedNames: [String], config: CosConfig, progress: ((Double) -> Void)? = nil) async throws -> [(fileName: String, kind: String)] {
        var objs = try await listObjects(prefix: "h/\(roomKey)/", config: config)
        // v2.37（#11）：桶对象按「规范键」MediaNaming.canonicalKey 建索引——视频 .mov/.mp4 归一到 .mp4，
        // 图片保留完整后缀；只收媒体对象（图片/视频），跳过首帧图/分享页/cover。
        var remotePathByKey: [String: String] = [:]
        for obj in objs {
            let name = (obj.name as NSString).lastPathComponent
            let lower = name.lowercased()
            let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
            let isImage = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"].contains { lower.hasSuffix($0) }
            guard isVideo || isImage else { continue }
            let key = MediaNaming.canonicalKey(name)
            if remotePathByKey[key] == nil {
                remotePathByKey[key] = obj.name
            }
        }
        let existingKeys = Set(MediaStore.existingFileNames(roomKey: roomKey).map { MediaNaming.canonicalKey($0) })
        // 待下载目标：账本名单里、桶里有等价对象、本地磁盘还没有的（幂等：已存在跳过，天然支持断点重跑）
        struct Target { let expected: String; let remotePath: String; let kind: String }
        var targets: [Target] = []
        for expected in expectedNames {
            let lower = expected.lowercased()
            let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
            let isImage = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"].contains { lower.hasSuffix($0) }
            guard isVideo || isImage else { continue }
            // 按规范键找等价对象（视频 .mp4 ↔ .mov 等价；图片同名同后缀）——找不到说明账本与桶不一致，跳过不硬下
            guard let remotePath = remotePathByKey[MediaNaming.canonicalKey(expected)] else { continue }
            // 磁盘已有等价文件（mov/mp4 任一）→ 跳过（幂等回补）
            if existingKeys.contains(MediaNaming.canonicalKey(expected)) { continue }
            targets.append(Target(expected: expected, remotePath: remotePath, kind: isVideo ? "video" : "image"))
        }
        guard !targets.isEmpty else { progress?(1.0); return [] }

        // v2.36（#38）：并发 3 下载 + 字节进度。先并发 HEAD 拿每个对象大小，总字节用于按真实体积推进进度条
        // （大视频比小图片占比大，不再按「文件个数」平均）。HEAD 失败则回退按文件个数计进度。
        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64).self) { group in
            for t in targets {
                group.addTask { (t.expected, await Self.fetchObjectSize(path: t.remotePath, config: config)) }
            }
            for await (name, size) in group { sizes[name] = size }
        }
        let totalBytes = sizes.values.reduce(0, +)
        let useByteProgress = totalBytes > 0
        let byteCounter = DownloadByteCounter()
        let limiter = DownloadConcurrencyLimiter(limit: 3)
        progress?(0)

        let downloaded: [(fileName: String, kind: String)] = try await withThrowingTaskGroup(of: (String, String)?.self) { group in
            for t in targets {
                group.addTask {
                    await limiter.acquire()
                    do {
                        let expectedSize = sizes[t.expected] ?? 0
                        // v2.38（#38）真正断点续传：若上次中断留下 .part，从已写字节发 Range 续传；
                        // .part 异常（≥对象大小）则丢弃重来。
                        var startByte = MediaStore.partialSize(for: t.expected, roomKey: roomKey)
                        if expectedSize > 0 && startByte >= expectedSize {
                            MediaStore.removePartial(for: t.expected, roomKey: roomKey)
                            startByte = 0
                        }
                        let partURL = MediaStore.partialURL(for: t.expected, roomKey: roomKey)
                        let presigned = try presignedGetURL(for: t.remotePath, expires: 300, config: config)
                        let finalBytes = try await ResumableMediaDownloader.download(
                            url: presigned, to: partURL, startByte: startByte, onBytes: { _ in }
                        )
                        // 大小校验：HEAD 拿到大小就必须一致，对不上说明文件不完整——保留 .part 报错，不产出半成品
                        if expectedSize > 0 && finalBytes != expectedSize {
                            throw NSError(domain: "CosUploader", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "媒体下载不完整：\(t.expected)（\(finalBytes)/\(expectedSize) 字节），可重试续传"])
                        }
                        // v2.37（#9）：先看真实格式再命名（从已落盘 .part 读文件头识别真实容器）
                        let saveName: String
                        if t.kind == "video" {
                            let realExt = MediaNaming.videoExtension(forFile: partURL)
                            saveName = ((t.expected as NSString).deletingPathExtension) + "." + realExt
                        } else {
                            saveName = t.expected
                        }
                        guard MediaStore.finalizePartial(partName: t.expected, to: saveName, roomKey: roomKey) else {
                            throw NSError(domain: "CosUploader", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "媒体落盘失败：\(saveName)"])
                        }
                        await limiter.release()
                        if useByteProgress {
                            await byteCounter.add(max(finalBytes, expectedSize))
                            let done = await byteCounter.value
                            progress?(min(0.99, Double(done) / Double(totalBytes)))
                        } else {
                            await byteCounter.bump()
                            let done = await byteCounter.count
                            progress?(min(0.99, Double(done) / Double(targets.count)))
                        }
                        return (saveName, t.kind)
                    } catch {
                        await limiter.release()
                        throw error
                    }
                }
            }
            var out: [(fileName: String, kind: String)] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
        progress?(1.0)
        return downloaded
    }

    /// v2.36（#38）：HEAD 请求读取对象字节大小（用于字节进度）；失败返回 0，调用方回退按个数计。
    private static func fetchObjectSize(path: String, config: CosConfig) async -> Int64 {
        guard let url = try? presignedGetURL(for: path, expires: 300, config: config) else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return http.expectedContentLength > 0 ? http.expectedContentLength : 0
            }
        } catch {}
        return 0
    }

    /// v1.54：自动生成/更新某房源的脱敏版 H5（新增/编辑保存后自动调用；设置页「刷新分享缓存」全量重建也用它）
    /// v2.36（#39）：改为「先建后删」蓝绿切换——
    /// 1) 清本地缓存 → 强制生成新链接（不命中缓存复用）
    /// 2) 先记住云端旧脱敏版 H5（不立即删），有媒体则先调 shareCard 把新页建好
    /// 3) 新页建成功后再删旧页，旧链接才失效；若新页生成中途失败，旧页仍可打开，不会出现「分享页 404 空窗」
    /// 无媒体只删旧页不生成（选房页点击该房时放大图）
    static func autoRegenerateMaskedShare(mediaFiles: [ShareMediaFile], roomKey: String, info: ShareHouseInfo, config: CosConfig) async throws -> URL? {
        // v2.57（P2-11）：不再先删本地缓存——旧逻辑每次“重新生成脱敏页”都先 ShareCacheStore.remove，
        // 缓存必然不命中，媒体与信息明明没变也走全量：逐个 HEAD、重复生成缩略图与页面，是假增量。
        // 现在先按统一命中判断（渲染参数+媒体清单+房源信息）短路：命中直接复用上次链接，
        // 零上传、零页面生成，也不做任何删除（返回的正是正在用的那页）。
        if let cachedURL = await shareCacheHitURL(mediaFiles: mediaFiles, roomKey: roomKey, mode: .masked, info: info, config: config) {
            return cachedURL
        }
        let prefix = "\(CloudUser.sharePagePrefix)\(roomKey)/"
        // 先收集旧脱敏页对象，暂不删除
        var oldMaskedKeys: [String] = []
        if let objs = try? await listObjects(prefix: prefix, config: config) {
            for obj in objs {
                let name = (obj.name as NSString).lastPathComponent
                if name.contains("_脱敏版_") && name.hasSuffix(".html") {
                    oldMaskedKeys.append(obj.name)
                }
            }
        }
        // 无媒体：没有新页要建，直接清旧页
        guard !mediaFiles.isEmpty else {
            for key in oldMaskedKeys {
                try? await CloudBackupService.deleteRemoteObject(name: key, config: config)
            }
            return nil
        }
        // 蓝绿：先把新页建好（失败则旧页保留，直接抛错，不做删除）
        let newURL = try await shareCard(mediaFiles: mediaFiles, roomKey: roomKey, info: info, mode: .masked, config: config)
        // 新页已就绪，再删除旧页
        for key in oldMaskedKeys {
            try? await CloudBackupService.deleteRemoteObject(name: key, config: config)
        }
        return newURL
    }

    /// v1.41：删除单条媒体的云端对象——图片删 h/<房号>/<原名>；视频删 h/<房号>/<同名>.mp4，
    /// 并顺带清用户私有区的视频首帧缩略图。编辑保存删除媒体时调用，保证「删了别人也看不到」。
    /// 无云端配置或对象不存在时静默跳过（不打断本地删除）。
    static func deleteRemoteMedia(fileName: String, kind: String, roomKey: String, config: CosConfig?) async throws {
        guard let config = config ?? CosConfig.load(), config.isValid, !fileName.isEmpty else { return }
        let remoteName = kind == "video" ? ((fileName as NSString).deletingPathExtension) + ".mp4" : fileName
        // v2.36（#5）：主媒体对象删除失败必须上抛，不能静默吞掉，否则别人还能看到已删的图/视频
        try await CloudBackupService.deleteRemoteObject(name: "h/\(roomKey)/\(remoteName)", config: config)
        if kind == "video" {
            // 首帧缩略图是派生文件，删除失败不影响主流程，保留 best-effort
            try? await CloudBackupService.deleteRemoteObject(name: "\(CloudUser.sharePagePrefix)\(roomKey)/\(fileName).vthumb.jpg", config: config)
        }
    }
}

/// v2.36（#38）：下载并发限流器——同一时刻最多 limit 个任务在跑网络请求
private actor DownloadConcurrencyLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    func release() {
        running -= 1
        if !waiters.isEmpty && running < limit {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}

/// v2.36（#38）：线程安全的下载字节/文件计数，供任务组内并发任务共同累加
private actor DownloadByteCounter {
    private(set) var value: Int64 = 0
    private(set) var count: Int = 0
    func add(_ bytes: Int64) { value += bytes }
    func bump() { count += 1 }
}

/// v2.38（#38）：真正的 Range 断点续传下载器。
/// 边收字节边追加写入 .part：中途网络失败/被杀后，.part 已保留已收字节；
/// 下次用「Range: bytes=<已收>-」只下剩余部分。服务端若忽略 Range 回 200，则截断从头重写，保证文件不损坏。
/// 所有状态只在 URLSession 的串行代理队列上改动（@unchecked Sendable）。
private final class ResumableMediaDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let fileURL: URL
    private let startByte: Int64
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var continuation: CheckedContinuation<Int64, Error>?
    private var session: URLSession?
    private var finished = false
    private let onBytes: @Sendable (Int64) -> Void

    init(fileURL: URL, startByte: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.fileURL = fileURL
        self.startByte = startByte
        self.onBytes = onBytes
        super.init()
    }

    /// 下载到 fileURL，返回最终落盘字节数。
    static func download(url: URL, to fileURL: URL, startByte: Int64,
                        onBytes: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let loader = ResumableMediaDownloader(fileURL: fileURL, startByte: startByte, onBytes: onBytes)
        return try await loader.run(url: url)
    }

    private func run(url: URL) async throws -> Int64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
            self.continuation = cont
            let fm = FileManager.default
            do {
                if startByte > 0 && fm.fileExists(atPath: fileURL.path) {
                    // 续传：打开已有 .part 追加
                    let h = try FileHandle(forWritingTo: fileURL)
                    try h.seekToEnd()
                    self.handle = h
                    self.received = startByte
                } else {
                    // 全新：建空文件
                    fm.createFile(atPath: fileURL.path, contents: nil)
                    let h = try FileHandle(forWritingTo: fileURL)
                    self.handle = h
                    self.received = 0
                }
            } catch {
                cont.resume(throwing: NSError(domain: "CosUploader", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "断点文件打开失败：\(fileURL.lastPathComponent)"]))
                return
            }
            var request = URLRequest(url: url)
            if startByte > 0 {
                request.setValue("bytes=\(startByte)-", forHTTPHeaderField: "Range")
            }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    // MARK: URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(NSError(domain: "CosUploader", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败"]), completion: completionHandler)
            return
        }
        if http.statusCode == 404 {
            fail(CosObjectNotFoundError(path: fileURL.lastPathComponent), completion: completionHandler)
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            fail(NSError(domain: "CosUploader", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "读取云端对象失败（HTTP \(http.statusCode)）"]), completion: completionHandler)
            return
        }
        // 续传请求却收到 200（服务端/网关忽略 Range 回整包）→ 截断从头写，避免把整包拼到旧字节后
        if http.statusCode == 200, startByte > 0 {
            do {
                try handle?.truncate(atOffset: 0)
                try handle?.seek(toOffset: 0)
                received = 0
            } catch {
                fail(NSError(domain: "CosUploader", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "断点文件重置失败"]), completion: completionHandler)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            finish(with: NSError(domain: "CosUploader", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "断点文件写入失败"]))
            return
        }
        received += Int64(data.count)
        onBytes(received)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(with: error)
    }

    private func fail(_ error: Error, completion: @escaping (URLSession.ResponseDisposition) -> Void) {
        completion(.cancel)
        finish(with: error)
    }

    private func finish(with error: Error?) {
        guard !finished else { return }
        finished = true
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session?.invalidateAndCancel()
        session = nil
        if let error = error {
            continuation?.resume(throwing: error)   // 保留 .part，下次续传
        } else {
            continuation?.resume(returning: received)
        }
        continuation = nil
    }
}

/// v1.72（#6）：本地房源账本镜像——与云端方案 A 同构：每套房在 media/<房号>/info.json 存一份
/// 与云端同构的 CloudHouseRecord JSON（保存/导入/同步/删除联动）。
/// 效果：本地「一房一账本」，删除整套 = 删 media/<房号>/ 文件夹（媒体 + 账本）一步到位；
/// 备份/恢复/对账时本地账本与云端结构完全一致。
enum LocalHouseLedger {
    /// 写本套账本（幂等覆盖）
    static func save(_ house: House) {
        let record = CloudHouseSync.record(from: house, username: CloudUser.username)
        let dir = MediaStore.houseDirectory(roomKey: house.mediaRoomKey)
        let url = dir.appendingPathComponent("info.json")
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// v1.75：离线一键重建——扫描本地 media/<房号>/info.json，按账本「刷新+补齐」本地房源。
    /// 幂等合并：已有房源按账本覆盖字段与媒体清单，缺失房源新建；不删除任何现有数据。
    /// 无需联网（本地账本 + 本地媒体文件即为恢复源）。返回处理房源套数。
    static func restoreAll(houseContext: ModelContext) -> Int {
        let dir = MediaStore.mediaDirectory()
        guard let roomDirs = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var localByKey: [String: House] = [:]
        if let all = try? houseContext.fetch(FetchDescriptor<House>()) {
            for h in all where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
        }
        var restored = 0
        for roomDirName in roomDirs {
            let ledgerURL = dir.appendingPathComponent(roomDirName).appendingPathComponent("info.json")
            guard let data = try? Data(contentsOf: ledgerURL),
                  let rec = try? JSONDecoder().decode(CloudHouseRecord.self, from: data) else { continue }
            let house: House
            if let h = localByKey[rec.roomKey] {
                h.roomNo = rec.roomNo; h.tower = rec.tower; h.landlord = rec.landlord
                h.layout = rec.layout; h.price = rec.price; h.password = rec.password
                h.remark = rec.remark; h.statusRaw = rec.status
                h.lastUpdatedAt = rec.updatedAt
                house = h
            } else {
                let h = House(roomNo: rec.roomNo, tower: rec.tower, landlord: rec.landlord,
                              layout: rec.layout, price: rec.price, password: rec.password,
                              remark: rec.remark, status: HouseStatus(rawValue: rec.status) ?? .available)
                h.lastUpdatedAt = rec.updatedAt
                h.cloudStatus = .local
                houseContext.insert(h)
                house = h
            }
            // 媒体清单以账本为准：缺的补建记录、账本没有的移除记录（磁盘媒体文件不动）
            let cloudNames = Set(rec.mediaNames)
            let existing = Set(house.mediaItems.map { $0.fileName })
            for name in rec.mediaNames where !existing.contains(name) {
                let lower = name.lowercased()
                let kind = (lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? "video" : "image"
                let item = MediaItem(fileName: name, kind: kind)
                item.house = house
                houseContext.insert(item)
            }
            for item in Array(house.mediaItems) where !cloudNames.contains(item.fileName) {
                houseContext.delete(item)
            }
            restored += 1
        }
        try? houseContext.save()
        return restored
    }
}
