//
//  HouseSyncBaseStore.swift
//  公寓管家 · 房源服务器化改造（2026-11-27）
//
//  解决两个跨端问题：
//  1) 字段级合并需要「编辑前的服务器快照」。拉取/推送成功时把 RemoteHouse 存成本地
//     base；编辑提交时带 base，服务器才能分辨「客户端没改」与「两边都改」。
//  2) 媒体本地原名与服务器落盘名可能不同（视频 .mov → .mp4、同名唯一化追加随机后缀）。
//     这里维护 objectKey ↔ 本地文件名映射，账本/播放用本地名，media_refs 用服务器名。
//

import Foundation

// MARK: - 房源 base 快照

struct HouseBaseSnapshot: Codable {
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var status: String
    var mediaKeys: [String]
    var revision: Int

    #if !APP_EXTENSION
    init(remote: RemoteHouse) {
        roomNo = remote.roomNo
        tower = remote.tower
        landlord = remote.landlord
        layout = remote.layout
        price = remote.price
        password = remote.password
        remark = remote.remark
        status = remote.status
        mediaKeys = (remote.media ?? []).map { $0.objectKey }
        revision = remote.revision
    }
    #endif

    var fields: [String: Any] {
        ["roomNo": roomNo, "tower": tower, "landlord": landlord,
         "layout": layout, "price": price, "password": password,
         "remark": remark, "status": status]
    }
}

enum HouseBaseSnapshotStore {
    private static var userKey: String { CloudUser.safeName }

    private static func key(_ roomKey: String) -> String {
        "house.baseSnapshot.v1.\(userKey).\(roomKey)"
    }

    #if !APP_EXTENSION
    static func save(_ remote: RemoteHouse) {
        guard !remote.roomKey.isEmpty,
              let data = try? JSONEncoder().encode(HouseBaseSnapshot(remote: remote))
        else { return }
        SharedBridge.defaults.set(data, forKey: key(remote.roomKey))
    }
    #endif

    static func load(_ roomKey: String) -> HouseBaseSnapshot? {
        guard let data = SharedBridge.defaults.data(forKey: key(roomKey)),
              let snap = try? JSONDecoder().decode(HouseBaseSnapshot.self, from: data)
        else { return nil }
        return snap
    }

    static func remove(_ roomKey: String) {
        SharedBridge.defaults.removeObject(forKey: key(roomKey))
    }
}

// MARK: - 服务器媒体名 ↔ 本地文件名映射

/// key: `<roomKey>|<objectKey>` → localFileName。放 App Group，主 App 与分享扩展共用，
/// 扩展上传拿到服务器唯一化文件名后立即写，主 App 收养本地文件时可直接对上。
enum HouseMediaNameMap {
    private static var defaults: UserDefaults { SharedBridge.defaults }
    private static func key(roomKey: String, objectKey: String) -> String {
        "house.mediaMap.v1.\(roomKey)|\(objectKey)"
    }
    private static func roomPrefix(roomKey: String) -> String {
        "house.mediaMap.v1.\(roomKey)|"
    }

    static func set(roomKey: String, objectKey: String, localFileName: String) {
        guard !roomKey.isEmpty, !objectKey.isEmpty, !localFileName.isEmpty else { return }
        defaults.set(localFileName, forKey: key(roomKey: roomKey, objectKey: objectKey))
    }

    static func localName(roomKey: String, objectKey: String) -> String? {
        defaults.string(forKey: key(roomKey: roomKey, objectKey: objectKey))
    }

    /// 由本地文件名反查服务器 objectKey；没有映射时返回 nil，调用方按命名规则计算。
    static func objectKey(roomKey: String, localFileName: String) -> String? {
        let prefix = roomPrefix(roomKey: roomKey)
        for (k, v) in defaults.dictionaryRepresentation()
        where k.hasPrefix(prefix) && (v as? String) == localFileName {
            return String(k.dropFirst(prefix.count))
        }
        return nil
    }

    static func remove(roomKey: String, objectKey: String) {
        defaults.removeObject(forKey: key(roomKey: roomKey, objectKey: objectKey))
    }

    static func removeRoom(_ roomKey: String) {
        let prefix = roomPrefix(roomKey: roomKey)
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            defaults.removeObject(forKey: k)
        }
    }
}
