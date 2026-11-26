import Foundation
import UIKit

/// v2.68 分享扩展上传编排：与 App 内「新增房源 / 编辑保存」同一套函数、同一口径。
/// - 媒体：ExtensionHouseClient.uploadMedia（本地入库已压缩，上传原样二进制；命名/去重复用本地队列）；
///   失败不自动重试，预登记在共享队列，主 App 任务中心手动重试；
/// - 房源：ExtensionHouseClient.upsert（expectedRevision 乐观锁 + 服务器回写权威记录）；
///   账本本地 append + markDirty，服务器账本上行归阶段 B 编排收口；
/// - 日志：v2.71 改 BackupLogStore.logAwait（先入共享待补队→await 发送→成功出队，进程被杀不丢）；
/// - 本地落库：v2.71 每次入库写 ShareLocalInbox 待写账，App 启动/回前台收养进 SwiftData，
///   分享新增不再「只上云、本机没有」；
/// - 通知：HouseActionNotifier（文案与 App 内逐字一致）。
/// 不触碰 SwiftData / SyncTaskCenter / HouseSyncProgress（主 App UI 层）。
@MainActor
final class ShareUploadCoordinator: ObservableObject {

    /// 暂存媒体：kind=image/video，url=扩展临时目录里的源文件（视频已按真实容器定后缀）
    struct StagedItem {
        let kind: String
        let url: URL
    }

    /// v2.71 入库模式：新增房源 / 保留旧媒体补传 / 清掉旧媒体再传新的
    enum RunMode {
        case newHouse
        case append
        case replace
    }

    /// 单文件进度行
    struct FileRow: Identifiable {
        let id = UUID()
        let fileName: String
        let kind: String
        var stage: String = "待上传"
        var percent: Double = 0
        var state: String = "pending"   // pending / uploading / success / failed
    }

    struct Outcome {
        var success = 0
        var failed = 0
        var skipped = 0
        var failedFiles: [String] = []
        var lastError = ""
        var ledgerOK = false
        var title = ""
        var body = ""
    }

    @Published var rows: [FileRow] = []
    @Published var phaseText = "准备中"

    /// 新增房源表单（v2.71 与 HouseEditView 新建要素对齐：座号/房号/租金/房东/户型/密码/备注/状态）
    struct NewRoomForm {
        var tower = 1
        var roomNo = ""
        var priceText = ""
        var landlord = ""
        var layout = ""
        var password = ""
        var remark = ""
        var statusRaw = HouseStatus.available.rawValue

        /// 房号归一 + 带座前缀 + 非法字符替换（逐字对齐 House.mediaRoomKey）
        var roomKey: String {
            var s = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixes = ["2-", "1-", "2－", "1－"]
            var changed = true
            while changed {
                changed = false
                for p in prefixes where s.hasPrefix(p) {
                    s = String(s.dropFirst(p.count))
                    changed = true
                }
            }
            let raw = (tower == 2 ? "2-" : "1-") + s
            let illegal = CharacterSet(charactersIn: "/:\\?%*|\u{22}<>")
            return raw.components(separatedBy: illegal).joined(separator: "-")
        }

        var validationError: String? {
            let no = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            if no.isEmpty { return "请填写房号" }
            if landlord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写房东" }
            let p = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty || Int(p) == nil { return "租金请填写数字" }
            return nil
        }

        func record(mediaNames: [String]) -> CloudHouseRecord {
            CloudHouseRecord(
                roomKey: roomKey,
                roomNo: roomNo.trimmingCharacters(in: .whitespacesAndNewlines),
                tower: tower,
                landlord: landlord.trimmingCharacters(in: .whitespacesAndNewlines),
                layout: layout.trimmingCharacters(in: .whitespacesAndNewlines),
                price: Int(priceText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                password: password,
                remark: remark.trimmingCharacters(in: .whitespacesAndNewlines),
                status: statusRaw,
                updatedAt: Date(),
                updatedBy: CloudUser.signedUsername,
                mediaNames: mediaNames,
                revision: nil
            )
        }
    }

