//
//  HouseSyncEngine.swift
//  公寓管家 · 房源板块服务器权威同步引擎
//
//  职责：把本地 SwiftData House（缓存/UI 数据源）与服务器权威库双向同步。
//  本地保存与本地通知文案保持不变（修改人本机沿用现有文案）；本引擎把变更推到服务器，
//  服务器产生 outbox 并广播到其他接入设备，再由本引擎拉取他人变更应用到本地。
//  媒体实体在 COS，这里只同步媒体引用（objectKey），媒体文件下载走现有媒体流程。
//

import Foundation
import SwiftData

@MainActor
final class HouseSyncEngine: ObservableObject {
    static let shared = HouseSyncEngine()

    @Published var busy = false
    @Published var statusText: String?

    private let topKey = "house.sync.topRevision.v1"
    private let revMapKey = "house.sync.revMap.v1"
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - 版本号管理

    private var topRevision: Int {
        defaults.integer(forKey: topKey)
    }
    private func setTop(_ v: Int) {
        defaults.set(v, forKey: topKey)
    }
    private var revMap: [String: Int] {
        (defaults.dictionary(forKey: revMapKey) as? [String: Int]) ?? [:]
    }
    private func setServerRevision(_ rev: Int, forKey key: String) {
        var m = revMap
        m[key] = rev
        defaults.set(m, forKey: revMapKey)
    }
    private func removeServerRevision(forKey key: String) {
        var m = revMap
        m.removeValue(forKey: key)
        defaults.set(m, forKey: revMapKey)
    }

    // MARK: - 媒体名映射

    /// 本地 MediaItem -> 服务器磁盘相对引用
    static func objectKey(roomKey: String, fileName: String, kind: String) -> String {
        "houses/\(roomKey)/\(fileName)"
    }

    /// 服务器媒体 objectKey -> 本地 MediaItem.fileName
    static func localFileName(objectKey: String, kind: String) -> String {
        let name = (objectKey as NSString).lastPathComponent
        if kind == "video" {
            return ((name as NSString).deletingPathExtension) + ".mov"
        }
        return name
    }

    // MARK: - 拉取（服务器 → 本地）

    /// 拉取服务器全量清单并对账应用；返回实际变化的房源数
    @discardableResult
    func pull(context: ModelContext) async throws -> Int {
        // 全量清单：便于识别「曾同步过、但服务器已硬删」的本地孤儿房并一并清除；
        // 纯本地离线未提交的房（revMap 无记录）不会被误删。
        let list = try await HouseRemoteClient.shared.listHouses(since: nil)
        setTop(list.topRevision)
        if list.houses.isEmpty { return 0 }
        let changed = try applyRemote(list.houses, context: context)
        return changed
    }

    private func applyRemote(_ remoteHouses: [RemoteHouse], context: ModelContext) throws -> Int {
        let allHouses = try context.fetch(FetchDescriptor<House>())
        var byKey: [String: House] = [:]
        for h in allHouses {
            byKey[h.mediaRoomKey] = h
        }
        var changed = 0
        for r in remoteHouses {
            let target = byKey[r.roomKey] ?? House()
            if byKey[r.roomKey] == nil {
                context.insert(target)
            }
            let before = snapshot(target)
            // 房号：去掉座号前缀存纯房号，座号由 tower 决定
            target.roomNo = pureRoomNo(r.roomNo, tower: r.tower)
            target.tower = r.tower
            target.landlord = r.landlord
            target.layout = r.layout
            target.price = r.price
            target.password = r.password
            target.remark = r.remark
            target.statusRaw = r.status
            target.isDeleted = r.trashed
            target.deletedAt = r.trashed ? Date() : nil
            if let updated = r.updatedAt {
                target.lastUpdatedAt = ISO8601DateFormatter().date(from: updated) ?? Date()
            }
            reconcileMedia(target, remote: r, context: context)
            if snapshot(target) != before { changed += 1 }
            setServerRevision(r.revision, forKey: r.roomKey)
        }
        // 服务器已硬删的本地孤儿：曾同步过（revMap 有记录）但全量清单已不含 → 物理删除本地记录
        let remoteKeys = Set(remoteHouses.map { $0.roomKey })
        for (key, h) in byKey where !remoteKeys.contains(key) && revMap[key] != nil {
            context.delete(h)
            removeServerRevision(forKey: key)
            changed += 1
        }
        try context.save()
        return changed
    }

