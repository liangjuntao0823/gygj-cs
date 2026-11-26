//
//  ExtensionHouseClient.swift
//  公寓管家 · 分享扩展进程的轻量房源服务器客户端
//
//  扩展 target 不编入 HouseRemoteClient / MeterStore / NotifyHub / MeterCloudSync，
//  端点与房源/通知令牌经 SharedBridge 镜像从 App Group 读取，操作署名取 CloudUser.signedUsername。
//  能力对齐主 App HouseRemoteClient 中扩展编排所需的子集：查重 GET、媒体上传/删除、房源 upsert。
//

import Foundation

/// 扩展侧服务器错误（对齐 HouseAPIError 语义：403 无权不重试；conflict 为修订号冲突）
struct ExtHouseError: LocalizedError {
    let message: String
    let forbidden: Bool
    let conflict: Bool

    init(message: String, forbidden: Bool = false, conflict: Bool = false) {
        self.message = message
        self.forbidden = forbidden
        self.conflict = conflict
    }

    var errorDescription: String? { message }
}

/// 服务器房源 DTO（精简自 RemoteHouse；扩展 target 不编入 HouseRemoteClient.swift）
private struct ExtRemoteHouse: Codable {
    let roomKey: String
    let roomNo: String
    let tower: Int
    let landlord: String
    let layout: String
    let price: Int
    let password: String
    let remark: String
    let status: String
    let revision: Int?
    let updatedAt: String?
    let updatedBy: String?
    let media: [ExtRemoteMedia]?
}

private struct ExtRemoteMedia: Codable {
    let objectKey: String?
    let fileName: String
    let kind: String?
}

private struct ExtWriteResult: Codable {
    let ok: Bool?
    let results: [ExtWriteItem]?
}

private struct ExtWriteItem: Codable {
    let ok: Bool?
    let error: String?
    let detail: String?
    let house: ExtRemoteHouse?
}

private struct ExtMediaUpload: Codable {
    let ok: Bool
    let objectKey: String?
    let fileName: String?
}

enum ExtensionHouseClient {

    private static var endpoint: String { SharedBridge.mirroredEndpoint }
    private static var token: String? { SharedBridge.mirroredHouseToken }
    private static var operatorName: String { CloudUser.signedUsername }

    private static var originDeviceId: String {
        let key = "house.originDeviceId.v1"
        if let s = SharedBridge.defaults.string(forKey: key), !s.isEmpty { return s }
        let s = "dev_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
        SharedBridge.defaults.set(s, forKey: key)
        return s
    }

