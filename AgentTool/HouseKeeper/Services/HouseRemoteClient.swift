//
//  HouseRemoteClient.swift
//  公寓管家 · 房源板块服务器权威 API 客户端
//
//  服务器（8082 内 house-keeper 模块）为唯一权威；本类负责 JSON 收发与媒体二进制直传/直出，
//  媒体实体全部落服务器本地磁盘（不再使用 COS 桶）。
//  复用：服务器地址 NotifyHub.shared.endpoint、租户令牌 MeterCloudSync.shared.token。
//

import Foundation

// MARK: - 服务器 DTO

struct RemoteHouse: Codable, Identifiable, Hashable {
    let roomKey: String
    let roomNo: String
    let tower: Int
    let landlord: String
    let layout: String
    let price: Int
    let password: String
    let remark: String
    let status: String
    let revision: Int
    let isDeleted: Bool?
    let createdAt: String?
    let updatedAt: String?
    let updatedBy: String?
    let media: [RemoteMedia]?
    var id: String { roomKey }
    var trashed: Bool { isDeleted ?? false }
}

struct RemoteMedia: Codable, Identifiable, Hashable {
    let objectKey: String
    let fileName: String
    let kind: String          // image / video
    let sortOrder: Int?
    var id: String { objectKey }
}

struct RemoteHouseList: Codable {
    let ok: Bool
    let serverTime: String?
    let topRevision: Int
    let count: Int
    let houses: [RemoteHouse]
}

struct RemoteLedgerList: Codable {
    let ok: Bool
    let roomKey: String
    let ledger: [RemoteLedgerEvent]
}

struct RemoteLedgerEvent: Codable, Identifiable {
    let id: String
    let ts: String
    let operatorName: String?
    let action: String
    let detail: String?
    let migrated: Bool?
    let fieldChanges: [RemoteFieldChange]?
    enum CodingKeys: String, CodingKey {
        case id, ts, operatorName = "operator", action, detail, migrated, fieldChanges
    }
}

struct RemoteFieldChange: Codable, Hashable {
    let field: String
    let oldValue: String
    let newValue: String
}

struct RemoteLedgerWriteItem: Codable {
    let ok: Bool?
    let id: String?
    let deduplicated: Bool?
}

struct RemoteLedgerWriteResult: Codable {
    let ok: Bool
    let results: [RemoteLedgerWriteItem]?
}

struct RemoteHouseStats: Codable {
    let ok: Bool
    let total: Int
    let tower1: Int
    let tower2: Int
    let pendingOutbox: Int
}

/// 服务器备份 zip 清单条目（替代旧 COS ListObjects 对象元数据）
struct RemoteBackupRecord: Codable {
    let name: String
    let size: Int64?
    let date: String?
    let isAuto: Bool?
}

struct RemoteBackupList: Codable {
    let ok: Bool
    let backups: [RemoteBackupRecord]
}

/// 批量写入单套结果：成功带服务器权威房源，失败带结构化错误。
struct HouseBatchWriteOutcome {
    let roomKey: String
    let house: RemoteHouse?
    let error: HouseAPIError?
}

struct RemoteOrphanMedia: Codable, Identifiable, Hashable {
    let objectKey: String
    let size: Int
    let modifiedAt: String
    var id: String { objectKey }
}

struct RemoteOrphanList: Codable {
    let ok: Bool
    let files: [RemoteOrphanMedia]
    let count: Int
    let totalBytes: Int
    let minAgeSeconds: Int
}

struct RemoteOrphanDeleteResult: Codable {
    let ok: Bool
    let deleted: [String]
    let skipped: [RemoteOrphanSkip]
}

struct RemoteOrphanSkip: Codable, Hashable {
    let objectKey: String
    let reason: String
}

struct HouseAPIError: LocalizedError {
    let message: String
    /// 服务器已识别令牌，但该用户未被授权访问房源库（403）；此类错误不应自动重试
    let forbidden: Bool
    /// 乐观锁冲突：本机基于旧 revision 提交，服务器已有他人新版本
    let revisionConflict: Bool
    /// 新增房源时服务器已有同座同房号（房号重复）
    let duplicateRoom: Bool
    /// 字段级合并冲突：服务器同一字段也被其他设备改成了不同值
    let fieldConflict: Bool
    let fieldConflicts: [[String: String]]

