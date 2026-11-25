//
//  HouseRemoteClient.swift
//  公寓管家 · 房源板块服务器权威 API 客户端
//
//  服务器（8082 内 house-keeper 模块）为唯一权威；本类只负责小 JSON 收发，
//  媒体实体仍在 COS（见 HouseMediaUploader / 临时凭证）。
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

struct RemoteCosCredentialEnvelope: Codable {
    let ok: Bool
    let credentials: RemoteCosCredentials
    let bucket: String
    let region: String
    let prefix: String?
}

struct RemoteCosCredentials: Codable {
    let secretId: String
    let secretKey: String
    let token: String
    let expiredTime: TimeInterval
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

    func getHouse(_ roomKey: String) async throws -> RemoteHouse {
        let path = "/api/house/houses/\(encodedRoomKey(roomKey))"
        let (data, http) = try await makeRequest(path, method: "GET")
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

    /// 旧 COS 临时凭证（休眠链路：后端已下线该路由，保留签名仅为兼容旧批量导入编译，主链不再调用）
    func fetchCosCredentials() async throws -> RemoteCosCredentialEnvelope {
        let (data, http) = try await makeRequest("/api/house/cos-credentials", method: "GET")
        guard http.statusCode == 200 else {
            throw HouseAPIError(message: "临时凭证不可用（服务器 \(http.statusCode)）")
        }
        return try decode(RemoteCosCredentialEnvelope.self, data: data)
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
        let (respData, http) = try await URLSession.shared.data(for: req)
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
        let (data, http) = try await URLSession.shared.data(for: req)
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
