import Foundation
import CryptoKit

// MARK: - v1.80 远程配置中心
/// 三级兜底：服务器远程配置（/api/house/config，权威）→ 本地缓存（Documents/Config/config_cache.json）→ 代码内置默认值
/// 联网时 App 启动 / 每次云端同步成功调用 refresh() 拉取最新并更新缓存；
/// 断网时读本地缓存；首次安装无缓存时用内置默认值（= 与现状完全一致）。
/// 后台可视化编辑入口：服务器管理后台「远程配置」页。
enum RemoteConfig {
    struct Announcement: Codable {
        var enabled: Bool
        var text: String
        var link: String?
    }
    /// v1.89：AI 模型清单（云端扩展，登录火山方舟抓取账号已开通模型后由后台写入；与本地内置合并展示）
    struct AIModelInfo: Codable, Identifiable, Hashable {
        var id: String { modelID }
        var modelID: String
        var name: String
        var desc: String
    }
    struct ChangelogEntry: Codable, Identifiable {
        var id: String { version + (date ?? "") }
        var version: String
        var date: String?
        var changes: [String]
    }
    struct Payload: Codable {
        var version: Int = 0
        var updatedAt: String?
        var updatedBy: String?
        var announcement: Announcement?
        var minimumVersion: String?
        var tips: [String: String] = [:]
        var features: [String: Bool] = [:]
        var params: [String: Double] = [:]
        var helpTexts: [String: String] = [:]
        var changelog: [ChangelogEntry]?
        var aiModels: [AIModelInfo]? = nil
        /// v2.21：App 在线更新（云端后台「App 更新」填写；桶里只存最新一个包）
        var update: UpdateInfo? = nil