    /// 入库：图片 UIImage→JPEG 0.85（与 loadPhotos 同参数）；视频原文件+真实容器后缀（与 loadVideos 同口径）。
    /// 逐张 autoreleasepool，控制扩展内存峰值。
    private func ingest(_ item: StagedItem, roomKey: String) -> String? {
        if item.kind == "video" {
            return MediaStore.saveFile(from: item.url, roomKey: roomKey)
        }
        return autoreleasepool { () -> String? in
            guard let image = UIImage(contentsOfFile: item.url.path),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
            return MediaStore.save(data: jpeg, ext: "jpg", roomKey: roomKey)
        }
    }

    private static func kind(ofName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return (ext == "mp4" || ext == "mov") ? "video" : "image"
    }

    /// 主流程。mode=.newHouse 按 form 新增；.append 保留旧媒体补传；.replace 清旧媒体再传新。
    func run(staged: [StagedItem], existing: CloudHouseRecord?, form: NewRoomForm, mode: RunMode) async -> Outcome {
        var out = Outcome()
        let roomKey = existing?.roomKey ?? form.roomKey
        let isNewHouse = mode == .newHouse

        // 端点/令牌由 ExtensionHouseClient 内部经 SharedBridge 镜像从 App Group 读取；
        // 镜像缺失时在首次请求抛"服务器地址无效"。

        await MediaActivityGate.shared.beginUpload()
        defer { Task { await MediaActivityGate.shared.endUpload() } }

        // 2) 入库 + 预登记队列（即使扩展中途被系统终止，主 App 任务中心也能接手，文件不丢）
        phaseText = "媒体入库中"
        var saved: [(fileName: String, kind: String)] = []
        for item in staged {
            if let name = ingest(item, roomKey: roomKey) {
                saved.append((name, item.kind))
                HouseMediaUploadQueue.enqueue(roomKey: roomKey, fileName: name, kind: item.kind)
            } else {
                out.skipped += 1
            }
        }
        rows = saved.map { FileRow(fileName: $0.fileName, kind: $0.kind) }

        // v2.71：本地口径记录（含本次登记的全部媒体）——云端写失败时作本地镜像/待写账基线
        var localRecord: CloudHouseRecord
        let removedNames: [String] = (mode == .replace) ? (existing?.mediaNames ?? []) : []
        if isNewHouse {
            localRecord = form.record(mediaNames: saved.map { $0.fileName })
        } else {
            var base = existing!
            base.mediaNames = (mode == .replace)
                ? saved.map { $0.fileName }
                : Array(Set(base.mediaNames).union(saved.map { $0.fileName }))
            base.updatedAt = Date()
            base.updatedBy = CloudUser.signedUsername
            localRecord = base
        }
        var cloudRecord: CloudHouseRecord? = nil
        var failedDeletes: [String] = []
        var ledgerSynced = false
        var cloudOK = false

        // v2.71：本地待写账——所有退出路径（含取消/云端失败）都写，App 打开即收养进本地库
        func stashInbox() {
            ShareLocalInbox.write(ShareLocalInboxEntry(
                id: UUID().uuidString,
                roomKey: roomKey,
                isNewHouse: isNewHouse,
                formRecord: localRecord,
                cloudRecord: cloudRecord,
                localMedia: saved.map { ShareLocalInboxEntry.MediaRef(name: $0.fileName, kind: $0.kind) },
                removed: removedNames,
                failedDeletes: failedDeletes,
                cloudOK: cloudOK,
                ledgerSynced: ledgerSynced,
                date: Date()))
        }
        // v2.71：共享区账本镜像 info.json（与云端同构），App 收养时搬进 Documents 作对账基线
        func writeMirror() {
            guard let dir = MediaStore.sharedMediaDirectory?
                .appendingPathComponent(roomKey, isDirectory: true) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cloudRecord ?? localRecord) {
                try? data.write(to: dir.appendingPathComponent("info.json"), options: .atomic)
            }
        }

        // 3) 逐文件直传服务器（本地入库已完成压缩/转码，上传原样二进制；失败不自动重试，留在共享队列）
        let total = saved.count
        var successNames: [String] = []
        for (idx, file) in saved.enumerated() {
            phaseText = "上传中 \(idx + 1)/\(total)"
            rows[idx].state = "uploading"
            do {
                let localURL = MediaStore.url(for: file.fileName, roomKey: roomKey)
                guard FileManager.default.fileExists(atPath: localURL.path),
                      let data = try? Data(contentsOf: localURL) else {
                    throw ExtHouseError(message: "本地媒体文件读取失败")
                }
                _ = try await ExtensionHouseClient.uploadMedia(
                    roomKey: roomKey, fileName: file.fileName, kind: file.kind, data: data)
                HouseMediaUploadQueue.remove(roomKey: roomKey, fileName: file.fileName)
                rows[idx].state = "success"
                rows[idx].percent = 1
                out.success += 1
                successNames.append(file.fileName)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    out.lastError = "已取消"
                    writeMirror()
                    stashInbox()
                    return out
                }
                rows[idx].state = "failed"
                out.failed += 1
                out.failedFiles.append(file.fileName)
                out.lastError = error.localizedDescription
            }
        }

