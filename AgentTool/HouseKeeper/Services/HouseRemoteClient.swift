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

struct RemoteHouseStats: Codable {
    let ok: Bool
    let total: Int
    let tower1: Int
    let tower2: Int
    let pendingOutbox: Int
}

struct HouseAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
            throw HouseAPIError(message: "服务器地址无效，请到「电表监控设置」检查服务器地址")
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

    func stats() async throws -> RemoteHouseStats {
        let (data, http) = try await makeRequest("/api/house/stats", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "读取统计失败（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteHouseStats.self, data: data)
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
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(fileName, forHTTPHeaderField: "X-File-Name")
        req.setValue(kind, forHTTPHeaderField: "X-Kind")
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = data
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw HouseAPIError(message: "媒体上传失败（服务器响应无效）")
        }
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "媒体上传失败（服务器 \(http.statusCode)）")
        }
        let envelope = try decode(RemoteMediaUpload.self, data: respData)
        guard envelope.ok, let objectKey = envelope.objectKey else {
            throw HouseAPIError(message: "服务器未返回媒体引用")
        }
        return (objectKey, envelope.fileName ?? fileName)
    }

    /// 从服务器下载媒体二进制
    func downloadMedia(roomKey: String, fileName: String) async throws -> Data {
        let path = "/api/house/media/\(encodedRoomKey(roomKey))/\(encodedRoomKey(fileName))"
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
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "媒体下载失败（服务器 \(http.statusCode)）")
        }
        return data
    }

    /// 删除服务器上的单个媒体文件
    func deleteMedia(roomKey: String, fileName: String) async throws {
        let path = "/api/house/media/\(encodedRoomKey(roomKey))/\(encodedRoomKey(fileName))"
        let (_, http) = try await makeRequest(path, method: "DELETE")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "媒体删除失败（服务器 \(http.statusCode)）")
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
    func upsert(_ payload: HouseSyncPayload, expectedRevision: Int?) async throws -> RemoteHouse {
        var body: [String: Any] = payload.json
        body["operator"] = operatorName
        body["originDeviceId"] = originDeviceId
        if let expectedRevision { body["expectedRevision"] = expectedRevision }
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
                throw HouseAPIError(message: "该房源刚被其他人修改，请刷新后再编辑")
            }
            throw HouseAPIError(message: r.detail ?? "保存失败")
        }
        guard let house = r.house else {
            throw HouseAPIError(message: "服务器未回写房源数据")
        }
        return house
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

    /// 公开分享 H5 链接（服务器本地托管静态壳；roomKey 为空时为公开选房列表）
    static func h5URL(roomKey: String? = nil) -> URL? {
        guard var comps = URLComponents(string: NotifyHub.shared.endpoint) else { return nil }
        comps.path = "/api/public/h5"
        if let key = roomKey, !key.isEmpty {
            comps.queryItems = [URLQueryItem(name: "roomKey", value: key)]
        } else {
            comps.queryItems = nil
        }
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

    var json: [String: Any] {
        ["roomKey": roomKey, "roomNo": roomNo, "tower": tower,
         "landlord": landlord, "layout": layout, "price": price,
         "password": password, "remark": remark, "status": status,
         "media": media]
    }
}