        /// b29：公开更新接口只返回 update/changelog/minimumVersion 三块，
        /// 合成 Decodable 对缺失的非可选字段会抛 keyNotFound；这里统一按缺省值解码。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
            updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
            announcement = try c.decodeIfPresent(Announcement.self, forKey: .announcement)
            minimumVersion = try c.decodeIfPresent(String.self, forKey: .minimumVersion)
            tips = try c.decodeIfPresent([String: String].self, forKey: .tips) ?? [:]
            features = try c.decodeIfPresent([String: Bool].self, forKey: .features) ?? [:]
            params = try c.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]
            helpTexts = try c.decodeIfPresent([String: String].self, forKey: .helpTexts) ?? [:]
            changelog = try c.decodeIfPresent([ChangelogEntry].self, forKey: .changelog)
            aiModels = try c.decodeIfPresent([AIModelInfo].self, forKey: .aiModels)
            update = try c.decodeIfPresent(UpdateInfo.self, forKey: .update)
        }

        init() {}
    }

    /// v2.21：App 更新信息（云端 config.json 的 update 块）
    struct UpdateInfo: Codable, Equatable {
        var latestVersion: String?
        var latestBuild: Int?
        var releasedAt: String?
        var sizeBytes: Int?
        var notes: [String]?
        /// 服务器媒体路径（优先），如 update/公寓管家2.21-b144.ipa
        var objectKey: String?
        /// 备用 https 直链（objectKey 为空时使用）
        var downloadURL: String?
        /// 第三方签名平台安装页（填了才出现「去安装页」按钮）
        var installPageURL: String?
        var sha256: String?
    }

    private static var _current = Payload()
    static var current: Payload { _current }
    /// 最近一次配置/更新拉取的错误原文，设置页用于区分“令牌失效 / 超时 / 网络断”
    private(set) static var lastRefreshError: String?

    /// 配置缓存目录：Documents/Config/（随「备份」体系一起被文件 App 备份）
    private static var cacheDir: URL {
        let dir = DataRoot.url().appendingPathComponent("Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var cacheURL: URL { cacheDir.appendingPathComponent("config_cache.json") }

    /// App 启动时读取本地缓存（断网可用）
    static func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        _current = p
    }

    /// v1.81 原生后台保存成功后调用：写入内存 + 本地缓存（断网兜底）
    static func apply(_ p: Payload) {
        _current = p
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// 拉取服务器最新配置并更新缓存（联网时调用：App 启动 + 每次云端同步成功后）
    /// 返回是否拉取成功（在线更新检查据此区分「已是最新」与「连不上服务器」）
    @discardableResult
    static func refresh() async -> Bool {
        #if !APP_EXTENSION
        do {
            let client = HouseRemoteClient.shared
            let dict = try await client.fetchConfig()
            let data = try JSONSerialization.data(withJSONObject: dict)
            let p = try JSONDecoder().decode(Payload.self, from: data)
            _current = p
            try? data.write(to: cacheURL, options: .atomic)
            lastRefreshError = nil
            return true
        } catch {
            lastRefreshError = error.localizedDescription
            return false
        }
        #else
        return false
        #endif
    }

    /// b29：检查更新的兜底通道。
    /// /api/house/config 需要房源库授权，令牌过期/权限收紧时会把“只是查更新”误报成“连不上云端”；
    /// 公开更新块只含非敏感的 update/changelog/minimumVersion，可独立完成检查。
    @discardableResult
    static func refreshPublicUpdate() async -> Bool {
        #if !APP_EXTENSION
        do {
            let dict = try await HouseRemoteClient.shared.fetchPublicUpdate()
            let data = try JSONSerialization.data(withJSONObject: dict)
            let p = try JSONDecoder().decode(Payload.self, from: data)
            if let update = p.update { _current.update = update }
            if let changelog = p.changelog { _current.changelog = changelog }
            if let minimumVersion = p.minimumVersion { _current.minimumVersion = minimumVersion }
            if let cached = try? JSONEncoder().encode(_current) {
                try? cached.write(to: cacheURL, options: .atomic)
            }
            lastRefreshError = nil
            return true
        } catch {
            lastRefreshError = error.localizedDescription
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - 便捷读取（内置默认兜底，未配置时与 v1.79 行为完全一致）

    static func tip(_ key: String, _ fallback: String) -> String {
        _current.tips[key] ?? fallback
    }
    static func feature(_ key: String, _ fallback: Bool) -> Bool {
        _current.features[key] ?? fallback
    }
    static func param(_ key: String, _ fallback: Double) -> Double {
        _current.params[key] ?? fallback
    }
    static func help(_ key: String, _ fallback: String) -> String {
        _current.helpTexts[key] ?? fallback
    }
    static var announcement: Announcement? { _current.announcement }
    static var minimumVersion: String? {
        let v = _current.minimumVersion ?? ""
        return v.isEmpty ? nil : v
    }
    static var changelog: [ChangelogEntry]? { _current.changelog }
    /// 云端扩展的 AI 模型清单（可能为空；与 App 内置合并展示）
    static var aiModels: [AIModelInfo] { _current.aiModels ?? [] }

    /// 配置概览（设置页显示：版本 + 更新时间）
    static var summary: String {
        let ver = _current.version
        let updated = _current.updatedAt ?? "未同步"
        return "版本 \(ver) · 更新于 \(updated)"
    }
}

// MARK: - v2.21 App 在线更新（检查 → 提示 → 下载 → 签名工具安装）

/// 更新检查中心：数据全部来自云端 config.json 的 update 块（复用启动已有的配置拉取，不额外发请求）
@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    struct Available: Equatable, Identifiable {
        var id: String { "\(version)-\(build)" }
        var version: String
        var build: Int
        var releasedAt: String
        var sizeBytes: Int
        var notes: [String]
        var objectKey: String
        var downloadURL: String
        var installPageURL: String
        var sha256: String
    }

    enum CheckState: Equatable { case idle, checking, upToDate, failed }

    @Published private(set) var available: Available?
    @Published private(set) var checkState: CheckState = .idle
    @Published private(set) var lastCheckedAt: Date?
    /// 检查失败的原始原因（设置页副标题显示，避免一律归成“连不上云端”）
    @Published private(set) var failureDetail: String?
    /// v2.22：启动弹窗（只在每次冷启动检查出有新版本时置一次；关掉即清空）
    @Published private(set) var launchPopupVersion: String?

    private static let lastCheckKey = "update.lastCheckAt"
    private static let autoCheckKey = "update.autoCheckEnabled"

    /// 每次启动自动检查（默认开）
    static var autoCheckEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoCheckKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoCheckKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    static var appBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    private static func parts(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// 版本号按段比较（2.9 < 2.10），同一版本再比 build
    static func isNewer(version: String, build: Int) -> Bool {
        let a = parts(version)
        let b = parts(appVersion)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return build > appBuild
    }

    /// 从当前配置重算「有没有新版本」
    func evaluate() {
        guard let info = RemoteConfig.current.update else { available = nil; return }
        let v = (info.latestVersion ?? "").trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, Self.isNewer(version: v, build: info.latestBuild ?? 0) else {
            available = nil
            return
        }
        var notes = (info.notes ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if notes.isEmpty {
            let cloud = RemoteConfig.changelog ?? []
            if let hit = cloud.first(where: { $0.version == v || $0.version == "v\(v)" }) {
                notes = hit.changes
            }
        }
        available = Available(
            version: v,
            build: info.latestBuild ?? 0,
            releasedAt: info.releasedAt ?? "",
            sizeBytes: info.sizeBytes ?? 0,
            notes: notes,
            objectKey: info.objectKey ?? "",
            downloadURL: info.downloadURL ?? "",
            installPageURL: info.installPageURL ?? "",
            sha256: info.sha256 ?? ""
        )
    }

    /// 每次进 App 都跑一次（冷启动）——有新版本时弹一次启动弹窗
    func checkOnLaunch() async {
        await runCheck(showPopup: true)
    }

    /// 设置页「检查更新」手动触发（不弹启动弹窗，结果就地显示在设置页）
    func checkManually() async {
        await runCheck(showPopup: false)
    }

    func dismissLaunchPopup() {
        launchPopupVersion = nil
    }

    private func runCheck(showPopup: Bool) async {
        checkState = .checking
        // b32：检查更新先走公开更新块。它不依赖房源库授权，令牌过期/未绑定时
        // 也能真实判断有没有新版本；公开块失败才回退到需要授权的完整配置接口。
        var ok = await RemoteConfig.refreshPublicUpdate()
        if !ok { ok = await RemoteConfig.refresh() }
        failureDetail = ok ? nil : (RemoteConfig.lastRefreshError ?? "网络请求超时")
        evaluate()
        if available != nil {
            checkState = .idle
        } else {
            checkState = ok ? .upToDate : .failed
        }
        lastCheckedAt = Date()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        if showPopup, let a = available {
            launchPopupVersion = a.version
        }
    }
}

/// 安装包下载器：服务器媒体取（优先）或直链下载 → 存到 Documents/Updates/ → 可选 sha256 校验
@MainActor
final class UpdateDownloader: ObservableObject {
    /// 更新详情页可能被「稍后」关闭或从设置页重新进入；下载器和已下载文件必须跨页面保留。
    static let shared = UpdateDownloader()

    enum Phase: Equatable {
        case idle, downloading, verifying, ready, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var localURL: URL?

    private var task: URLSessionDownloadTask?
    private var pendingURLs: [URL] = []
    private var activeUpdate: UpdateCenter.Available?
    private var lastFailure = ""
    private let progressDelegate = UpdateDownloadProgressDelegate()
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg, delegate: progressDelegate,
                          delegateQueue: nil)
    }()

    var isBusy: Bool {
        if case .downloading = phase { return true }
        if case .verifying = phase { return true }
        return false
    }

    /// 重新进入详情页时优先复用已下载好的包；文件被清理/不完整才重新下载。
    func restoreIfDownloaded(_ update: UpdateCenter.Available) {
        guard !isBusy else { return }
        let name = update.objectKey.isEmpty
            ? "公寓管家\(update.version).ipa"
            : (update.objectKey as NSString).lastPathComponent
        let dest = Self.downloadsDirectory().appendingPathComponent(name)
        if case .ready = phase, localURL?.lastPathComponent == name { return }
        if case .ready = phase {
            phase = .idle
            progress = 0
            localURL = nil
        }
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        let actualSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if update.sizeBytes > 0, actualSize != update.sizeBytes { return }
        if !update.sha256.isEmpty, let data = try? Data(contentsOf: dest) {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if hash.lowercased() != update.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return
            }
        }
        localURL = dest
        progress = 1
        receivedBytes = Int64(actualSize)
        expectedBytes = Int64(update.sizeBytes)
        phase = .ready
    }

    func start(_ update: UpdateCenter.Available) {
        guard !isBusy else { return }
        var urls: [URL] = []
        // 服务器配置里的 downloadURL 是完整绝对地址，优先使用；objectKey 只作兜底。
        // 这样即使本机保存的服务器地址和安装包实际所在端口不一致，也不会下到别的服务。
        let direct = update.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty, let u = URL(string: direct) {
            urls.append(u)
        }
        if !update.objectKey.isEmpty {
            #if !APP_EXTENSION
            let base = NotifyHub.shared.endpoint
            let objectKey = update.objectKey
            let url: URL?
            if objectKey.hasPrefix("releases/") {
                // b31：新架构安装包落服务器 releases/ 目录，走专用公开下载接口；
                // 旧版 objectKey 仍兼容 /api/public/media/ 路径。
                let name = (objectKey as NSString).lastPathComponent
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                url = URL(string: "\(base)/api/public/release/\(encoded)")
            } else {
                let rel = objectKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectKey
                url = URL(string: "\(base)/api/public/media/\(rel)")
            }
            if let url { urls.append(url) }
            #endif
        }
        // 去重，避免 direct 与 objectKey 拼出同一条地址后重复下载一遍。
        var seen = Set<String>()
        pendingURLs = urls.filter { seen.insert($0.absoluteString).inserted }
        guard !pendingURLs.isEmpty else {
            phase = .failed("服务器还没有安装包，请在后台填 objectKey 或 downloadURL")
            return
        }
        activeUpdate = update
        lastFailure = ""
        beginNextDownload()
    }

    private func beginNextDownload() {
        guard let update = activeUpdate, !pendingURLs.isEmpty else {
            phase = .failed(lastFailure.isEmpty ? "没有可用的安装包地址" : lastFailure)
            return
        }
        let url = pendingURLs.removeFirst()
        progressTimer?.invalidate()
        progressTimer = nil
        phase = .downloading
        progress = 0
        receivedBytes = 0
        expectedBytes = Int64(update.sizeBytes)

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 120
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // didWriteData 比 task.progress 轮询可靠：小包/快网下后者经常一直是 0，完成才跳到 100%。
        progressDelegate.expect(Int64(update.sizeBytes))
        progressDelegate.onProgress = { [weak self] received, total in
            Task { @MainActor in
                self?.applyProgress(received: received, total: total)
            }
        }
        progressDelegate.onFinish = { [weak self] tmp, resp, err in
            Task { @MainActor in
                self?.finish(tmp: tmp, response: resp, error: err, update: update)
            }
        }
        let t = session.downloadTask(with: req)
        task = t
        t.resume()

        // 双保险：delegate 的 didWriteData 在部分 iOS/网络栈组合下可能不回调，
        // 再用 task.countOfBytesReceived 每 0.1 秒取一次；两者取较大值，进度不会停在 0。
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak t] _ in
            guard let self, let t else { return }
            let got = t.countOfBytesReceived
            let total = t.countOfBytesExpectedToReceive > 0
                ? t.countOfBytesExpectedToReceive : self.expectedBytes
            Task { @MainActor in
                self.applyProgress(received: got, total: total)
            }
        }
    }

    private func applyProgress(received: Int64, total: Int64) {
        guard case .downloading = phase else { return }
        let got = max(received, 0)
        let expected = total > 0 ? total : expectedBytes
        guard expected > 0 else { return }
        receivedBytes = max(receivedBytes, got)
        expectedBytes = expected
        progress = min(max(Double(receivedBytes) / Double(expected), 0), 1)
    }

    private func finish(tmp: URL?, response: URLResponse?, error: Error?, update: UpdateCenter.Available) {
        progressTimer?.invalidate()
        progressTimer = nil
        task = nil

        if let error {
            retryOrFail("下载失败：\(error.localizedDescription)")
            return
        }
        guard let tmp else {
            retryOrFail("下载失败：没有拿到文件")
            return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            retryOrFail("服务器返回 HTTP \(http.statusCode)，不是安装包")
            return
        }
        phase = .verifying

        let name = update.objectKey.isEmpty
            ? "公寓管家\(update.version).ipa"
            : (update.objectKey as NSString).lastPathComponent
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            retryOrFail("保存失败：\(error.localizedDescription)")
            return
        }

        let actualSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if update.sizeBytes > 0, actualSize != update.sizeBytes {
            try? FileManager.default.removeItem(at: dest)
            retryOrFail("下载不完整：实际 \(actualSize) 字节，应为 \(update.sizeBytes) 字节")
            return
        }

        if !update.sha256.isEmpty, let data = try? Data(contentsOf: dest) {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if hash.lowercased() != update.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                try? FileManager.default.removeItem(at: dest)
                retryOrFail("安装包校验失败：已下载 \(actualSize) 字节，SHA256 与服务器配置不一致")
                return
            }
        }

        // v2.23：校验通过后清掉目录里其它旧安装包——只留刚下载的这一个（每版约 10MB，不清理会一直堆）
        Self.pruneOldPackages(keep: dest)
        pendingURLs.removeAll()
        activeUpdate = nil
        localURL = dest
        progress = 1
        receivedBytes = Int64(actualSize)
        expectedBytes = Int64(update.sizeBytes)
        phase = .ready
    }

    /// 当前地址失败时自动换下一条；全部失败才把最后一个真实原因交给界面。
    private func retryOrFail(_ message: String) {
        lastFailure = message
        if !pendingURLs.isEmpty {
            beginNextDownload()
        } else {
            phase = .failed(message)
        }
    }
}

