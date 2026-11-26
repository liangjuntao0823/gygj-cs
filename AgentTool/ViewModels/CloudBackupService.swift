import Foundation

// MARK: - 云端备份服务（服务器磁盘）
// 备份实体落服务器本地磁盘（替代旧 COS 桶 backups/ 目录）：
//   · 快速备份：备份后自动上传（断网/失败自动加入重试队列，下次启动或回前台自动重试）
//   · 全量备份：查看器里手动上传（zip 本体整体上传，媒体已含在 zip 内）
//   · 云端文件清单由服务器返回，本地 UserDefaults 同步维护权威记录
//   · 云端自动清理：只清「快速_」且含「_自动」后缀的自动备份，保留最近 10 份；全量手动上传不自动删除
//   · 未连服务器：快速备份仅存本地，查看器标记「未上传」

final class CloudBackupService {
    static let shared = CloudBackupService()
    private init() {}

    // 服务器备份条目日期解析（ISO8601，带时区偏移）
    private static var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }

    // MARK: - 云端记录（本地权威清单）

    struct CloudRecord: Codable {
        var name: String
        var size: Int64
        var date: Date
        var isAuto: Bool
    }

    // v1.24：本地权威记录按用户名分 key（切用户名互不串），空名用「未设置」占位
    private static var recordsKey: String { "cloudBackupRecords.\(CloudUser.safeName)" }

    static func cloudRecords() -> [CloudRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let list = try? JSONDecoder().decode([CloudRecord].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    static func isUploaded(name: String) -> Bool {
        cloudRecords().contains { $0.name == name }
    }

    static func uploadState(of name: String) -> String {
        if isUploaded(name: name) { return "已上传云端" }
        if pendingUploadNames().contains(name) { return "未上传（将自动重试）" }
        return "未上传"
    }

    static func recordUpload(name: String, size: Int64, date: Date, isAuto: Bool) {
        var list = cloudRecords()
        list.removeAll { $0.name == name }
        list.append(CloudRecord(name: name, size: size, date: date, isAuto: isAuto))
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
        removePendingUpload(name: name)
    }

    static func removeCloudRecord(name: String) {
        var list = cloudRecords()
        list.removeAll { $0.name == name }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    // MARK: - 待上传重试队列（断网/被系统杀死后下次启动自动重试）

    // v1.24：待上传重试队列也按用户名分 key
    private static var pendingKey: String { "cloudBackupPending.\(CloudUser.safeName)" }

    static func pendingUploadNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: pendingKey) ?? []
    }

    static func enqueuePendingUpload(name: String) {
        var list = pendingUploadNames()
        guard !list.contains(name) else { return }
        list.append(name)
        UserDefaults.standard.set(list, forKey: pendingKey)
    }

    static func removePendingUpload(name: String) {
        var list = pendingUploadNames()
        list.removeAll { $0 == name }
        UserDefaults.standard.set(list, forKey: pendingKey)
    }

#if !APP_EXTENSION // v2.68：分享扩展不编译备份 zip 链路（依赖 BackupV5Manager/ZipStore/MediaFingerprintV5）
    /// 启动/回前台时重试全部待上传（快速备份 zip）
    static func retryPendingUploads() async {
        let pending = pendingUploadNames()
        guard !pending.isEmpty else { return }
        for name in pending {
            let local = BackupV5Manager.backupsDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: local.path) else {
                removePendingUpload(name: name)
                continue
            }
            do {
                try await uploadZip(url: local) { _ in }
                recordUpload(name: name, size: BackupV5Manager.fileSize(at: local), date: Date(), isAuto: true)
            } catch {
                // 保留队列，下次再试
            }
        }
        await enforceCloudRetention()
    }
#endif

    // MARK: - 上传

    /// 上传备份 zip 到服务器（整体上传；媒体已包含在 zip 内，不再单独传媒体镜像）
    static func uploadZip(url: URL, progress: @escaping (Double) -> Void) async throws {
        let name = url.lastPathComponent
        let data = try Data(contentsOf: url)
        progress(0.5)
        try await HouseRemoteClient.shared.uploadBackup(name: name, data: data, isAuto: false)
        progress(1.0)
    }

