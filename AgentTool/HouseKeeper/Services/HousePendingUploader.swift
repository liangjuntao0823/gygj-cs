//
//  HousePendingUploader.swift
//  公寓管家 · 弱网离线写与联网自动补传
//
//  本地写操作先落 SwiftData（任何时候都不阻塞用户）；若推送到服务器失败，
//  把该房 roomKey 记入待补传集合，网络恢复 / 回前台 / 手动同步时自动按序补传，
//  成功一套清一套，保证弱网下不丢改动、不产生重复。
//

import Foundation
import SwiftData

/// 待补传登记簿（唯一底层集合）。
/// 旧 SyncFailStore「同步失败标记」与新 HousePendingUploader「待提交房号」共用同一份存储，
/// 避免两套登记簿漂移；写入/移除后发 didChange 通知，任务中心与卡片红点实时吸收。
struct HousePendingChange: Codable, Equatable {
    let roomKey: String
    /// 例如「修改备注」「修改租金」「新增房源」
    let action: String
    /// 例如「修改备注 空 改 测试」；任务中心和补传成功日志直接复用
    let detail: String
    let updatedAt: Date
}

enum HousePendingRegistry {
    static let pendingKey = "house.pending.roomKeys.v1"
    private static let changesKey = "house.pending.changes.v1"
    private static let legacyKey = "house_sync_failed_keys"
    static let didChange = Notification.Name("housePendingRegistryChanged")

    static func keys() -> Set<String> {
        migrateLegacyIfNeeded()
        var set = Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
        // 以 keys 为权威，同时兜底 changes 里残留的房号，避免两处漂移
        set.formUnion(changes().map { $0.roomKey })
        return set
    }

    /// 待同步的具体改动（按房号）；旧版只存房号时返回 nil，界面降级为「有改动待上传」
    static func change(for roomKey: String) -> HousePendingChange? {
        changes().first { $0.roomKey == roomKey }
    }

    static func allChanges() -> [HousePendingChange] {
        changes().sorted { $0.updatedAt > $1.updatedAt }
    }