    init(message: String, forbidden: Bool = false, revisionConflict: Bool = false,
         duplicateRoom: Bool = false, fieldConflict: Bool = false,
         fieldConflicts: [[String: String]] = []) {
        self.message = message
        self.forbidden = forbidden
        self.revisionConflict = revisionConflict
        self.duplicateRoom = duplicateRoom
        self.fieldConflict = fieldConflict
        self.fieldConflicts = fieldConflicts
    }

    var errorDescription: String? { message }
}

/// 「连接」测试结果：服务器可达 + 令牌状态
enum HouseConnectionCheck: Equatable {
    /// 可达，且本机令牌有效、具备房源权限
    case connectedWithAuth
    /// 可达，但本机尚未绑定账号令牌
    case reachableNoToken
    /// 连接失败，带可读原因
    case failed(String)

    var summary: String {
        switch self {
        case .connectedWithAuth: return "连接成功：服务器可达，账号已具备房源权限"
        case .reachableNoToken: return "服务器可达，但本机尚未绑定账号令牌（在本页输入服务器授权码接入）"
        case .failed(let reason): return reason
        }
    }

    var isPositive: Bool {
        if case .failed = self { return false }
        return true
    }
}

// MARK: - 客户端

@MainActor
final class HouseRemoteClient {
    static let shared = HouseRemoteClient()

    private let originKey = "house.originDeviceId.v1"
    private let timeout: TimeInterval = 12

    /// 稳定的本设备标识：服务器广播时排除这台设备（本机走本地通知，沿用现有文案）
    var originDeviceId: String {
        if let s = UserDefaults.standard.string(forKey: originKey), !s.isEmpty { return s }
        let s = "dev_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
        UserDefaults.standard.set(s, forKey: originKey)
        return s
    }

    private var endpoint: String { NotifyHub.shared.endpoint }
    private var token: String? { MeterCloudSync.shared.token }
    private var operatorName: String { CloudUser.signedUsername }

    private init() {}

    // MARK: 基础请求

    private func makeRequest(_ path: String, method: String,
                             body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let base = URL(string: endpoint),
              let url = URL(string: path, relativeTo: base) else {
            throw HouseAPIError(message: "服务器地址无效，请在「云端配置」检查服务器地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HouseAPIError(message: "服务器无响应")
        }
        if http.statusCode == 403 {
            throw HouseAPIError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func encodedRoomKey(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
    }

    // MARK: 读

    /// 增量拉取：since 为本地已见最高修订号，只返回之后变化的房源
    func listHouses(since: Int? = nil) async throws -> RemoteHouseList {
        var path = "/api/house/houses"
        if let since { path += "?since=\(since)" }
        let (data, http) = try await makeRequest(path, method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取房源失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteHouseList.self, data: data)
    }

    func getHouse(_ roomKey: String) async throws -> RemoteHouse? {
        let path = "/api/house/houses/\(encodedRoomKey(roomKey))"
        let (data, http) = try await makeRequest(path, method: "GET")
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取房源失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteHouse.self, data: data)
    }

    func ledger(_ roomKey: String) async throws -> [RemoteLedgerEvent] {
        let path = "/api/house/houses/\(encodedRoomKey(roomKey))/ledger"
        let (data, http) = try await makeRequest(path, method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取账本失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteLedgerList.self, data: data).ledger
    }

    /// 上报一条账本事件（append-only，服务器按事件 id 幂等去重）；不进实时广播
    func appendLedger(roomKey: String, event: HouseLedgerEvent) async throws {
        let ts = ISO8601DateFormatter().string(from: event.date)
        let changes = event.fieldChanges.map { ch -> [String: String] in
            ["field": ch.field, "oldValue": ch.oldValue, "newValue": ch.newValue]
        }
        let body: [String: Any] = [
            "id": event.id,
            "ts": ts,
            "operator": operatorName,
            "originDeviceId": originDeviceId,
            "action": event.action,
            "detail": event.detail,
            "migrated": event.migrated,
            "fieldChanges": changes,
        ]
        let path = "/api/house/houses/\(encodedRoomKey(roomKey))/ledger"
        let (data, http) = try await makeRequest(path, method: "POST", body: body)
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "账本同步失败（服务器 \(http.statusCode)）")
        }
        let result = try decode(RemoteLedgerWriteResult.self, data: data)
        guard result.ok else {
            throw HouseAPIError(message: "服务器未接收账本事件")
        }
    }