#if !APP_EXTENSION
    /// 全量备份媒体镜像增量（旧 COS sha1 去重镜像）：服务器架构下媒体已含在全量 zip 内，
    /// 不再单独上传媒体镜像；保留方法壳避免调用点编译断裂，直接完成进度。
    static func uploadFullMedia(zipURL: URL, progress: @escaping (Double) -> Void) async throws {
        progress(1.0)
    }
#endif

#if !APP_EXTENSION
    /// 自动上传快速备份（失败入队重试，成功后清理队列并执行云端保留）
    static func autoUploadFastBackup(zipURL: URL) async {
        do {
            try await uploadZip(url: zipURL) { _ in }
            recordUpload(name: zipURL.lastPathComponent, size: BackupV5Manager.fileSize(at: zipURL), date: Date(), isAuto: true)
        } catch {
            enqueuePendingUpload(name: zipURL.lastPathComponent)
        }
        await enforceCloudRetention()
    }
#endif

    // MARK: - 下载 / 删除

    /// 下载服务器备份 zip 到本地，返回文件 URL。
    /// 下载前先检查本地是否已有该备份（同名 zip 或 下载_ 前缀副本）→ 有则直接复用；
    /// 下载完成后逐文件 CRC 核对（防损坏/不完整），失败删除临时文件并抛错。
    /// 落盘直接使用服务器原名（快速_/全量_ 前缀），本地备份列表可直接识别并恢复。