    static func insert(_ roomKey: String, action: String = "", detail: String = "") {
        guard !roomKey.isEmpty else { return }
        var set = keys()
        set.insert(roomKey)
        UserDefaults.standard.set(Array(set), forKey: pendingKey)
        if !action.isEmpty || !detail.isEmpty {
            var map = changes()
            if let idx = map.firstIndex(where: { $0.roomKey == roomKey }) {
                let old = map[idx]
                // 同一房号多次离线改动合并成一条，任务中心能看到改了哪些字段
                let mergedAction = [old.action, action].filter { !$0.isEmpty }
                    .reduce(into: [String]()) { acc, x in if !acc.contains(x) { acc.append(x) } }
                    .joined(separator: "、")
                let mergedDetail = [old.detail, detail].filter { !$0.isEmpty }
                    .reduce(into: [String]()) { acc, x in if !acc.contains(x) { acc.append(x) } }
                    .joined(separator: "；")
                map[idx] = HousePendingChange(roomKey: roomKey,
                                              action: mergedAction.isEmpty ? old.action : mergedAction,
                                              detail: mergedDetail,
                                              updatedAt: Date())
            } else {
                map.append(HousePendingChange(roomKey: roomKey, action: action,
                                              detail: detail, updatedAt: Date()))
            }
            saveChanges(map)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func remove(_ roomKey: String) {
        var set = keys()
        guard set.contains(roomKey) else { return }
        set.remove(roomKey)
        UserDefaults.standard.set(Array(set), forKey: pendingKey)
        var map = changes()
        map.removeAll { $0.roomKey == roomKey }
        saveChanges(map)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func changes() -> [HousePendingChange] {
        guard let data = UserDefaults.standard.data(forKey: changesKey),
              let list = try? JSONDecoder().decode([HousePendingChange].self, from: data) else { return [] }
        return list
    }

    private static func saveChanges(_ list: [HousePendingChange]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: changesKey)
        }
    }

    /// 一次性把旧「账本未同步」标记键并入新键，随后旧键清空
    private static func migrateLegacyIfNeeded() {
        let legacy = Set(UserDefaults.standard.stringArray(forKey: legacyKey) ?? [])
        guard !legacy.isEmpty else { return }
        // 注意：这里不能调用 keys()（会再次进入本函数导致递归）；直接读权威键+changes 兜底。
        var set = Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
        set.formUnion(changes().map { $0.roomKey })
        set.formUnion(legacy)
        UserDefaults.standard.set(Array(set), forKey: pendingKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}

@MainActor
final class HousePendingUploader {
    static let shared = HousePendingUploader()

    private init() {}

    var pendingKeys: [String] {
        Array(HousePendingRegistry.keys()).sorted()
    }

    var hasPending: Bool { !pendingKeys.isEmpty }

    func markPending(_ roomKey: String, action: String = "", detail: String = "") {
        HousePendingRegistry.insert(roomKey, action: action, detail: detail)
    }

    func clearPending(_ roomKey: String) {
        HousePendingRegistry.remove(roomKey)
    }

    /// 详情面板用：某个待同步房号的具体改动说明。
    func pendingChange(for roomKey: String) -> HousePendingChange? {
        HousePendingRegistry.change(for: roomKey)
    }

    /// 补传成功：把原来一条「待同步」日志就地收口成一条「成功」日志，
    /// 不再额外追加通用成功记录，避免同一动作出现两条云端日志。
    func completePending(_ roomKey: String, remoteKey: String? = nil, note: String = "") {
        let change = HousePendingRegistry.change(for: roomKey)
        let logRoom = remoteKey ?? roomKey
        clearPending(roomKey)
        let action = change?.action.isEmpty == false ? change!.action : "房源同步"
        let detail: String
        if let change, !change.detail.isEmpty {
            detail = change.detail
        } else {
            detail = note.isEmpty ? "已上传到服务器" : note
        }
        BackupLogStore.resolvePending(room: logRoom, pendingRoom: roomKey,
                                      action: action, result: "成功",
                                      detail: detail, cloud: true)
    }

    /// 联网后按序补传所有待提交房源；返回成功数
    @discardableResult
    func flush(context: ModelContext) async -> Int {
        let houses = (try? context.fetch(FetchDescriptor<House>())) ?? []
        let byKey = Dictionary(houses.map { ($0.mediaRoomKey, $0) },
                               uniquingKeysWith: { a, _ in a })

        // 先补媒体二进制：媒体成功后才能把真实引用写进服务器。
        // 之前先 pushHouse 再传媒体，会把还没传上去的文件写进 media_refs，
        // 刷新时服务器指向不存在的文件，客户端就 404/无图。
        let uploadedRooms = await flushMedia(context: context)

        var done = 0
        let pendingKeySet = Set(pendingKeys)
        var keysToPush = pendingKeySet
        for key in Array(keysToPush) where byKey[key] == nil {
            clearPending(key)   // 本地已无此房（被彻底删除），不再补传
            keysToPush.remove(key)
        }
        keysToPush.formUnion(uploadedRooms)
        for key in keysToPush {
            guard let h = byKey[key] else { continue }
            // 仍留在待上传队列里的媒体不写进服务器引用，避免幽灵引用。
            let pendingNames = Set(HouseMediaUploadQueue.pendingItems()
                .filter { $0.roomKey == key }
                .map { $0.fileName })
            let allowed = Set(h.mediaItems.map { $0.fileName }).subtracting(pendingNames)
            do {
                _ = try await HouseRepository.shared.push(h, mediaFileNames: allowed)
                if pendingKeySet.contains(key) || HousePendingRegistry.keys().contains(key) {
                    completePending(key, remoteKey: h.mediaRoomKey, note: "已上传到服务器")
                }
                // 媒体-only 补传也要计入本次完成数，任务中心才不会显示 0。
                done += 1
            } catch let error as HouseAPIError where error.fieldConflict {
                // 同字段冲突：服务器已有另一版，本机内容保留但不无限重试；
                // 冲突明细由 HouseSyncEngine 写入日志并发通知，用户按明细处理。
                clearPending(key)
                continue
            } catch {
                // 断网/其他临时失败：保留待下轮，不影响其余房源
                continue
            }
        }
        return done
    }

    /// 服务器模式：把待传媒体队列逐个补传到服务器磁盘；成功清条目，本地文件已失则清条目，失败保留待下轮。
    /// 返回本次成功上传过的房源 roomKey 集合，调用方据此补写服务器 media_refs。
    @discardableResult
    func flushMedia(context: ModelContext) async -> Set<String> {
        let items = HouseMediaUploadQueue.pendingItems()
        guard !items.isEmpty else { return [] }
        var uploadedRooms = Set<String>()
        for item in items {
            let localURL = MediaStore.url(for: item.fileName, roomKey: item.roomKey)
            guard FileManager.default.fileExists(atPath: localURL.path),
                  let data = try? Data(contentsOf: localURL) else {
                HouseMediaUploadQueue.remove(roomKey: item.roomKey, fileName: item.fileName)
                continue
            }
            do {
                let result = try await HouseRepository.shared.uploadMedia(
                    roomKey: item.roomKey, fileName: item.fileName, kind: item.kind, data: data)
                // 服务器可能唯一化文件名 / 视频转 .mp4。本地文件与文件名保持原样不动，
                // 由 objectKey ↔ 本地名映射承接；media_refs 取映射里的真实服务器名。
                HouseMediaNameMap.set(roomKey: item.roomKey, objectKey: result.objectKey,
                                      localFileName: item.fileName)
                HouseMediaUploadQueue.remove(roomKey: item.roomKey, fileName: item.fileName)
                uploadedRooms.insert(item.roomKey)
            } catch {
                // 保留条目，下轮同步再试
            }
        }
        if !uploadedRooms.isEmpty { try? context.save() }
        return uploadedRooms
    }
}