    func stats() async throws -> RemoteHouseStats {
        let (data, http) = try await makeRequest("/api/house/stats", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取统计失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteHouseStats.self, data: data)
    }

    /// 连接测试：先打公开 health 验证地址可达；有本机令牌再用 stats 校验鉴权与房源权限。
    /// 不抛错，结果统一回 HouseConnectionCheck，便于设置页直接展示成功/失败原因。
    func testConnection() async -> HouseConnectionCheck {
        guard let base = URL(string: endpoint),
              let healthURL = URL(string: "/api/house/health", relativeTo: base) else {
            return .failed("服务器地址无效")
        }
        // 1) 公开 health：验证地址可达、服务在线
        do {
            var req = URLRequest(url: healthURL)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("服务器无响应") }
            guard http.statusCode == 200 else {
                return .failed("服务器响应异常（HTTP \(http.statusCode)）")
            }
        } catch {
            return .failed("无法连接到服务器：\(error.localizedDescription)")
        }

        // 2) 可达但本机无令牌：提示未绑定账号，不算失败
        guard let t = token, !t.isEmpty else { return .reachableNoToken }

        // 3) 有令牌：stats 校验鉴权与房源权限
        guard let statsURL = URL(string: "/api/house/stats", relativeTo: base) else {
            return .failed("服务器地址无效")
        }
        do {
            var req = URLRequest(url: statsURL)
            req.httpMethod = "GET"
            req.timeoutInterval = 8
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return .connectedWithAuth
            case 401: return .failed("令牌无效或已过期，请重新绑定账号")
            case 403: return .failed("当前账号暂无房源访问权限")
            default: return .failed("鉴权失败（HTTP \(code)）")
            }
        } catch {
            return .failed("令牌校验失败：\(error.localizedDescription)")
        }
    }

    // MARK: 媒体（服务器本地磁盘，二进制直传/直出）

    /// 上传单个媒体文件到服务器；返回服务器相对引用 objectKey 与落盘文件名
    func uploadMedia(roomKey: String, fileName: String, kind: String,
                     data: Data) async throws -> (objectKey: String, fileName: String) {
        let path = "/api/house/media/\(encodedRoomKey(roomKey))"
        guard let base = URL(string: endpoint),
              let url = URL(string: path, relativeTo: base) else {
            throw HouseAPIError(message: "服务器地址无效")
        }

        // 上传前统一走分享压缩同一套参数：图片长边 ≤1600/JPEG 0.8；视频 960/1 Mbps H.264 mp4。
        // 本地旧版本已经落盘的 .mov 也在这里补转码，避免原片直传。
        var uploadData = data
        var uploadName = MediaNaming.remoteName(fileName: fileName, kind: kind)
        let ext = (fileName as NSString).pathExtension.lowercased()
        if kind == "video" {
            let container = MediaNaming.videoExtension(for: data)
            // 只补转真正的 QuickTime 原片；已是 mp4 容器（含本地 .mov 名但内容已压成 mp4）不重复转码。
            if container == "mov" {
                if let mp4 = await CosUploader.optimizedVideoDataForUpload(
                    from: data, compress: shareCompressionEnabled) {
                    uploadData = mp4
                    uploadName = (uploadName as NSString).deletingPathExtension + ".mp4"
                }
            }
        } else if ["jpg", "jpeg"].contains(ext), data.count > 2_500_000 {
            if let jpeg = CosUploader.optimizedImageDataForUpload(data, compress: true) {
                uploadData = jpeg
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // HTTP 头只能是 ASCII：中文房号/文件名的原始值会被 URLSession 截断成 ASCII 前缀
        //（实测 1-1234测试-... → 服务端只收到 1-1234）。这里百分号编码，服务端 unquote 还原，
        // 保证落盘名与客户端账本引用一致。
        let headerName = uploadName.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? uploadName
        req.setValue(headerName, forHTTPHeaderField: "X-File-Name")
        req.setValue(kind, forHTTPHeaderField: "X-Kind")
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = uploadData
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HouseAPIError(message: "媒体上传失败（服务器响应无效）")
        }
        if http.statusCode == 403 {
            throw HouseAPIError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "媒体上传失败（服务器 \(http.statusCode)）")
        }
        let envelope = try decode(RemoteMediaUpload.self, data: respData)
        guard envelope.ok, let objectKey = envelope.objectKey else {
            throw HouseAPIError(message: "服务器未返回媒体引用")
        }
        let actualName = envelope.fileName ?? uploadName
        // 本地保留原文件名/后缀，服务器可能唯一化或把视频转成 .mp4；
        // 这里把 objectKey ↔ 本地名写进共享映射，后续 media_refs / 播放 / 删除都用真实对。
        HouseMediaNameMap.set(roomKey: roomKey, objectKey: objectKey,
                              localFileName: fileName)
        return (objectKey, actualName)
    }

    /// 从服务器下载媒体二进制
    func downloadMedia(roomKey: String, fileName: String) async throws -> Data {
        // 服务器可能已把本地名唯一化/转成 .mp4：优先按映射取真实落盘名
        let remoteName: String
        if let objectKey = HouseMediaNameMap.objectKey(roomKey: roomKey, localFileName: fileName) {
            remoteName = (objectKey as NSString).lastPathComponent
        } else {
            let kind = ["mov", "m4v", "mp4", "avi"].contains((fileName as NSString).pathExtension.lowercased()) ? "video" : "image"
            remoteName = MediaNaming.remoteName(fileName: fileName, kind: kind)
        }
        let path = "/api/house/media/\(encodedRoomKey(roomKey))/\(encodedRoomKey(remoteName))"
        guard let base = URL(string: endpoint),
              let url = URL(string: path, relativeTo: base) else {
            throw HouseAPIError(message: "服务器地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 120
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HouseAPIError(message: "媒体下载失败（服务器响应无效）")
        }
        if http.statusCode == 403 {
            throw HouseAPIError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "媒体下载失败（服务器 \(http.statusCode)）")
        }
        return data
    }

    /// 删除服务器上的单个媒体文件
    func deleteMedia(roomKey: String, fileName: String) async throws {
        // 优先用上传时记下的 objectKey ↔ 本地名映射；没有映射再按旧口径把 .mov 换算成 .mp4。
        let remoteName: String
        if let objectKey = HouseMediaNameMap.objectKey(roomKey: roomKey,
                                                       localFileName: fileName) {
            remoteName = (objectKey as NSString).lastPathComponent
        } else {
            let kind = ["mov", "m4v", "mp4", "avi"].contains((fileName as NSString).pathExtension.lowercased())
                ? "video" : "image"
            remoteName = MediaNaming.remoteName(fileName: fileName, kind: kind)
        }
        let path = "/api/house/media/\(encodedRoomKey(roomKey))/\(encodedRoomKey(remoteName))"
        let (_, http) = try await makeRequest(path, method: "DELETE")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "媒体删除失败（服务器 \(http.statusCode)）")
        }
    }

    // MARK: 备份 zip（服务器本地磁盘，替代旧 COS backups/ 目录）

    /// 读取服务器备份清单
    func listBackups() async throws -> [RemoteBackupRecord] {
        let (data, http) = try await makeRequest("/api/house/backups", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取备份清单失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteBackupList.self, data: data).backups
    }

    /// 上传备份 zip 到服务器；isAuto 标记快速自动备份（云端保留策略据此裁剪）
    func uploadBackup(name: String, data: Data, isAuto: Bool) async throws {
        guard let base = URL(string: endpoint),
              let url = URL(string: "/api/house/backups", relativeTo: base) else {
            throw HouseAPIError(message: "服务器地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(name, forHTTPHeaderField: "X-Backup-Name")
        req.setValue(isAuto ? "1" : "0", forHTTPHeaderField: "X-Is-Auto")
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HouseAPIError(message: "备份上传失败（服务器响应无效）")
        }
        if http.statusCode == 403 {
            throw HouseAPIError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "备份上传失败（服务器 \(http.statusCode)）")
        }
    }

    /// 从服务器下载备份 zip 二进制（落盘与 CRC 校验由调用方完成）
    func downloadBackup(name: String) async throws -> Data {
        let path = "/api/house/backups/\(encodedRoomKey(name))"
        guard let base = URL(string: endpoint),
              let url = URL(string: path, relativeTo: base) else {
            throw HouseAPIError(message: "服务器地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 300
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HouseAPIError(message: "备份下载失败（服务器响应无效）")
        }
        if http.statusCode == 403 {
            throw HouseAPIError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "备份下载失败（服务器 \(http.statusCode)）")
        }
        return data
    }

    /// 删除服务器上的备份 zip
    func deleteBackup(name: String) async throws {
        let path = "/api/house/backups/\(encodedRoomKey(name))"
        let (_, http) = try await makeRequest(path, method: "DELETE")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "备份删除失败（服务器 \(http.statusCode)）")
        }
    }

    /// 服务器模式回补本地缺失媒体：按本地记录名单逐个从服务器下载落盘，已存在的跳过；
    /// 单个缺失跳过不中断整批。返回本次新落盘的 (fileName, kind)。
    func downloadMissingMedia(roomKey: String, records: [(fileName: String, kind: String)]) async -> [(fileName: String, kind: String)] {
        let existing = Set(MediaStore.existingFileNames(roomKey: roomKey).map { MediaNaming.canonicalKey($0) })
        var done: [(fileName: String, kind: String)] = []
        let imageExts = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif"]
        for record in records {
            let name = record.fileName
            let lower = name.lowercased()
            let isVideo = record.kind == "video" || lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v")
            let isImage = !isVideo && imageExts.contains { lower.hasSuffix($0) }
            guard isVideo || isImage else { continue }
            if existing.contains(MediaNaming.canonicalKey(name)) { continue }

            // 服务器视频统一 .mp4：记录若是 .mov，先试记录名再回退 .mp4
            let candidates: [String]
            if isVideo {
                let base = (name as NSString).deletingPathExtension
                candidates = [name, base + ".mp4"]
            } else {
                candidates = [name]
            }
            var data: Data?
            var remoteName = name
            for candidate in candidates {
                if let d = try? await downloadMedia(roomKey: roomKey, fileName: candidate) {
                    data = d
                    remoteName = candidate
                    break
                }
            }
            guard let downloaded = data else { continue }

            let saveName: String
            if isVideo {
                let ext = MediaNaming.videoExtension(for: downloaded)
                saveName = ((remoteName as NSString).deletingPathExtension) + "." + ext
            } else {
                saveName = remoteName
            }
            guard MediaStore.write(data: downloaded, fileName: saveName, roomKey: roomKey) else { continue }
            done.append((saveName, isVideo ? "video" : "image"))
        }
        return done
    }

    // MARK: 配置 / 名片 / 分享记录（服务器权威）

    /// 读取应用远程配置（返回 config 字典，解码为 RemoteConfig.Payload）
    func fetchConfig() async throws -> [String: Any] {
        let (data, http) = try await makeRequest("/api/house/config", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取配置失败（服务器 \(http.statusCode)）")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["config"] as? [String: Any]) ?? [:]
    }

    /// 写回应用远程配置
    func putConfig(_ dict: [String: Any]) async throws {
        let (_, http) = try await makeRequest("/api/house/config", method: "PUT", body: dict)
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "保存配置失败（服务器 \(http.statusCode)）")
        }
    }

    /// 读取名片（姓名 / 电话 / 二维码引用）
    func fetchProfile() async throws -> [String: Any] {
        let (data, http) = try await makeRequest("/api/house/profile", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取名片失败（服务器 \(http.statusCode)）")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["profile"] as? [String: Any]) ?? [:]
    }

    /// 写回名片
    func putProfile(name: String, phone: String, qrPath: String) async throws {
        let body: [String: Any] = ["name": name, "phone": phone, "qrPath": qrPath]
        let (_, http) = try await makeRequest("/api/house/profile", method: "PUT", body: body)
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "保存名片失败（服务器 \(http.statusCode)）")
        }
    }

    /// 读取分享记录列表
    func fetchShareRecords() async throws -> [[String: Any]] {
        let (data, http) = try await makeRequest("/api/house/share-records", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取分享记录失败（服务器 \(http.statusCode)）")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["records"] as? [[String: Any]]) ?? []
    }

    /// 追加一条分享记录
    func addShareRecord(roomKey: String, channel: String, summary: String) async throws {
        let body: [String: Any] = ["roomKey": roomKey, "channel": channel,
                                   "summary": summary, "operator": operatorName]
        let (_, http) = try await makeRequest("/api/house/share-records", method: "POST", body: body)
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "记录分享失败（服务器 \(http.statusCode)）")
        }
    }

    // MARK: 写

    /// 新增或编辑；expectedRevision 为编辑前修订号（乐观锁），新增传 nil
    @discardableResult
    func upsert(_ payload: HouseSyncPayload, expectedRevision: Int?,
                createOnly: Bool = false) async throws -> RemoteHouse {
        var body: [String: Any] = payload.json
        body["operator"] = operatorName
        body["originDeviceId"] = originDeviceId
        if let expectedRevision { body["expectedRevision"] = expectedRevision }
        if createOnly { body["createOnly"] = true }
        let (data, http) = try await makeRequest("/api/house/houses", method: "POST", body: body)
        if http.statusCode == 401 {
            throw HouseAPIError(message: "登录已失效，请重新接入服务器")
        }
        let result = try decode(HouseWriteResult.self, data: data)
        guard let r = result.results?.first else {
            throw HouseAPIError(message: "服务器返回格式异常")
        }
        if r.ok == false {
            if r.error == "revision_conflict" {
                throw HouseAPIError(message: "该房源刚被其他人修改，请刷新后再编辑",
                                   revisionConflict: true)
            }
            if r.error == "field_conflict" {
                let conflicts = (r.conflicts ?? []).compactMap { c -> [String: String]? in
                    guard let field = c["field"] else { return nil }
                    return ["field": field, "label": c["label"] ?? field,
                            "base": c["base"] ?? "", "client": c["client"] ?? "",
                            "server": c["server"] ?? ""]
                }
                let text = conflicts.map { "\($0["label"] ?? ""): 你填 \($0["client"] ?? "")，服务器已改为 \($0["server"] ?? "")" }
                    .joined(separator: "；")
                throw HouseAPIError(message: text.isEmpty ? "同一字段已被其他设备修改，请刷新后重试" : text,
                                   fieldConflict: true, fieldConflicts: conflicts)
            }
            if r.error == "duplicate_room" {
                throw HouseAPIError(message: r.detail ?? "该房号已在服务器收录，不能重复添加",
                                   duplicateRoom: true)
            }
            throw HouseAPIError(message: r.detail ?? "保存失败")
        }
        guard let house = r.house else {
            throw HouseAPIError(message: "服务器未回写房源数据")
        }
        return house
    }

    /// 批量写入（一次 HTTP 提交多套）；返回每套的结果，单套失败不拖垮整批。
    func upsertBatch(_ payloads: [HouseSyncPayload],
                     expectedRevisions: [Int?],
                     createOnly: [Bool]) async throws -> [HouseBatchWriteOutcome] {
        var houses: [[String: Any]] = []
        for (i, payload) in payloads.enumerated() {
            var body = payload.json
            body["operator"] = operatorName
            body["originDeviceId"] = originDeviceId
            if i < expectedRevisions.count, let expected = expectedRevisions[i] {
                body["expectedRevision"] = expected
            }
            if i < createOnly.count, createOnly[i] { body["createOnly"] = true }
            houses.append(body)
        }
        let body: [String: Any] = ["operator": operatorName,
                                   "originDeviceId": originDeviceId,
                                   "houses": houses]
        let (data, http) = try await makeRequest("/api/house/houses:batch", method: "POST",
                                                 body: body)
        if http.statusCode == 401 {
            throw HouseAPIError(message: "登录已失效，请重新接入服务器")
        }
        let result = try decode(HouseWriteResult.self, data: data)
        guard let items = result.results else {
            throw HouseAPIError(message: "服务器批量返回格式异常")
        }
        var outcomes: [HouseBatchWriteOutcome] = []
        for (i, item) in items.enumerated() {
            let key = i < payloads.count ? payloads[i].roomKey : ""
            if item.ok == true, let house = item.house {
                outcomes.append(HouseBatchWriteOutcome(roomKey: key, house: house, error: nil))
            } else {
                let text = item.detail ?? "保存失败"
                let err: HouseAPIError
                if item.error == "field_conflict" {
                    let conflicts = (item.conflicts ?? []).compactMap { c -> [String: String]? in
                        guard let field = c["field"] else { return nil }
                        return ["field": field, "label": c["label"] ?? field,
                                "base": c["base"] ?? "", "client": c["client"] ?? "",
                                "server": c["server"] ?? ""]
                    }
                    err = HouseAPIError(message: text, fieldConflict: true,
                                        fieldConflicts: conflicts)
                } else if item.error == "revision_conflict" {
                    err = HouseAPIError(message: "该房源刚被其他人修改，请刷新后再编辑",
                                        revisionConflict: true)
                } else if item.error == "duplicate_room" {
                    err = HouseAPIError(message: text, duplicateRoom: true)
                } else {
                    err = HouseAPIError(message: text)
                }
                outcomes.append(HouseBatchWriteOutcome(roomKey: key, house: nil, error: err))
            }
        }
        return outcomes
    }

    /// 硬删房源（服务器库物理移除，不进回收站）；成功只校验状态码，不再解码房源体
    func delete(_ roomKey: String) async throws {
        let body: [String: Any] = ["operator": operatorName,
                                   "originDeviceId": originDeviceId]
        let path = "/api/house/houses/\(encodedRoomKey(roomKey))"
        let (_, http) = try await makeRequest(path, method: "DELETE", body: body)
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "删除失败（服务器 \(http.statusCode)）")
        }
    }

    func restore(_ roomKey: String) async throws -> RemoteHouse {
        let body: [String: Any] = ["operator": operatorName,
                                   "originDeviceId": originDeviceId]
        let path = "/api/house/houses/\(encodedRoomKey(roomKey))/restore"
        let (data, http) = try await makeRequest(path, method: "POST", body: body)
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "恢复失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteHouse.self, data: data)
    }

    /// 扫描服务器 houses/ 下未被 media_refs 引用的孤儿媒体（设置页清理用）
    func listOrphanMedia(minAge: Int = 3600) async throws -> RemoteOrphanList {
        let (data, http) = try await makeRequest(
            "/api/house/media-orphans?minAge=\(max(0, minAge))", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "扫描服务器孤儿媒体失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteOrphanList.self, data: data)
    }

    /// 删除确认后的服务器孤儿媒体；服务器会二次核对 media_refs，已引用的跳过
    func deleteOrphanMedia(objectKeys: [String], minAge: Int = 3600) async throws -> RemoteOrphanDeleteResult {
        let body: [String: Any] = ["objectKeys": objectKeys, "minAge": max(0, minAge)]
        let (data, http) = try await makeRequest("/api/house/media-orphans", method: "DELETE", body: body)
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "清理服务器孤儿媒体失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteOrphanDeleteResult.self, data: data)
    }

    /// 公开分享 H5 链接（服务器本地托管静态壳；roomKey 为空时为公开选房列表）。
    /// 姓名/电话只在本机，随链接参数传给页面，服务器不落库；二维码不上服务器、H5 不展示。
    static func h5URL(roomKey: String? = nil) -> URL? {
        guard var comps = URLComponents(string: NotifyHub.shared.endpoint) else { return nil }
        comps.path = "/api/public/h5"
        var items: [URLQueryItem] = []
        if let key = roomKey, !key.isEmpty {
            items.append(URLQueryItem(name: "roomKey", value: key))
        }
        let profile = CosUploader.loadShareProfile()
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = profile.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { items.append(URLQueryItem(name: "n", value: name)) }
        if !phone.isEmpty { items.append(URLQueryItem(name: "p", value: phone)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }
}

/// POST /houses 单条返回（服务器对单条也包成 results）
private struct HouseWriteResult: Codable {
    let ok: Bool?
    let results: [WriteItem]?
}
private struct WriteItem: Codable {
    let ok: Bool?
    let error: String?
    let detail: String?
    let house: RemoteHouse?
    let conflicts: [[String: String]]?
}

private struct RemoteMediaUpload: Codable {
    let ok: Bool
    let objectKey: String?
    let fileName: String?
}

// MARK: - 上送载荷（本地 House 转换）

struct HouseSyncPayload {
    let roomKey: String
    let roomNo: String
    let tower: Int
    let landlord: String
    let layout: String
    let price: Int
    let password: String
    let remark: String
    let status: String
    let media: [[String: Any]]
    /// 编辑前的服务器快照字段；新增/无快照时为 nil（服务器走全量 CAS）
    var base: [String: Any]? = nil
    /// 编辑前的服务器媒体 objectKey 清单；与 base 一起用于「媒体并集 − 显式删除」
    var baseMedia: [String]? = nil
    /// 本次显式删除的服务器媒体 objectKey（本地已移除的旧媒体）
    var removedMedia: [String]? = nil

    var json: [String: Any] {
        var d: [String: Any] = ["roomKey": roomKey, "roomNo": roomNo, "tower": tower,
                                "landlord": landlord, "layout": layout, "price": price,
                                "password": password, "remark": remark, "status": status,
                                "media": media]
        if let base { d["base"] = base }
        if let baseMedia { d["baseMedia"] = baseMedia }
        if let removedMedia, !removedMedia.isEmpty { d["removedMedia"] = removedMedia }
        return d
    }
}
