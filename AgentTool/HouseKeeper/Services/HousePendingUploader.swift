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
        let keys = pendingKeys
        var done = 0
        if !keys.isEmpty {
            let houses = (try? context.fetch(FetchDescriptor<House>())) ?? []
            let byKey = Dictionary(houses.map { ($0.mediaRoomKey, $0) },
                                   uniquingKeysWith: { a, _ in a })
            for key in keys {
                guard let h = byKey[key] else {
                    // 本地已无此房（被彻底删除），无需再补传
                    clearPending(key)
                    continue
                }
                do {
                    _ = try await HouseSyncEngine.shared.pushHouse(h)
                    clearPending(key)
                    done += 1
                } catch {
                    // 仍失败（断网/冲突），保留待下轮，不影响其余房源
                    break
                }
            }
        }
        // 文本补传后顺带把待传媒体二进制补到服务器磁盘
        await flushMedia()
        return done
    }

    /// 服务器模式：把待传媒体队列逐个补传到服务器磁盘；成功清条目，本地文件已失则清条目，失败保留待下轮
    @discardableResult
    func flushMedia() async -> Int {
        let items = HouseMediaUploadQueue.pendingItems()
        guard !items.isEmpty else { return 0 }
        var done = 0
        for item in items {
            let localURL = MediaStore.url(for: item.fileName, roomKey: item.roomKey)
            guard FileManager.default.fileExists(atPath: localURL.path),
                  let data = try? Data(contentsOf: localURL) else {
                HouseMediaUploadQueue.remove(roomKey: item.roomKey, fileName: item.fileName)
                continue
            }
            do {
                _ = try await HouseRemoteClient.shared.uploadMedia(
                    roomKey: item.roomKey, fileName: item.fileName, kind: item.kind, data: data)
                HouseMediaUploadQueue.remove(roomKey: item.roomKey, fileName: item.fileName)
                done += 1
            } catch {
                // 保留条目，下轮同步再试
            }
        }
        return done
    }
}