        // 4) 媒体阶段日志（与 uploadMedia 逐字同口径；v2.71 可靠上云）
        let upSplit = HouseLedgerFormat.split(saved.map { (name: $0.fileName, kind: $0.kind) })
        let upParts = HouseLedgerFormat.mediaParts(images: upSplit.images, videos: upSplit.videos, includeNames: false)
        if out.failed > 0 {
            let upAction = isNewHouse ? "新增房源" : "新增媒体（本地→云端）"
            let upResult = isNewHouse && out.failed >= total ? "失败" : "部分失败"
            let upDetail = isNewHouse
                ? HouseMediaLogFormat.failureDetail(images: upSplit.images.count, videos: upSplit.videos.count, error: out.lastError)
                : upParts.joined(separator: "；") + "；成功 \(out.success) 失败 \(out.failed)（已入队自动补传）" + (out.lastError.isEmpty ? "" : "；错误：\(out.lastError)")
            await BackupLogStore.logAwait(category: "房源", action: upAction, result: upResult,
                                          detail: upDetail, room: roomKey, cloud: true)
        } else if out.success > 0 && !isNewHouse {
            let upAction: String
            if upSplit.videos.isEmpty { upAction = "新增图片（本地→云端）" }
            else if upSplit.images.isEmpty { upAction = "新增视频（本地→云端）" }
            else { upAction = "新增媒体（本地→云端）" }
            await BackupLogStore.logAwait(category: "房源", action: upAction, result: "成功",
                                          detail: upParts.joined(separator: "；"), room: roomKey, cloud: true)
        }

        // 5) 账本事件 + 记录推送（新增：先媒体后账本；失败文件名不进 mediaNames）
        phaseText = "同步账本"
        let successSplit = HouseLedgerFormat.split(saved.filter { successNames.contains($0.fileName) }.map { (name: $0.fileName, kind: $0.kind) })
        var record: CloudHouseRecord
        let action: String
        let changeText: String
        if isNewHouse {
            let initial = HouseLedgerFormat.mediaSummary(images: successSplit.images.count, videos: successSplit.videos.count)
            action = "新增房源"
            changeText = "新建房源，" + (initial.isEmpty ? "无媒体" : initial)
            record = form.record(mediaNames: successNames)
            if out.success > 0 || total == 0 {
                HouseLedgerStore.append(roomKey: roomKey, action: action, detail: changeText)
            }
        } else {
            var base = existing!
            let addedParts = HouseLedgerFormat.mediaParts(images: successSplit.images, videos: successSplit.videos, includeNames: false)
            action = successSplit.videos.isEmpty ? "新增图片"
                : (successSplit.images.isEmpty ? "新增视频" : "新增媒体")
            changeText = addedParts.map { "新增\($0)" }.joined(separator: "；")
            base.mediaNames = (mode == .replace)
                ? successNames
                : Array(Set(base.mediaNames).union(successNames))
            base.updatedAt = Date()
            base.updatedBy = CloudUser.signedUsername
            record = base
            if !addedParts.isEmpty {
                HouseLedgerStore.append(roomKey: roomKey, action: action, detail: changeText)
            }
        }

