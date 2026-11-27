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
enum HousePendingRegistry {
    static let pendingKey = "house.pending.roomKeys.v1"
    private static let legacyKey = "house_sync_failed_keys"
    static let didChange = Notification.Name("housePendingRegistryChanged")

    static func keys() -> Set<String> {
        migrateLegacyIfNeeded()
        return Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
    }

    static func insert(_ roomKey: String) {
        guard !roomKey.isEmpty else { return }
        var set = keys()
        set.insert(roomKey)
        UserDefaults.standard.set(Array(set), forKey: pendingKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func remove(_ roomKey: String) {
        var set = keys()
        guard set.contains(roomKey) else { return }
        set.remove(roomKey)
        UserDefaults.standard.set(Array(set), forKey: pendingKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 一次性把旧「账本未同步」标记键并入新键，随后旧键清空
    private static func migrateLegacyIfNeeded() {
        let legacy = Set(UserDefaults.standard.stringArray(forKey: legacyKey) ?? [])
        guard !legacy.isEmpty else { return }
        var set = keys()
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

    func markPending(_ roomKey: String) {
        HousePendingRegistry.insert(roomKey)
    }

    func clearPending(_ roomKey: String) {
        HousePendingRegistry.remove(roomKey)
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
        var keysToPush = Set(pendingKeys)
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
                _ = try await HouseSyncEngine.shared.pushHouse(h, mediaFileNames: allowed)
                if HousePendingRegistry.keys().contains(key) {
                    clearPending(key)
                    done += 1
                }
            } catch {
                // 仍失败（断网/冲突），保留待下轮，不影响其余房源
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
        let houses = (try? context.fetch(FetchDescriptor<House>())) ?? []
        let byKey = Dictionary(houses.map { ($0.mediaRoomKey, $0) },
                               uniquingKeysWith: { a, _ in a })
        for item in items {
            let localURL = MediaStore.url(for: item.fileName, roomKey: item.roomKey)
            guard FileManager.default.fileExists(atPath: localURL.path),
                  let data = try? Data(contentsOf: localURL) else {
                HouseMediaUploadQueue.remove(roomKey: item.roomKey, fileName: item.fileName)
                continue
            }
            do {
                let result = try await HouseRemoteClient.shared.uploadMedia(
                    roomKey: item.roomKey, fileName: item.fileName, kind: item.kind, data: data)
                // 服务器可能因为同名/无后缀而唯一化落盘名；必须把本地记录改到真实落盘名，
                // 否则下一次 pushHouse 仍然引用旧名，服务器就留下 404 幽灵引用。
                let expectedRemote = MediaNaming.remoteName(fileName: item.fileName, kind: item.kind)
                if result.fileName != expectedRemote {
                    let actualURL = MediaStore.houseDirectory(roomKey: item.roomKey)
                        .appendingPathComponent(result.fileName)
                    if !FileManager.default.fileExists(atPath: actualURL.path),
                       FileManager.default.fileExists(atPath: localURL.path) {
                        try? FileManager.default.moveItem(at: localURL, to: actualURL)
                    }
                    if let h = byKey[item.roomKey] {
                        for media in h.mediaItems where media.fileName == item.fileName {
                            media.fileName = result.fileName
                        }
                    }
                }
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