    private func reconcileMedia(_ house: House, remote: RemoteHouse, context: ModelContext) {
        let remoteMedia = remote.media ?? []
        let wantedNames = Set(remoteMedia.map {
            Self.localFileName(objectKey: $0.objectKey, kind: $0.kind)
        })
        // 删除本地不再引用的媒体记录
        for old in house.mediaItems where !wantedNames.contains(old.fileName) {
            context.delete(old)
        }
        let existing = Set(house.mediaItems.map { $0.fileName })
        for m in remoteMedia {
            let localName = Self.localFileName(objectKey: m.objectKey, kind: m.kind)
            guard !existing.contains(localName) else { continue }
            let item = MediaItem(fileName: localName, kind: m.kind)
            item.house = house
            context.insert(item)
        }
    }

    // MARK: - 推送（本地 → 服务器）

    /// 推送单套房的新增/编辑
    @discardableResult
    func pushHouse(_ house: House) async throws -> RemoteHouse {
        let roomKey = house.mediaRoomKey
        let payload = HouseSyncPayload(
            roomKey: roomKey, roomNo: house.roomNo, tower: house.tower,
            landlord: house.landlord, layout: house.layout, price: house.price,
            password: house.password, remark: house.remark,
            status: house.statusRaw, media: mediaArray(house, roomKey: roomKey))
        let expected = revMap[roomKey]
        let remote = try await HouseRemoteClient.shared.upsert(
            payload, expectedRevision: expected)
        setServerRevision(remote.revision, forKey: roomKey)
        setTop(max(topRevision, remote.revision))
        return remote
    }

    /// 硬删：通知服务器物理移除（不进回收站）；本地记录由调用方在成功后 ctx.delete 清除
    func pushDelete(_ house: House) async throws {
        let roomKey = house.mediaRoomKey
        try await HouseRemoteClient.shared.delete(roomKey)
    }

    func pushRestore(_ house: House) async throws {
        let roomKey = house.mediaRoomKey
        let remote = try await HouseRemoteClient.shared.restore(roomKey)
        house.isDeleted = false
        house.deletedAt = nil
        setServerRevision(remote.revision, forKey: roomKey)
        setTop(max(topRevision, remote.revision))
    }

    private func mediaArray(_ house: House, roomKey: String) -> [[String: Any]] {
        house.mediaItems.map { item in
            let key = Self.objectKey(roomKey: roomKey, fileName: item.fileName,
                                    kind: item.kind)
            return ["objectKey": key, "fileName": item.fileName,
                    "kind": item.kind]
        }
    }

    // MARK: - 全量同步（先推后拉）

    func syncAll(context: ModelContext) async throws {
        busy = true
        defer { busy = false }
        // 本地未提交（无服务器 revision）的房源先推
        let houses = try context.fetch(FetchDescriptor<House>())
        for h in houses where !h.isTrashed && revMap[h.mediaRoomKey] == nil {
            try await pushHouse(h)
        }
        _ = try await pull(context: context)
        statusText = "同步完成 · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
    }

    // MARK: - 工具

    private func pureRoomNo(_ roomNo: String, tower: Int) -> String {
        var s = roomNo
        for p in ["1-", "2-", "1－", "2－"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        return s
    }

    private func snapshot(_ h: House) -> [String: String] {
        ["roomNo": h.roomNo, "tower": String(h.tower), "landlord": h.landlord,
         "layout": h.layout, "price": String(h.price), "password": h.password,
         "remark": h.remark, "status": h.statusRaw, "deleted": String(h.isTrashed),
         "media": h.mediaItems.map { $0.fileName }.sorted().joined(separator: "|")]
    }
}