#if !APP_EXTENSION
    static func downloadBackup(name: String) async throws -> URL {
        if let existing = localCopyIfExists(name: name) {
            return existing
        }
        let data = try await HouseRemoteClient.shared.downloadBackup(name: name)
        let dest = BackupV5Manager.backupsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        do {
            _ = try ZipStore.verifyAllEntriesCRC(at: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }

    /// v1.13 需求15：检查本地 Backups 目录是否已有该云端备份的副本
    /// 命中规则：①同名 zip（本地快速/全量原文件）；②「下载_」+ 名（之前从云端下载过的副本）
    static func localCopyIfExists(name: String) -> URL? {
        let dir = BackupV5Manager.backupsDirectory
        let sameName = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: sameName.path) {
            return sameName
        }
        let downloaded = dir.appendingPathComponent("下载_" + name)
        if FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        return nil
    }
#endif

    /// 实时刷新服务器备份清单并同步到本地权威记录。
    /// 以服务器返回清单为准重建 cloudRecords：服务器真实存在的 → 记录；已删除的 → 本地记录同步移除。
    /// isAuto 优先取服务器标记，缺省时按文件名含「_自动」后缀兜底判定。
    static func refreshCloudRecords() async throws {
        let remote = try await HouseRemoteClient.shared.listBackups()
        var records: [CloudRecord] = []
        for item in remote {
            guard item.name.hasSuffix(".zip") else { continue }
            let date = item.date.flatMap { dateFormatter.date(from: $0) } ?? Date()
            records.append(CloudRecord(
                name: item.name,
                size: item.size ?? 0,
                date: date,
                isAuto: item.isAuto ?? item.name.contains("_自动")))
        }
        records.sort { $0.date > $1.date }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    /// 删除服务器备份 zip
    static func deleteRemoteBackup(name: String) async throws {
        try await HouseRemoteClient.shared.deleteBackup(name: name)
        removeCloudRecord(name: name)
    }

    // MARK: - v1.13 需求19：删除房源在桶里的整个文件夹 h/<roomKey>/

    /// 列出一套房源在桶里 h/<roomKey>/ 下的全部对象（含封面、视频首帧、分享页等，不含 backups/ 前缀）
    static func listHouseRemoteObjects(roomKey: String, config: CosConfig) async throws -> [String] {
        let prefix = "h/\(roomKey)/"
        let items = try await CosUploader.listObjects(prefix: prefix, delimiter: nil, config: config)
        return items.map { $0.name }
    }

    /// 删除单个云端对象（h/<roomKey>/ 下用；403/404 不视为失败——对象可能已被手动删过）
    static func deleteRemoteObject(name: String, config: CosConfig) async throws {
        guard let url = try? CosUploader.presignedURL(for: name, method: "DELETE", expires: 600, headers: [], config: config) else {
            throw CosUploader.CosError.invalidConfig
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, (200...299).contains(status) {
            return   // 删除成功
        }
        // 404 = 对象不存在（已被删过/未上传过），视为已删除成功；其余错误抛给上层
        if let status = http?.statusCode, status == 404 {
            return
        }
        throw CosUploader.CosError.uploadFailed("云端删除失败（HTTP \(http?.statusCode ?? 0)）" + CosUploader.extractCosError(from: data))
    }

    /// 删除房源在桶里的整个文件夹（h/<房号>/ 共享媒体 + users/<用户名>/shares/<房号>/ 私有分享页）。
    /// v1.40 第6点：分享页/封面/视频首帧图已移入用户私有目录，删房时必须一并删除，避免残留
    /// 无云端配置或桶里无该房源的文件夹时静默返回（不打断本地删除）；
    /// 单个对象删除失败会继续删其余对象，最终把第一个错误抛给上层（供 App 分开提示本地已删、云端失败）。
    /// 删除整套房源在云端的全部对象（h/<房号>/ 媒体 + 用户区分享页/首帧图）。
    /// v1.69：writeLog=false 时不写「云端删除房源文件夹」日志（由删除调用方统一记一条
    /// 「彻底删除（本地+云端）」）；reportCount 回传实际删除对象数（含 0=桶里本就没有）。
    static func deleteHouseRemoteFolder(roomKey: String, config: CosConfig?, writeLog: Bool = true, reportCount: ((Int) -> Void)? = nil) async throws {
        guard let config = config ?? CosConfig.load(), config.isValid else { return }
        var objects = try await listHouseRemoteObjects(roomKey: roomKey, config: config)
        // v1.40：私有分享页目录（用户区）
        let sharePrefix = CloudUser.sharePagePrefix + roomKey + "/"
        let shareObjects = (try? await CosUploader.listObjects(prefix: sharePrefix, delimiter: nil, config: config).map { $0.name }) ?? []
        objects.append(contentsOf: shareObjects)
        guard !objects.isEmpty else {
            reportCount?(0)
            if writeLog {
                BackupLogStore.log(category: "删除", action: "云端删除房源文件夹", result: "成功", detail: "h/\(roomKey)/ 桶内无对象", cloud: true)
            }
            return
        }
        var firstError: Error?
        for name in objects {
            do {
                try await deleteRemoteObject(name: name, config: config)
            } catch {
                // v2.57（P3-18）：完整错误描述（String(describing:) 带错误类型，localizedDescription 会吃掉细节）
                BackupLogStore.log(category: "删除", action: "云端删除对象", result: "失败", detail: "\(name)：\(String(describing: error))", cloud: true)
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
        reportCount?(objects.count)
        if writeLog {
            BackupLogStore.log(category: "删除", action: "云端删除房源文件夹", result: "成功", detail: "h/\(roomKey)/ + 用户分享页 共 \(objects.count) 个对象", cloud: true)
        }
    }

    // MARK: - 云端保留（快速_ 且文件名带 _自动 的自动备份保留最近 10 份）

    /// 只清理「文件名含 _自动 后缀」的自动备份，保留最近 10 份；
    /// 手动备份（文件名不带 _自动，含手动快速备份与手动全量上传）一律不清理。
    static func enforceCloudRetention() async {
        var records = cloudRecords().filter { $0.name.hasPrefix("快速_") && $0.name.contains("_自动") }
        records.sort { $0.date > $1.date }
        guard records.count > 10 else { return }
        for record in records.dropFirst(10) {
            try? await deleteRemoteBackup(name: record.name)
        }
    }
}
