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

/// 一轮服务器→本地拉取的结果：房源元数据变化 + 媒体回补进度，供列表页和任务中心结算。
struct HousePullResult {
    let changed: Int
    let mediaTotal: Int
    let mediaDownloaded: Int
    let mediaFailed: Int
    let mediaTaskID: UUID?

    var didChangeStore: Bool {
        changed > 0 || mediaDownloaded > 0
    }

    var mediaNote: String? {
        guard mediaTotal > 0 else { return nil }
        let ok = mediaDownloaded
        if mediaFailed > 0 {
            return "媒体 \(ok)/\(mediaTotal) 已下载，\(mediaFailed) 个失败"
        }
        return "媒体 \(ok)/\(mediaTotal) 已下载"
    }
}

/// 手动总刷新的变化预览：先列出服务器变化，再由用户确认应用。
struct HouseChangePreview {
    let newKeys: [String]
    let updatedKeys: [String]
    let deletedKeys: [String]
    let hiddenCount: Int

    private func line(_ label: String, _ keys: [String]) -> String {
        let head = keys.prefix(8).joined(separator: "、")
        let more = keys.count > 8 ? " 等 \(keys.count) 套" : ""
        return "• \(label) \(keys.count) 套：\(head)\(more)"
    }

    var isEmpty: Bool {
        newKeys.isEmpty && updatedKeys.isEmpty && deletedKeys.isEmpty && hiddenCount == 0
    }

    /// 同步完成提示：必须区分新增/修改/服务器删除，避免把“跟随服务器删除”说成“新增”。
    var resultText: String {
        var parts: [String] = []
        if !newKeys.isEmpty { parts.append("新增 \(newKeys.count) 套") }
        if !updatedKeys.isEmpty { parts.append("更新 \(updatedKeys.count) 套") }
        if !deletedKeys.isEmpty { parts.append("服务器删除 \(deletedKeys.count) 套，本机已同步删除") }
        return parts.isEmpty ? "已刷新，无变化" : "已同步：" + parts.joined(separator: "，")
    }

