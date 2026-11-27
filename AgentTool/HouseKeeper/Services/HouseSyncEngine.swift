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
    /// 本轮拉取时，服务器有、但被用户“仅删本地”隐藏的房源数量。
    /// 手动刷新用它做恢复确认；自动对账只跳过，不弹窗、不自动带回。
    @Published private(set) var hiddenCloudCount = 0

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

    /// 本地 MediaItem -> 服务器磁盘相对引用。
    /// 视频本地名可能是 .mov，但服务器统一落 .mp4，避免安卓/微信不识别 QuickTime 容器。
    static func objectKey(roomKey: String, fileName: String, kind: String) -> String {
        "houses/\(roomKey)/\(MediaNaming.remoteName(fileName: fileName, kind: kind))"
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
        // 不能因为服务器为空就提前 return：后台硬删最后一套房后，本地 revMap 里仍有
        // 该房记录，必须走一次空清单对账，才能把本地孤儿/“双端”徽章清掉。
        let changed = try applyRemote(list.houses, context: context)
        // 记录对账完成后，把本地磁盘缺失的媒体从服务器回补落盘（已存在自动跳过）
        await backfillMissingMedia(context: context)
        return changed
    }

    /// 遍历在册房源，回补本地磁盘缺失但服务器有的媒体文件；单个失败跳过，不阻断同步。
    private func backfillMissingMedia(context: ModelContext) async {
        let houses = (try? context.fetch(FetchDescriptor<House>())) ?? []
        for h in houses where !h.isTrashed {
            let records = h.mediaItems.map { ($0.fileName, $0.kind) }
            guard !records.isEmpty else { continue }
            _ = await HouseRemoteClient.shared.downloadMissingMedia(roomKey: h.mediaRoomKey, records: records)
        }
    }

    private func applyRemote(_ remoteHouses: [RemoteHouse], context: ModelContext) throws -> Int {
        let allHouses = try context.fetch(FetchDescriptor<House>())
        var byKey: [String: House] = [:]
        for h in allHouses {
            byKey[h.mediaRoomKey] = h
        }
        var changed = 0
        hiddenCloudCount = 0
        // 本机有还没推上去的改动：服务器清单不能直接盖回来，否则弱网/冲突时
        // 用户刚改的租金、状态、媒体会被下一次自动对账静默回滚。
        let pendingKeys = HousePendingRegistry.keys()
        for r in remoteHouses {
            // 用户明确选择「仅删本地」：服务器仍有这套房，但本机不再自动带回。
            // 手动刷新时由列表页弹窗询问是否恢复；自动对账只跳过。
            if HouseLocalDeletionStore.contains(r.roomKey) {
                hiddenCloudCount += 1
                if let local = byKey[r.roomKey] {
                    context.delete(local)
                    changed += 1
                }
                continue
            }
            if pendingKeys.contains(r.roomKey) {
                continue
            }
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
            // 只要服务器权威库返回这套房，徽章就应是“双端”；不能沿用本地旧值。
            target.cloudStatus = .both
            target.deletedAt = r.trashed ? Date() : nil
            if let updated = r.updatedAt {
                target.lastUpdatedAt = ISO8601DateFormatter().date(from: updated) ?? Date()
            }
            reconcileMedia(target, remote: r, context: context)
            if snapshot(target) != before { changed += 1 }
            setServerRevision(r.revision, forKey: r.roomKey)
        }
        // 服务器已硬删的本地孤儿：曾同步过（revMap 有记录）但全量清单已不含 → 物理删除本地记录；
        // 从未同步过的纯本地房保留，并明确标为“本地”，避免沿用旧的“双端”。
        let remoteKeys = Set(remoteHouses.map { $0.roomKey })
        // 服务器已经不存在这套房（被其他设备双端删除）时，清掉本地“隐藏”墓碑；
        // 否则以后服务器重新收录同房号，会被旧墓碑永久挡住。
        for key in HouseLocalDeletionStore.keys() where !remoteKeys.contains(key) {
            HouseLocalDeletionStore.remove(key)
        }
        for (key, h) in byKey where !remoteKeys.contains(key) {
            // 本机待补传房：即使服务器已没有它，也先保留本地，
            // 等补传时服务器给出 revision_conflict，用户再明确处理；不在这里静默删。
            if pendingKeys.contains(key) { continue }
            if revMap[key] != nil {
                context.delete(h)
                removeServerRevision(forKey: key)
                changed += 1
            } else if h.cloudStatus != .local {
                h.cloudStatus = .local
                changed += 1
            }
        }
        try context.save()
        return changed
    }

    private func reconcileMedia(_ house: House, remote: RemoteHouse, context: ModelContext) {
        let remoteMedia = remote.media ?? []
        let wantedNames = Set(remoteMedia.map {
            Self.localFileName(objectKey: $0.objectKey, kind: $0.kind)
        })
        // 本地已登记、但还没传成功的媒体不能因为服务器清单暂时没有就删掉：
        // 它们还在待上传队列里，删了本地记录会让后补传的图片/视频“人间蒸发”。
        let pendingNames = Set(HouseMediaUploadQueue.pendingItems()
            .filter { $0.roomKey == house.mediaRoomKey }
            .map { $0.fileName })
        // 删除本地不再引用的媒体记录
        for old in house.mediaItems where !wantedNames.contains(old.fileName)
            && !pendingNames.contains(old.fileName) {
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

    /// 推送单套房的新增/编辑。
    /// - Parameter mediaFileNames: 本次允许写进服务器 media_refs 的本地文件名集合；
    ///   传 nil 表示全部。上传失败的媒体不应写进服务器，否则会在服务器留下 404 幽灵引用。
    @discardableResult
    func pushHouse(_ house: House, mediaFileNames: Set<String>? = nil) async throws -> RemoteHouse {
        let roomKey = house.mediaRoomKey
        // 任何入口 pushHouse 都自动排除仍在待上传队列里的媒体：
        // 状态切换、批量导入等路径不会把“本地有、服务器还没有”的文件写进 media_refs。
        let pendingNames = Set(HouseMediaUploadQueue.pendingItems()
            .filter { $0.roomKey == roomKey }
            .map { $0.fileName })
        let effectiveNames: Set<String>? = {
            if let mediaFileNames { return mediaFileNames.subtracting(pendingNames) }
            guard !pendingNames.isEmpty else { return nil }
            return Set(house.mediaItems.map { $0.fileName }).subtracting(pendingNames)
        }()
        let payload = HouseSyncPayload(
            roomKey: roomKey, roomNo: house.roomNo, tower: house.tower,
            landlord: house.landlord, layout: house.layout, price: house.price,
            password: house.password, remark: house.remark,
            status: house.statusRaw, media: mediaArray(house, roomKey: roomKey,
                                                       onlyNames: effectiveNames))
        let expected = revMap[roomKey]
        let remote: RemoteHouse
        do {
            remote = try await HouseRemoteClient.shared.upsert(
                payload, expectedRevision: expected)
        } catch let error as HouseAPIError where error.revisionConflict {
            // 冲突后不能一直拿旧 revision 重试（会永久卡在待补传）。
            // 先拉一次服务器当前 revision，更新本地基线；本次仍抛给调用方提示/保留本机改动，
            // 下一轮补传按“最后写入者胜”提交本机版本，避免死循环。
            if let fresh = try? await HouseRemoteClient.shared.getHouse(roomKey) {
                setServerRevision(fresh.revision, forKey: roomKey)
                setTop(max(topRevision, fresh.revision))
                CloudOps.log(category: "房源", action: "同步冲突", result: "冲突",
                             detail: "服务器已更新到修订 \(fresh.revision)；本机改动保留，下一轮补传按本机版本覆盖",
                             room: roomKey)
            } else {
                CloudOps.log(category: "房源", action: "同步冲突", result: "冲突",
                             detail: "服务器已无此房源（可能被其他设备删除）；本机改动保留，等待人工处理",
                             room: roomKey)
            }
            throw error
        }
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

    private func mediaArray(_ house: House, roomKey: String,
                            onlyNames: Set<String>? = nil) -> [[String: Any]] {
        house.mediaItems.compactMap { item in
            if let onlyNames, !onlyNames.contains(item.fileName) { return nil }
            let remoteName = MediaNaming.remoteName(fileName: item.fileName, kind: item.kind)
            let key = Self.objectKey(roomKey: roomKey, fileName: item.fileName,
                                    kind: item.kind)
            return ["objectKey": key, "fileName": remoteName,
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
        await HouseLedgerStore.flushPendingAll()
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

/// “仅删本地”墓碑：记录用户明确从本机删除、但服务器仍保留的房源。
/// 作用：自动同步/手动同步不再把它们静默带回；只有用户在总刷新确认框里点“恢复”才清除。
enum HouseLocalDeletionStore {
    private static let key = "house.localDeletion.roomKeys.v1"

    static func keys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func count() -> Int { keys().count }

    static func contains(_ roomKey: String) -> Bool {
        keys().contains(roomKey)
    }

    static func mark(_ roomKey: String) {
        guard !roomKey.isEmpty else { return }
        var set = keys()
        set.insert(roomKey)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func remove(_ roomKey: String) {
        var set = keys()
        set.remove(roomKey)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
