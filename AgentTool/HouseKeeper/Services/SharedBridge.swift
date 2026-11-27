import Foundation

/// 分享扩展 ↔ 主 App 共享桥（App Group：group.com.gj.tg2.shared，与 Widget 同组）。
/// 口径：
/// - 敏感密钥（COS sid/skey、后台口令明文）绝不进共享区——扩展经云函数 cosCfg 取 COS 配置，仅内存持有；
/// - 共享区只放非敏感配置镜像（用户名/云函数地址/口令哈希/压缩开关/自定义域名）与两进程共用的队列；
/// - 口令哈希本就随每个云函数请求 URL 传输（k= 参数），镜像不扩大暴露面；
/// - suite 不可用时回退 standard，主 App 存量行为不变。
enum SharedBridge {
    static let groupID = "group.com.gj.tg2.shared"

    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// 扩展进程标记：扩展入口置 true；主 App 恒 false。
    /// 决定 CosConfig.load / CloudConfig.passwordHash / BackupLogStore 的进程分支。
    static var isExtension = false

    // MARK: 镜像键（主 App 写、扩展读）

    static let kPasswordHash = "share.mirror.passwordHash"
    static let kCompress = "share.mirror.compressOnShare"
    static let kCustomDomain = "share.mirror.customDomain"
    static let kEndpoint = "share.mirror.endpoint"
    static let kToken = "share.mirror.houseToken"

    /// 主 App 调用：把非敏感配置镜像进共享区（启动 / 回前台 / 退后台 / 设置变更时）。
    /// 用户名与云函数地址的 setter 已直写共享区，这里兜底覆盖钥匙串旧值等边角。
    /// 标注 MainActor：需访问 NotifyHub/MeterCloudSync/MeterStore 等 @MainActor 单例的隔离属性。
    @MainActor
    static func writeMirrors() {
        guard !isExtension else { return }
        let d = defaults
        d.set(CloudUser.username, forKey: "cloud.username")
        d.set(CloudConfig.functionURL, forKey: "cloud.functionURL")
        d.set(CloudConfig.passwordHash, forKey: kPasswordHash)
        let compress = UserDefaults.standard.object(forKey: "compressOnShare") as? Bool
            ?? RemoteConfig.feature("compressUpload", true)
        d.set(compress, forKey: kCompress)
        d.set(CosConfig.load()?.customDomain ?? "", forKey: kCustomDomain)
        #if !APP_EXTENSION
        // 服务器地址与房源/通知令牌镜像进 App Group 共享区，供分享扩展直连服务器；
        // 扩展进程读不到主 App 的 standard UserDefaults 与内存缓存，只能经共享区取。
        d.set(NotifyHub.shared.endpoint, forKey: kEndpoint)
        if let t = MeterCloudSync.shared.token, !t.isEmpty {
            d.set(t, forKey: kToken)
        } else {
            // 断开/清除授权后必须同步清掉共享区旧令牌，否则扩展和 CloudOps 会拿旧令牌
            // 继续写服务器，表现为“已断开但日志/媒体还在上传”。
            d.removeObject(forKey: kToken)
        }
        #endif
    }

    /// v2.70 兜底：覆盖安装后主 App 尚未启动、镜像还没写时，扩展用与 App 默认口径同源的
    /// 默认云函数地址/默认口令哈希（口令默认值本就在 App 代码内，哈希本就随 k= 参数传输，
    /// 不扩大暴露面）。镜像一旦有值立即优先镜像，用户改过地址/口令后不受兜底影响。
    static let fallbackFunctionURL = "https://1511251056-csopw5c0jd.ap-hongkong.tencentscf.com"
    static let fallbackPasswordHash = "615ed7fb1504b0c724a296d7a69e6c7b2f9ea2c57c1d8206c5afdf392ebdfd25"

    static var mirroredPasswordHash: String {
        let s = defaults.string(forKey: kPasswordHash) ?? ""
        return s.isEmpty ? fallbackPasswordHash : s
    }

    /// 扩展读压缩开关：镜像优先；未镜像过按远程配置默认（与 App 内 shareCompressionEnabled 同口径）
    static var mirroredCompress: Bool {
        if defaults.object(forKey: kCompress) != nil { return defaults.bool(forKey: kCompress) }
        return RemoteConfig.feature("compressUpload", true)
    }

    static var mirroredCustomDomain: String { defaults.string(forKey: kCustomDomain) ?? "" }

    /// 扩展读服务器端点：镜像优先；未镜像过按主 App 默认地址兜底（与 MeterCloudConfig.defaultEndpoint 同值）。
    /// 规范化口径对齐 NotifyHub.endpoint：补 http:// 前缀、去尾斜杠。
    static var mirroredEndpoint: String {
        var s = (defaults.string(forKey: kEndpoint) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "http://114.132.93.85:8082" }
        if !s.hasPrefix("http://"), !s.hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 扩展读房源/通知令牌（App Group 镜像；为空返回 nil，扩展按未接入服务器处理）
    static var mirroredHouseToken: String? {
        let s = (defaults.string(forKey: kToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 一次性迁移：共享区无值时把 standard 旧值补进去（只补不覆盖，幂等）。
    /// 用于用户名/云函数地址/两队列等历史键，升级后两进程收敛到同一份。
    static func migrateKey(_ key: String) {
        let d = defaults
        guard d.object(forKey: key) == nil,
              let old = UserDefaults.standard.object(forKey: key) else { return }
        d.set(old, forKey: key)
    }
}
