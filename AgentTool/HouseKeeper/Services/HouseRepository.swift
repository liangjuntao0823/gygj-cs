//
//  HouseRepository.swift
//  公寓管家 · 房源板块统一仓库层（b29）
//
//  视图只通过本仓库读写房源数据与服务器；HouseSyncEngine / HouseRemoteClient 退到仓库内部，
//  不再被各个 View 直接调用。这样“保存到本机、推服务器、挂补传、写日志”只有一套口径。
//

import Foundation
import SwiftData

@MainActor
final class HouseRepository {
    static let shared = HouseRepository()
    private init() {}

    /// HouseStore 容器的主 context，由 App 启动时注入。
    private var context: ModelContext?

    func configure(context: ModelContext) {
        self.context = context
    }

    private func requireContext() -> ModelContext? { context }

    // MARK: - 本地读

    func fetchAll(includeTrashed: Bool = false) throws -> [House] {
        guard let context = requireContext() else { return [] }
        let all = try context.fetch(FetchDescriptor<House>())
        return includeTrashed ? all : all.filter { !$0.isTrashed }
    }

    /// 列表用：创建时间倒序（替代 @Query 的 sort）
    func fetchAllSorted() -> [House] {
        (try? fetchAll())?.sorted { $0.createdAt > $1.createdAt } ?? []
    }

    func processPendingChanges() {
        context?.processPendingChanges()
    }

    func fetch(roomKey: String) -> House? {
        try? fetchAll(includeTrashed: true).first { $0.mediaRoomKey == roomKey }
    }

    // MARK: - 本地写（视图落库统一入口）

    func insert(_ house: House) {
        context?.insert(house)
    }

    func delete(_ house: House) {
        context?.delete(house)
    }

    func save() throws {
        try context?.save()
    }

    // MARK: - 待补传登记

    func markPending(_ roomKey: String, action: String = "", detail: String = "") {
        HousePendingUploader.shared.markPending(roomKey, action: action, detail: detail)
    }

    func clearPending(_ roomKey: String) {
        HousePendingUploader.shared.clearPending(roomKey)
    }

    func pendingChange(for roomKey: String) -> HousePendingChange? {
        HousePendingRegistry.change(for: roomKey)
    }

    func completePending(_ roomKey: String, remoteKey: String? = nil, note: String = "") {
        HousePendingUploader.shared.completePending(roomKey, remoteKey: remoteKey, note: note)
    }

    func pendingKeys() -> [String] { HousePendingUploader.shared.pendingKeys }
    func hasPending() -> Bool { HousePendingUploader.shared.hasPending }

    // MARK: - 服务器同步（视图不直接碰引擎/客户端）

    func push(_ house: House, mediaFileNames: Set<String>? = nil) async throws -> RemoteHouse {
        try await HouseSyncEngine.shared.pushHouse(house, mediaFileNames: mediaFileNames)
    }

    func pushHousesBatch(_ houses: [House]) async throws -> [String: Error] {
        try await HouseSyncEngine.shared.pushHousesBatch(houses)
    }

    func pull(reportMediaTask: Bool = false) async throws -> HousePullResult {
        guard let context = requireContext() else {
            return HousePullResult(changed: 0, mediaTotal: 0, mediaDownloaded: 0,
                                   mediaFailed: 0, mediaTaskID: nil)
        }
        return try await HouseSyncEngine.shared.pull(context: context, reportMediaTask: reportMediaTask)
    }

    func preview() async throws -> HouseChangePreview {
        guard let context = requireContext() else {
            return HouseChangePreview(newKeys: [], updatedKeys: [], deletedKeys: [], hiddenCount: 0)
        }
        return try await HouseSyncEngine.shared.preview(context: context)
    }

    func pushDelete(_ house: House) async throws {
        try await HouseSyncEngine.shared.pushDelete(house)
    }

    func purgeLocal(_ roomKeys: [String]) -> Int {
        guard let context = requireContext() else { return 0 }
        return HouseSyncEngine.shared.purgeLocalHouses(roomKeys, context: context)
    }

    func hiddenCloudCount() -> Int { HouseSyncEngine.shared.hiddenCloudCount }

    func flushPending() async -> Int {
        guard let context = requireContext() else { return 0 }
        return await HousePendingUploader.shared.flush(context: context)
    }

    // MARK: - 服务器基础操作

    func testConnection() async -> HouseConnectionCheck {
        await HouseRemoteClient.shared.testConnection()
    }

    func fetchStorageStats() async throws -> RemoteStorageStats {
        try await HouseRemoteClient.shared.fetchStorageStats()
    }

    func getHouse(_ roomKey: String) async throws -> RemoteHouse? {
        try await HouseRemoteClient.shared.getHouse(roomKey)
    }

    func deleteRemote(_ roomKey: String) async throws {
        try await HouseRemoteClient.shared.delete(roomKey)
    }

    func restoreRemote(_ roomKey: String) async throws -> RemoteHouse {
        try await HouseRemoteClient.shared.restore(roomKey)
    }

    func downloadMissingMedia(roomKey: String, records: [(fileName: String, kind: String)],
                              onProgress: ((Int, Int, String) -> Void)? = nil) async -> MediaDownloadResult {
        await HouseRemoteClient.shared.downloadMissingMedia(roomKey: roomKey, records: records,
                                                            onProgress: onProgress)
    }

    func uploadMedia(roomKey: String, fileName: String, kind: String,
                     data: Data) async throws -> (objectKey: String, fileName: String) {
        try await HouseRemoteClient.shared.uploadMedia(roomKey: roomKey, fileName: fileName,
                                                       kind: kind, data: data)
    }

    func deleteMedia(roomKey: String, fileName: String) async throws {
        try await HouseRemoteClient.shared.deleteMedia(roomKey: roomKey, fileName: fileName)
    }

    func addShareRecord(roomKey: String, channel: String, summary: String) async throws {
        try await HouseRemoteClient.shared.addShareRecord(roomKey: roomKey, channel: channel, summary: summary)
    }

    func ledger(roomKey: String) async throws -> [RemoteLedgerEvent] {
        try await HouseRemoteClient.shared.ledger(roomKey)
    }

    func appendLedger(roomKey: String, event: HouseLedgerEvent) async throws {
        try await HouseRemoteClient.shared.appendLedger(roomKey: roomKey, event: event)
    }

    func listOrphanMedia(minAge: Int = 3600) async throws -> RemoteOrphanList {
        try await HouseRemoteClient.shared.listOrphanMedia(minAge: minAge)
    }

    func deleteOrphanMedia(objectKeys: [String], minAge: Int = 3600) async throws -> RemoteOrphanDeleteResult {
        try await HouseRemoteClient.shared.deleteOrphanMedia(objectKeys: objectKeys, minAge: minAge)
    }
}