        do {
            let merged = try await ExtensionHouseClient.upsert(
                record, expectedRevision: existing?.revision.map { Int($0) })
            cloudRecord = merged
            cloudOK = true
            // 合并注记与旧链同口径（集合差判定）
            let hadExisting = !isNewHouse
            let cloudOnly = Set(merged.mediaNames).subtracting(Set(record.mediaNames))
            let mergeNote = (hadExisting && !cloudOnly.isEmpty)
                ? "；已合并云端原有 \(cloudOnly.count) 个媒体"
                : ""
            let mainLogged = isNewHouse ? out.failed == 0 : true
            if mainLogged && (isNewHouse || !changeText.isEmpty) {
                await BackupLogStore.logAwait(category: "房源", action: action, result: "成功",
                                              detail: changeText + mergeNote, room: roomKey, cloud: true)
            } else if !mergeNote.isEmpty {
                await BackupLogStore.logAwait(category: "同步", action: "合并云端更新", result: "成功",
                                              detail: "云端有别人的更新，已合并：媒体 \(record.mediaNames.count) 个 → \(merged.mediaNames.count) 个", room: roomKey, cloud: true)
            }
            out.ledgerOK = true

            // 5.5) v2.71 清旧换新：删云端旧对象 + 清共享区旧文件 + 账本删除事件（与 App 编辑删媒体同口径）
            if mode == .replace && !removedNames.isEmpty {
                for name in removedNames {
                    do {
                        try await ExtensionHouseClient.deleteMedia(roomKey: roomKey, fileName: name)
                    } catch {
                        failedDeletes.append(name)
                    }
                    MediaStore.delete(fileName: name, roomKey: roomKey)
                }
                let rmSplit = HouseLedgerFormat.split(removedNames.map { (name: $0, kind: Self.kind(ofName: $0)) })
                let rmAction = rmSplit.videos.isEmpty ? "删除图片"
                    : (rmSplit.images.isEmpty ? "删除视频" : "删除媒体")
                let rmSummary = HouseLedgerFormat.mediaSummary(images: rmSplit.images.count, videos: rmSplit.videos.count)
                HouseLedgerStore.append(roomKey: roomKey, action: rmAction, detail: "删除" + rmSummary)
                await BackupLogStore.logAwait(
                    category: "房源", action: "删除媒体（本地→云端）",
                    result: failedDeletes.isEmpty ? "成功" : "部分失败",
                    detail: rmSummary + (failedDeletes.isEmpty ? "" : "；\(failedDeletes.count) 个云端删除失败已挂任务中心"),
                    room: roomKey, cloud: true)
            }

            // 6) 账本上行归阶段 B 编排收口；扩展内仅落本地 dirty 标记，主 App 启动接手补上行
            HouseLedgerStore.markDirty(roomKey)
        } catch {
            await BackupLogStore.logAwait(category: "房源", action: action, result: "失败",
                                          detail: "云端更新失败：\(error.localizedDescription)", room: roomKey, cloud: true)
            out.lastError = error.localizedDescription
            if (error as? ExtHouseError)?.conflict == true {
                HouseActionNotifier.shared.send(
                    key: "conflict.\(roomKey)",
                    title: "修改没传上去",
                    body: "\(roomKey) 刚被其他设备更新，本次改动只存本机；请刷新同步后再编辑",
                    silent: true)
            } else {
                HouseActionNotifier.shared.send(
                    key: "syncfail.\(roomKey)",
                    title: "同步失败",
                    body: "\(roomKey) 云端同步失败：已挂同步任务中心，联网后点重试",
                    silent: true)
            }
            out.title = "同步失败"
            out.body = "\(roomKey) 云端同步失败：已挂同步任务中心，联网后点重试"
            writeMirror()
            stashInbox()
            return out
        }

        // 8) 系统通知（文案与 notifySaved 逐字一致）
        let images = staged.filter { $0.kind == "image" }.count
        let videos = staged.filter { $0.kind == "video" }.count
        var mediaSuffix = ""
        if images > 0 || videos > 0 { mediaSuffix = "（照片\(images)、视频\(videos)）" }
        if isNewHouse {
            if out.failed > 0 {
                out.title = "房源已保存，媒体待补传"
                out.body = "\(roomKey) 已存本机，\(out.failed) 个媒体没传上，联网后在同步任务中心点重试"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body, silent: true)
            } else {
                out.title = "房源已上传"
                out.body = "\(roomKey) 已同步到云端\(mediaSuffix)"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body)
            }
        } else {
            if out.failed > 0 {
                out.title = "修改已保存，媒体待补传"
                out.body = "\(roomKey) 的改动已存本机，\(out.failed) 个媒体没传上，联网后在同步任务中心点重试"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body, silent: true)
            } else {
                out.title = "修改已同步"
                out.body = "\(roomKey) 的改动已同步到云端\(mediaSuffix)"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body)
            }
        }
        writeMirror()
        stashInbox()
        return out
    }
}