/// URLSessionDownloadDelegate 版进度：didWriteData 按字节回调，避免 10MB 包在快网下
/// task.progress 仍为 0、完成时直接跳到 100%。临时文件在 didFinish 里先复制，防被系统回收。
private final class UpdateDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((URL?, URLResponse?, Error?) -> Void)?

    private var expectedBytes: Int64 = 0
    private var finishedURL: URL?
    private var copyError: Error?
    private var response: URLResponse?

    func expect(_ bytes: Int64) {
        expectedBytes = max(bytes, 0)
        finishedURL = nil
        copyError = nil
        response = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else { return }
        onProgress?(max(totalBytesWritten, 0), total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        response = downloadTask.response
        let name = downloadTask.currentRequest?.url?.lastPathComponent ?? "update.ipa"
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        do {
            try FileManager.default.copyItem(at: location, to: dst)
            finishedURL = dst
        } catch {
            copyError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let err = error ?? copyError
        onFinish?(finishedURL, response, err)
        if err != nil, let finishedURL {
            try? FileManager.default.removeItem(at: finishedURL)
        }
    }
}

// MARK: - v2.23 下载包目录工具（设置页「清理下载的安装包」用）
extension UpdateDownloader {
    /// Updates/ 目录（App 沙盒 Documents/Updates，文件 App 可见）
    static func downloadsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 目录内全部 .ipa（按修改时间新→旧）
    static func downloadedPackages() -> [URL] {
        let dir = downloadsDirectory()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    /// 目录占用（字节）
    static func downloadsSizeBytes() -> Int {
        downloadedPackages().reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + size
        }
    }

    /// 清空目录内全部安装包（返回删除个数）
    @discardableResult
    static func clearDownloads() -> Int {
        let items = downloadedPackages()
        var n = 0
        for url in items {
            if (try? FileManager.default.removeItem(at: url)) != nil { n += 1 }
        }
        return n
    }

    /// 只保留指定这一个，其余 .ipa 全删
    static func pruneOldPackages(keep: URL) {
        for url in downloadedPackages() where url.standardizedFileURL != keep.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