    private static var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }

    private static func encoded(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
    }

    static func kind(ofName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return (ext == "mp4" || ext == "mov" || ext == "m4v") ? "video" : "image"
    }

    private static func objectKey(roomKey: String, fileName: String) -> String {
        "houses/\(roomKey)/\(fileName)"
    }

    private static func request(_ path: String, method: String,
                                body: [String: Any]? = nil) throws -> URLRequest {
        guard let base = URL(string: endpoint),
              let url = URL(string: path, relativeTo: base) else {
            throw ExtHouseError(message: "服务器地址无效，请到电表监控设置检查服务器地址")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// 单房查重：404 → nil（新房）；其余非 200 抛错
    static func fetchOne(roomKey: String) async throws -> CloudHouseRecord? {
        let req = try request("/api/house/houses/\(encoded(roomKey))", method: "GET")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ExtHouseError(message: "服务器无响应")
        }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 403 {
            throw ExtHouseError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw ExtHouseError(message: "读取房源失败（服务器 \(http.statusCode)）")
        }
        let doc = try JSONDecoder().decode(ExtRemoteHouse.self, from: data)
        return makeRecord(from: doc)
    }

    /// 上传单个媒体二进制；返回服务器落盘文件名
    @discardableResult
    static func uploadMedia(roomKey: String, fileName: String, kind: String,
                            data: Data) async throws -> String {
        guard let base = URL(string: endpoint),
              let url = URL(string: "/api/house/media/\(encoded(roomKey))", relativeTo: base) else {
            throw ExtHouseError(message: "服务器地址无效")
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
            throw ExtHouseError(message: "媒体上传失败（服务器响应无效）")
        }
        if http.statusCode == 403 {
            throw ExtHouseError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw ExtHouseError(message: "媒体上传失败（服务器 \(http.statusCode)）")
        }
        let envelope = try JSONDecoder().decode(ExtMediaUpload.self, from: respData)
        guard envelope.ok else { throw ExtHouseError(message: "服务器未返回媒体引用") }
        return envelope.fileName ?? fileName
    }

    static func deleteMedia(roomKey: String, fileName: String) async throws {
        let req = try request("/api/house/media/\(encoded(roomKey))/\(encoded(fileName))", method: "DELETE")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ExtHouseError(message: "媒体删除失败（服务器响应无效）")
        }
        if http.statusCode == 403 {
            throw ExtHouseError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw ExtHouseError(message: "媒体删除失败（服务器 \(http.statusCode)）")
        }
    }

    /// 下载服务器单个媒体二进制（扩展内预览用；落本地临时目录后再加载）
    static func downloadMedia(roomKey: String, fileName: String) async throws -> Data {
        let req = try request("/api/house/media/\(encoded(roomKey))/\(encoded(fileName))", method: "GET")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ExtHouseError(message: "媒体下载失败（服务器响应无效）")
        }
        if http.statusCode == 403 {
            throw ExtHouseError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        guard http.statusCode == 200 else {
            throw ExtHouseError(message: "媒体下载失败（服务器 \(http.statusCode)）")
        }
        return data
    }

    /// 新增/编辑；expectedRevision 为编辑前修订号（乐观锁），新增传 nil；返回服务器回写的权威记录
    static func upsert(_ record: CloudHouseRecord, expectedRevision: Int?) async throws -> CloudHouseRecord {
        let media: [[String: Any]] = record.mediaNames.map { name in
            ["objectKey": objectKey(roomKey: record.roomKey, fileName: name),
             "fileName": name, "kind": kind(ofName: name)]
        }
        var body: [String: Any] = [
            "roomKey": record.roomKey,
            "roomNo": record.roomNo,
            "tower": record.tower,
            "landlord": record.landlord,
            "layout": record.layout,
            "price": record.price,
            "password": record.password,
            "remark": record.remark,
            "status": record.status,
            "media": media,
            "operator": operatorName,
            "originDeviceId": originDeviceId
        ]
        if let expectedRevision { body["expectedRevision"] = expectedRevision }
        let req = try request("/api/house/houses", method: "POST", body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ExtHouseError(message: "服务器无响应")
        }
        if http.statusCode == 401 {
            throw ExtHouseError(message: "登录已失效，请重新接入服务器")
        }
        if http.statusCode == 403 {
            throw ExtHouseError(message: "暂无房源访问权限，请联系管理员开通", forbidden: true)
        }
        let result = try JSONDecoder().decode(ExtWriteResult.self, from: data)
        guard let item = result.results?.first else {
            throw ExtHouseError(message: "服务器返回格式异常")
        }
        if item.ok == false {
            if item.error == "revision_conflict" {
                throw ExtHouseError(message: "该房源刚被其他人修改，请刷新后再编辑", conflict: true)
            }
            throw ExtHouseError(message: item.detail ?? "保存失败")
        }
        guard let house = item.house else {
            throw ExtHouseError(message: "服务器未回写房源数据")
        }
        return makeRecord(from: house)
    }

    // MARK: - 服务器 doc ↔ 本地 CloudHouseRecord 映射

    private static func makeRecord(from doc: ExtRemoteHouse) -> CloudHouseRecord {
        CloudHouseRecord(
            roomKey: doc.roomKey,
            roomNo: doc.roomNo,
            tower: doc.tower,
            landlord: doc.landlord,
            layout: doc.layout,
            price: doc.price,
            password: doc.password,
            remark: doc.remark,
            status: doc.status,
            updatedAt: doc.updatedAt.flatMap { dateFormatter.date(from: $0) } ?? Date(),
            updatedBy: doc.updatedBy ?? "",
            mediaNames: doc.media?.map { $0.fileName } ?? [],
            revision: doc.revision.map { Int64($0) })
    }
}