    var summary: String {
        var parts: [String] = []
        if !newKeys.isEmpty { parts.append(line("新增", newKeys)) }
        if !updatedKeys.isEmpty { parts.append(line("修改", updatedKeys)) }
        if !deletedKeys.isEmpty { parts.append(line("服务器删除", deletedKeys)) }
        if parts.isEmpty {
            return "服务器暂无新增、修改或删除；仍会核对一次，并补齐本机缺失的媒体。"
        }
        var text = "服务器变化：\n" + parts.joined(separator: "\n")
        if hiddenCount > 0 {
            text += "\n另有 \(hiddenCount) 套仅删除了本地，本机继续隐藏。"
        }
        text += "\n\n只同步服务器→本机；本机未上传的改动会保留在任务中心，不会自动补传。"
        return text
    }
}

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
    /// 优先查上传时记录的映射；没有映射时按服务器真实文件名落盘（不再无条件把视频改成 .mov，
    /// 否则「本地 .mp4、服务器 .mp4」会被当成 .mov 重复登记）。历史本地 .mov 仍能通过映射/存在性命中。
    static func localFileName(objectKey: String, kind: String, roomKey: String? = nil) -> String {
        let serverName = (objectKey as NSString).lastPathComponent
        if let roomKey, let mapped = HouseMediaNameMap.localName(roomKey: roomKey, objectKey: objectKey) {
            return mapped
        }
        if let roomKey {
            // 没有映射时，先看服务器名对应的本地文件是否存在；视频再看同名 .mov（历史分享入库）
            let direct = MediaStore.url(for: serverName, roomKey: roomKey)
            if FileManager.default.fileExists(atPath: direct.path) { return serverName }
            if kind == "video" {
                let mov = MediaStore.url(for: ((serverName as NSString).deletingPathExtension) + ".mov",
                                         roomKey: roomKey)
                if FileManager.default.fileExists(atPath: mov.path) {
                    return (serverName as NSString).deletingPathExtension + ".mov"
                }
            }
        }
        return serverName
    }

    // MARK: - 拉取（服务器 → 本地）

    /// 拉取服务器全量清单并对账应用；返回实际变化的房源数与媒体回补结果。
    /// - Parameter reportMediaTask: 手动总刷新传 true，把媒体回补挂进任务中心；
    ///   自动对账传 false，不占任务中心，但卡片进度仍然显示。
    @discardableResult
    func pull(context: ModelContext, reportMediaTask: Bool = false) async throws -> HousePullResult {
        // 全量清单：便于识别「曾同步过、但服务器已硬删」的本地孤儿房并一并清除；
        // 纯本地离线未提交的房（revMap 无记录）不会被误删。
        let list = try await HouseRemoteClient.shared.listHouses(since: nil)
        setTop(list.topRevision)
        // 不能因为服务器为空就提前 return：后台硬删最后一套房后，本地 revMap 里仍有
        // 该房记录，必须走一次空清单对账，才能把本地孤儿/“双端”徽章清掉。
        let changed = try applyRemote(list.houses, context: context)
        // 元数据落盘后立刻通知列表重建卡片；媒体回补在卡片已经显示之后进行。
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        // 记录对账完成后，把本地磁盘缺失的媒体从服务器回补落盘（已存在自动跳过）
        let media = await backfillMissingMedia(context: context, reportTask: reportMediaTask)
        if media.downloaded > 0 || media.failed > 0 {
            // 缩略图/视频首帧在文件落盘后需要重新读盘
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        }
        return HousePullResult(changed: changed,
                               mediaTotal: media.total,
                               mediaDownloaded: media.downloaded,
                               mediaFailed: media.failed,
                               mediaTaskID: media.taskID)
    }

    /// 手动总刷新前先算服务器变化，供确认框列出“新增/修改/删除”套数。
    func preview(context: ModelContext) async throws -> HouseChangePreview {
        let list = try await HouseRemoteClient.shared.listHouses(since: nil)
        let locals = (try? context.fetch(FetchDescriptor<House>())) ?? []
        var localByKey: [String: House] = [:]
        for h in locals { localByKey[h.mediaRoomKey] = h }
        let remoteKeys = Set(list.houses.map { $0.roomKey })
        var newKeys: [String] = []
        var updatedKeys: [String] = []

        for r in list.houses {
            if HouseLocalDeletionStore.contains(r.roomKey) { continue }
            guard !r.trashed else { continue }
            guard let local = localByKey[r.roomKey] else {
                newKeys.append(r.roomKey)
                continue
            }
            let knownRevision = serverRevision(forKey: r.roomKey)
            if knownRevision != r.revision || !remoteMatches(local, remote: r) {
                updatedKeys.append(r.roomKey)
            }
        }

        var deletedKeys: [String] = []
        for (key, local) in localByKey where !remoteKeys.contains(key) && !local.isTrashed {
            // 只有曾同步过（有服务器修订记录）的本地房，才可能是服务器硬删；
            // 纯本地未提交房不算“服务器删除”。
            if serverRevision(forKey: key) != nil { deletedKeys.append(key) }
        }

        return HouseChangePreview(newKeys: newKeys.sorted(),
                                  updatedKeys: updatedKeys.sorted(),
                                  deletedKeys: deletedKeys.sorted(),
                                  hiddenCount: HouseLocalDeletionStore.count())
    }

    private func remoteMatches(_ local: House, remote r: RemoteHouse) -> Bool {
        guard local.roomNo == pureRoomNo(r.roomNo, tower: r.tower),
              local.tower == r.tower,
              local.landlord == r.landlord,
              local.layout == r.layout,
              local.price == r.price,
              local.password == r.password,
              local.remark == r.remark,
              local.statusRaw == r.status,
              local.isTrashed == r.trashed else { return false }
        let localMedia = Set(local.mediaItems.map { MediaNaming.canonicalKey($0.fileName) })
        let remoteMedia = Set((r.media ?? []).map {
            MediaNaming.canonicalKey(Self.localFileName(objectKey: $0.objectKey,
                                                        kind: $0.kind,
                                                        roomKey: r.roomKey))
        })
        return localMedia == remoteMedia
    }

    func serverRevision(forKey key: String) -> Int? {
        revMap[key]
    }

    /// 遍历在册房源，回补本地磁盘缺失但服务器有的媒体文件。
    /// - Parameter reportTask: true 时创建任务中心 `mediaDownload` 任务，可失败重试；
    ///   false 时只更新卡片进度，用于自动对账。
    private func backfillMissingMedia(context: ModelContext,
                                      reportTask: Bool) async -> (total: Int, downloaded: Int, failed: Int, taskID: UUID?) {
        let houses = (try? context.fetch(FetchDescriptor<House>())) ?? []
        var jobs: [(house: House, records: [(fileName: String, kind: String)])] = []
        for h in houses where !h.isTrashed {
            let onDisk = Set(MediaStore.existingFileNames(roomKey: h.mediaRoomKey)
                .map { MediaNaming.canonicalKey($0) })
            let missing = h.mediaItems.filter {
                !onDisk.contains(MediaNaming.canonicalKey($0.fileName))
            }
            guard !missing.isEmpty else { continue }
            jobs.append((h, missing.map { ($0.fileName, $0.kind) }))
        }
        let total = jobs.reduce(0) { $0 + $1.records.count }
        guard total > 0 else { return (0, 0, 0, nil) }

        var taskID: UUID?
        if reportTask {
            taskID = SyncTaskCenter.shared.begin(
                kind: .mediaDownload,
                title: "下载服务器媒体",
                roomKeys: jobs.map { $0.house.mediaRoomKey },
                total: total,
                note: "准备下载 \(total) 个媒体"
            )
        }

        var downloaded = 0
        var failed = 0
        var jobOffset = 0
        for job in jobs {
            let roomKey = job.house.mediaRoomKey
            let offset = jobOffset
            let progressToken = HouseSyncProgress.shared.begin(
                roomKey: roomKey, direction: .download,
                progress: 0, label: "下载媒体 0/\(job.records.count)")
            let result = await HouseRemoteClient.shared.downloadMissingMedia(
                roomKey: roomKey,
                records: job.records,
                onProgress: { fileDone, _, name in
                    let globalDone = offset + fileDone
                    Task { @MainActor in
                        HouseSyncProgress.shared.update(
                            roomKey: roomKey, direction: .download,
                            progress: Double(globalDone) / Double(total),
                            label: "下载媒体 \(globalDone)/\(total)",
                            token: progressToken)
                        if let taskID {
                            SyncTaskCenter.shared.advance(
                                id: taskID, done: globalDone,
                                note: "下载 \(name)（\(globalDone)/\(total)）")
                        }
                    }
                })
            downloaded += result.files.count
            failed += result.failedFiles.count
            jobOffset += job.records.count
            HouseSyncProgress.shared.end(token: progressToken)
        }

        if let taskID {
            if failed == 0 {
                SyncTaskCenter.shared.finish(id: taskID, success: true,
                                             note: "已下载 \(downloaded)/\(total) 个媒体")
            } else {
                SyncTaskCenter.shared.finish(id: taskID, success: false,
                                             failure: "媒体下载失败 \(failed) 个，点重试")
            }
        }
        return (total, downloaded, failed, taskID)
    }

    private func applyRemote(_ remoteHouses: [RemoteHouse], context: ModelContext) throws -> Int {
        let allHouses = try context.fetch(FetchDescriptor<House>())
        var byKey: [String: House] = [:]
        for h in allHouses {
            byKey[h.mediaRoomKey] = h
        }
        var changed = 0
        var unreadKeys: [String] = []
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
            // 服务器又出现了这套房：清除“服务器已删除”标记。
            HouseServerMissingStore.remove(r.roomKey)
            if pendingKeys.contains(r.roomKey) {
                continue
            }
            let isNewForLocal = byKey[r.roomKey] == nil
            let target = byKey[r.roomKey] ?? House()
            if isNewForLocal {
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
            // b31：手动同步后，新插入或被服务器改动的房源恢复红框未读提示。
            // 自动检测只挂横幅、不写本地，因此不会产生未读；进入详情页后照旧清除。
            if !r.trashed && (isNewForLocal || snapshot(target) != before) {
                unreadKeys.append(r.roomKey)
            }
            setServerRevision(r.revision, forKey: r.roomKey)
            // 保存一份服务器快照：下次编辑提交时作为字段级合并的 base
            HouseBaseSnapshotStore.save(r)
        }
        if !unreadKeys.isEmpty {
            UnreadCloudHouseStore.mark(unreadKeys)
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
            // 本机待补传房：服务器已没有它（曾同步过、revMap 有记录）时，标记为
            // “服务器已删除”，由详情页给用户一个“彻底删除本机房源”按钮；
            // 不在自动对账里静默删掉本机改动。纯本地未提交房（revMap 无记录）不标记。
            if pendingKeys.contains(key) {
                if revMap[key] != nil { HouseServerMissingStore.mark(key) }
                continue
            }
            if revMap[key] != nil {
                context.delete(h)
                removeServerRevision(forKey: key)
                HouseBaseSnapshotStore.remove(key)
                HouseMediaNameMap.removeRoom(key)
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
            Self.localFileName(objectKey: $0.objectKey, kind: $0.kind,
                               roomKey: house.mediaRoomKey)
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
            let localName = Self.localFileName(objectKey: m.objectKey, kind: m.kind,
                                               roomKey: house.mediaRoomKey)
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
    func pushHouse(_ house: House, mediaFileNames: Set<String>? = nil,
                   changedFields: Set<String>? = nil) async throws -> RemoteHouse {
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
        let mediaPayload = mediaArray(house, roomKey: roomKey, onlyNames: effectiveNames)
        let base = HouseBaseSnapshotStore.load(roomKey)
        let currentKeys = Set(mediaPayload.compactMap { $0["objectKey"] as? String })
        let removedKeys = (base?.mediaKeys ?? []).filter { !currentKeys.contains($0) }
        let payload = HouseSyncPayload(
            roomKey: roomKey, roomNo: house.roomNo, tower: house.tower,
            landlord: house.landlord, layout: house.layout, price: house.price,
            password: house.password, remark: house.remark,
            status: house.statusRaw, media: mediaPayload,
            base: base?.fields, baseMedia: base?.mediaKeys,
            removedMedia: removedKeys,
            changedFields: changedFields.map { Array($0).sorted() })
        let expected = revMap[roomKey]
        // 新增/本机从未拿到服务器修订号：按“创建”提交，服务器已同房号时直接拒绝，
        // 不能把别人的房源当成本机旧版本覆盖掉。
        let createOnly = (expected == nil)
        let remote: RemoteHouse
        do {
            remote = try await HouseRemoteClient.shared.upsert(
                payload, expectedRevision: expected, createOnly: createOnly)
        } catch let error as HouseAPIError where error.fieldConflict {
            // 同字段两边都改：服务器拒绝覆盖并返回明细。本机改动保留，但不再自动重试，
            // 避免每轮补传都撞同一冲突；提示用户按明细决定保留哪边。
            let lines = error.fieldConflicts.map { c in
                "\(c["label"] ?? c["field"] ?? "字段")：服务器「\(c["server"] ?? "")」/ 本机「\(c["client"] ?? "")」"
            }.joined(separator: "；")
            BackupLogStore.log(category: "房源", action: "字段冲突", result: "冲突",
                               detail: lines.isEmpty ? error.message : lines,
                               room: roomKey, cloud: true)
            HouseActionNotifier.shared.send(
                key: "fieldconflict.\(roomKey)",
                title: "有字段被其他设备改过",
                body: "\(roomKey) 本次未上传：\(lines.isEmpty ? "同字段冲突" : lines)",
                silent: true)
            throw error
        } catch let error as HouseAPIError where error.revisionConflict {
            // 冲突后先拉一次服务器当前 revision 更新本地基线；本次仍抛给调用方提示/保留本机改动。
            // 不能用 try? 把「404 = 服务器确实已删」和「网络错误 = 不知道」混成 nil，
            // 否则一次弱网抖动就会被 UI 当成服务器已删，诱导用户彻底删本机房源。
            do {
                if let fresh = try await HouseRemoteClient.shared.getHouse(roomKey) {
                    setServerRevision(fresh.revision, forKey: roomKey)
                    setTop(max(topRevision, fresh.revision))
                    HouseBaseSnapshotStore.save(fresh)
                    BackupLogStore.log(category: "房源", action: "同步冲突", result: "冲突",
                                       detail: "服务器已更新到修订 \(fresh.revision)；本机改动保留，下一次提交按字段合并",
                                       room: roomKey, cloud: true)
                } else {
                    HouseServerMissingStore.mark(roomKey)
                    BackupLogStore.log(category: "房源", action: "同步冲突", result: "冲突",
                                       detail: "服务器已无此房源（可能被其他设备删除）；本机改动保留，可在详情页彻底删除本机",
                                       room: roomKey, cloud: true)
                }
            } catch {
                // 网络/鉴权失败：状态未知，不标记服务器删除，交给下一轮补传
                BackupLogStore.log(category: "房源", action: "同步冲突", result: "待重试",
                                   detail: "冲突后无法确认服务器状态（\(error.localizedDescription)），本机改动保留，稍后自动重试",
                                   room: roomKey, cloud: true)
            }
            throw error
        }
        setServerRevision(remote.revision, forKey: roomKey)
        setTop(max(topRevision, remote.revision))
        HouseBaseSnapshotStore.save(remote)
        HouseServerMissingStore.remove(roomKey)
        return remote
    }

    /// 批量导入专用：新收录房源一次 `:batch` 提交，返回失败房号→错误。
    /// 已有服务器 revision 的房源不走批量（回单条 pushHouse，保留 base 字段合并语义）。
    func pushHousesBatch(_ houses: [House]) async throws -> [String: Error] {
        let fresh = houses.filter { revMap[$0.mediaRoomKey] == nil }
        guard !fresh.isEmpty else { return [:] }
        var payloads: [HouseSyncPayload] = []
        for house in fresh {
            let roomKey = house.mediaRoomKey
            let pendingNames = Set(HouseMediaUploadQueue.pendingItems()
                .filter { $0.roomKey == roomKey }
                .map { $0.fileName })
            let allowed: Set<String>? = pendingNames.isEmpty
                ? nil
                : Set(house.mediaItems.map { $0.fileName }).subtracting(pendingNames)
            let mediaPayload = mediaArray(house, roomKey: roomKey, onlyNames: allowed)
            payloads.append(HouseSyncPayload(
                roomKey: roomKey, roomNo: house.roomNo, tower: house.tower,
                landlord: house.landlord, layout: house.layout, price: house.price,
                password: house.password, remark: house.remark,
                status: house.statusRaw, media: mediaPayload,
                base: nil, baseMedia: nil, removedMedia: nil))
        }
        let outcomes = try await HouseRemoteClient.shared.upsertBatch(
            payloads,
            expectedRevisions: Array(repeating: nil, count: payloads.count),
            createOnly: Array(repeating: true, count: payloads.count))
        var failures: [String: Error] = [:]
        for outcome in outcomes {
            if let remote = outcome.house {
                setServerRevision(remote.revision, forKey: outcome.roomKey)
                setTop(max(topRevision, remote.revision))
                HouseBaseSnapshotStore.save(remote)
                HouseServerMissingStore.remove(outcome.roomKey)
            } else if let error = outcome.error {
                failures[outcome.roomKey] = error
            }
        }
        // 已有 revision 的房源保留单条字段合并；批量导入通常是新房，不常走这里。
        for house in houses where revMap[house.mediaRoomKey] != nil {
            do {
                try await pushHouse(house)
            } catch {
                failures[house.mediaRoomKey] = error
            }
        }
        return failures
    }

    /// 服务器已硬删、本机仍残留待补传时，按“服务器为准”彻底清掉本机房源。
    /// 只动本地，不再请求服务器（避免已删除房源被二次操作）；返回实际清理套数。
    @discardableResult
    func purgeLocalHouses(_ roomKeys: [String], context: ModelContext) -> Int {
        let keys = Set(roomKeys.filter { !$0.isEmpty })
        guard !keys.isEmpty else { return 0 }
        let houses = (try? context.fetch(FetchDescriptor<House>())) ?? []
        var deleted = 0
        for house in houses where keys.contains(house.mediaRoomKey) {
            let key = house.mediaRoomKey
            MediaStore.deleteHouseDirectory(roomKey: key)
            HousePendingUploader.shared.clearPending(key)
            SyncFailStore.clear(key)
            HouseMediaUploadQueue.removeRoom(key)
            HouseLocalDeletionStore.remove(key)
            HouseServerMissingStore.remove(key)
            HouseBaseSnapshotStore.remove(key)
            HouseMediaNameMap.removeRoom(key)
            UnreadCloudHouseStore.clear(key)
            context.delete(house)
            deleted += 1
            BackupLogStore.log(category: "房源", action: "彻底删除本机房源", result: "成功",
                               detail: "服务器已删除，按服务器为准清理本机，不再保留本机改动",
                               room: key, cloud: true)
        }
        if deleted > 0 {
            try? context.save()
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        }
        return deleted
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
            // 上传时可能被服务器唯一化/转码；优先用映射里的真实 objectKey，
            // 没有映射才按本地名推导。fileName 用服务器落盘名，账本才能和磁盘对上。
            let key = HouseMediaNameMap.objectKey(roomKey: roomKey,
                                                 localFileName: item.fileName)
                ?? Self.objectKey(roomKey: roomKey, fileName: item.fileName,
                                  kind: item.kind)
            let remoteName = (key as NSString).lastPathComponent
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
    private static let legacyKey = "house.localDeletion.roomKeys.v1"
    /// 同一台手机可能切换账号；墓碑必须按账号隔离，否则 A 账号仅删本地的房
    /// 会让 B 账号登录后也看不到这套房。
    private static var key: String {
        legacyKey + "." + CloudUser.safeName
    }

    static func keys() -> Set<String> {
        migrateLegacyIfNeeded()
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil,
              let legacy = defaults.stringArray(forKey: legacyKey),
              !legacy.isEmpty else { return }
        defaults.set(legacy, forKey: key)
        defaults.removeObject(forKey: legacyKey)
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

/// 服务器上已经不存在（被其他设备硬删）的房源标记。
/// 仅用于 UI 给出「彻底删除本机房源」入口；不自动静默删除本地待补传改动。
enum HouseServerMissingStore {
    static let didChange = Notification.Name("houseServerMissingChanged")
    private static let baseKey = "house.serverMissing.roomKeys.v1"
    private static var key: String { baseKey + "." + CloudUser.safeName }

    static func keys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func contains(_ roomKey: String) -> Bool {
        keys().contains(roomKey)
    }

    static func mark(_ roomKey: String) {
        guard !roomKey.isEmpty else { return }
        var set = keys()
        guard set.insert(roomKey).inserted else { return }
        UserDefaults.standard.set(Array(set), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func remove(_ roomKey: String) {
        var set = keys()
        guard set.remove(roomKey) != nil else { return }
        UserDefaults.standard.set(Array(set), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
