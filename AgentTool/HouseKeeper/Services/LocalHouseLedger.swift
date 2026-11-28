import Foundation
import SwiftData

/// 本地房源账本（media/<房号>/info.json）：离线重建、单套覆盖写。
/// 服务器是权威源，这里只承担本机镜像与断电/断网时的重建。
enum LocalHouseLedger {
    /// 生成本地账本记录（服务器记录结构与本地补建共用同一字段口径）。
    static func record(from house: House) -> CloudHouseRecord {
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
            updatedBy: CloudUser.signedUsername,
            mediaNames: house.mediaItems.map { $0.fileName },
            revision: nil
        )
    }

    /// 写本套账本（幂等覆盖）
    static func save(_ house: House) {
        let record = Self.record(from: house)
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
