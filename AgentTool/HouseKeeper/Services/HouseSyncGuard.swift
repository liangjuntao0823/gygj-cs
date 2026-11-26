//
//  HouseSyncGuard.swift
//  公寓管家 · 房源多设备同步防护（v2.39）
//
//  解决的核心问题：A 手机改完并同步后，B 手机账本还是旧的，直接进编辑页保存，
//  会把云端 A 刚写进去的新账本按字段覆盖掉（CAS 只在读-写几百毫秒窗口内有效，
//  隔几分钟的「旧数据编辑」根本绕不过去）。
//
//  防护分三道：
//  1) 进详情页自动检测（只拉该房 info.json 一个对象，不拉全量账本；15 秒内重复进入复用结果）；
//  2) 保存前强校验（不走缓存）：本地旧值 vs 云端现值逐字段比对，字段被改过就禁止保存；
//  3) 校验不了（断网/弱网）时不落正式数据，本次改动整体存草稿，联网后手动提交。
//
//  判定规则：只有「字段差异」才拦编辑；如果字段一致、仅媒体名单不同（别人只是加/删了图），
//  允许编辑保存，由 uploadGuarded 的媒体并集合并处理，避免为了加一张图也强制全量同步。
//

import Foundation
import SwiftUI
import SwiftData

// MARK: - 云端新鲜度三态

enum HouseCloudState {
    /// 云端与本地逐字段一致（媒体名单也一致）
    case fresh
    /// 字段一致，只有媒体名单差异（允许编辑，保存时自动合并）
    case mediaOnly(CloudHouseRecord)
    /// 字段有更新（禁止直接编辑/保存，必须先同步）
    case updated(CloudHouseRecord, [String])
    /// 云端没有这套房（本地独有，正常上传即可）
    case missing
    /// 检测失败（断网/弱网/权限），不等于「没有更新」
    case unknown(String)

    var hasFieldConflict: Bool {
        if case .updated = self { return true }
        return false
    }
}

// MARK: - 单房检测缓存（省流量）

/// 详情页短时间内反复进出（点开→返回→再点开）复用同一次检测结果，避免重复请求。
/// 保存前的强校验不走缓存；TTL 15 秒，窗口内即使他人写入，保存时那道校验也会兜住。
@MainActor
final class HouseFreshnessCache {
    static let shared = HouseFreshnessCache()
    private var store: [String: (at: Date, state: HouseCloudState)] = [:]
    private let ttl: TimeInterval = 15

    func get(_ roomKey: String) -> HouseCloudState? {
        guard let item = store[roomKey] else { return nil }
        guard Date().timeIntervalSince(item.at) < ttl else {
            store[roomKey] = nil
            return nil
        }
        return item.state
    }

    func set(_ roomKey: String, _ state: HouseCloudState) {
        store[roomKey] = (Date(), state)
    }

    func clear(_ roomKey: String) {
        store[roomKey] = nil
    }
}

// MARK: - 检测 / 比对 / 应用云端

enum HouseSyncGuard {

    /// 由表单字段推导媒体目录 key（与 House.mediaRoomKey、HouseEditView.currentRoomKey 同一口径）
    static func roomKey(roomNo: String, tower: Int) -> String {
        var t = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        let raw = (tower == 2 ? "2-" : "1-") + t
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\u{22}<>")
        return raw.components(separatedBy: illegal).joined(separator: "-")
    }

    /// 把表单可读成「x座xxxx」
    static func displayRoomNo(roomNo: String, tower: Int) -> String {
        var t = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        return "\(tower)座\(t)"
    }

    /// 编辑前旧值 vs 云端现值，逐字段生成人话差异（空数组 = 字段没变）
    @MainActor
    static func fieldDiffs(record: CloudHouseRecord, house: House) -> [String] {
        fieldDiffs(record: record,
                   roomNo: house.roomNo, tower: house.tower,
                   landlord: house.landlord, layout: house.layout,
                   price: house.price, password: house.password,
                   remark: house.remark, statusRaw: house.statusRaw)
    }

    /// 值类型版本（草稿比对用，不碰 SwiftData）
    static func fieldDiffs(record: CloudHouseRecord,
                           roomNo: String, tower: Int,
                           landlord: String, layout: String,
                           price: Int, password: String,
                           remark: String, statusRaw: String) -> [String] {
        var out: [String] = []
        if record.roomNo != roomNo { out.append("房号：\(roomNo) → \(record.roomNo)") }
        if record.tower != tower { out.append("座号：\(tower)座 → \(record.tower)座") }
        if record.price != price { out.append("租金：\(price) 元 → \(record.price) 元") }
        if record.landlord != landlord { out.append("房东：\(self.text(landlord)) → \(self.text(record.landlord))") }
        if record.layout != layout { out.append("户型：\(self.text(layout)) → \(self.text(record.layout))") }
        if record.password != password { out.append("密码：\(self.text(password)) → \(self.text(record.password))") }
        if record.remark != remark { out.append("备注：\(self.text(remark)) → \(self.text(record.remark))") }
        if record.status != statusRaw {
            let oldLabel = HouseStatus(rawValue: statusRaw)?.label ?? statusRaw
            let newLabel = HouseStatus(rawValue: record.status)?.label ?? record.status
            out.append("状态：\(oldLabel) → \(newLabel)")
        }
        return out
    }

    private static func text(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "（空）" : t
    }

    /// 云端有、本地没有 / 本地有、云端没有 的媒体名单
    @MainActor
    static func mediaDiff(record: CloudHouseRecord, house: House) -> (added: [String], removed: [String]) {
        let pendingKeys = Set(HouseMediaUploadQueue.pendingItems()
            .filter { $0.roomKey == record.roomKey }
            .map { MediaNaming.canonicalKey($0.fileName) })
        let localKeys = Set(house.mediaItems.map { MediaNaming.canonicalKey($0.fileName) }).subtracting(pendingKeys)
        let cloudKeys = Set(record.mediaNames.map { MediaNaming.canonicalKey($0) })
        let added = record.mediaNames.filter { !localKeys.contains(MediaNaming.canonicalKey($0)) }
        let removed = house.mediaItems.map { $0.fileName }
            .filter { !cloudKeys.contains(MediaNaming.canonicalKey($0)) && !pendingKeys.contains(MediaNaming.canonicalKey($0)) }
        return (added, removed)
    }

    /// 单房检测：只拉这一套的 info.json（约 1KB），不拉全量账本、不拉总清单。
    /// - useCache: 详情页自动检测用 true；保存前强校验必须 false。
    @MainActor
    static func check(house: House, config: CosConfig, useCache: Bool = true) async -> HouseCloudState {
        let roomKey = house.mediaRoomKey
        guard !roomKey.isEmpty else { return .unknown("房号为空") }
        if useCache, let cached = HouseFreshnessCache.shared.get(roomKey) {
            return cached
        }
        let state: HouseCloudState
        do {
            guard let rec = try await CloudHouseSync.fetchOne(roomKey: roomKey, config: config) else {
                state = .missing
                HouseFreshnessCache.shared.set(roomKey, state)
                return state
            }
            let diffs = fieldDiffs(record: rec, house: house)
            if !diffs.isEmpty {
                state = .updated(rec, diffs)
            } else {
                let md = mediaDiff(record: rec, house: house)
                if md.added.isEmpty && md.removed.isEmpty {
                    state = .fresh
                } else {
                    state = .mediaOnly(rec)
                }
            }
        } catch {
            // 网络失败绝不能当成「没有更新」——否则下一屏就是静默覆盖
            state = .unknown(error.localizedDescription)
        }
        HouseFreshnessCache.shared.set(roomKey, state)
        return state
    }

    /// 把云端记录应用到本地（字段 + 媒体补缺/删除），返回人话摘要
    @MainActor
    @discardableResult
    static func apply(record: CloudHouseRecord, to house: House, ctx: ModelContext, config: CosConfig) async throws -> String {
        var parts: [String] = []
        let diffs = fieldDiffs(record: record, house: house)
        // 字段差异直接带人话明细（如「租金：1400 元 → 1500 元」），不再只记数量
        if !diffs.isEmpty { parts.append(diffs.joined(separator: "、")) }

        house.roomNo = record.roomNo
        house.tower = record.tower
        house.landlord = record.landlord
        house.layout = record.layout
        house.price = record.price
        house.password = record.password
        house.remark = record.remark
        house.statusRaw = record.status
        house.lastUpdatedAt = record.updatedAt
        house.cloudStatus = .both

        let md = mediaDiff(record: record, house: house)
        var downloadedFiles: [(name: String, kind: String)] = []
        if !md.added.isEmpty {
            // v2.54：下载失败必须上抛，不能再用 try? 吞掉——否则本地媒体没补齐却被标记 fresh（假收敛），
            // 15 秒缓存过期后再检测又算出 added，反复提示同步。
            let files = try await CosUploader.downloadHouseMedia(roomKey: record.roomKey,
                                                                expectedNames: record.mediaNames,
                                                                config: config)
            for f in files where !house.mediaItems.contains(where: {
                MediaNaming.canonicalKey($0.fileName) == MediaNaming.canonicalKey(f.fileName)
            }) {
                let item = MediaItem(fileName: f.fileName, kind: f.kind)
                item.house = house
                ctx.insert(item)
                downloadedFiles.append((f.fileName, f.kind))
            }
            // 下载后校验：仍有云端媒体没补齐（如云端账本引用了桶里不存在的对象），明确报错，不标记 fresh
            let after = mediaDiff(record: record, house: house)
            if !after.added.isEmpty {
                throw NSError(domain: "HouseSyncGuard", code: -1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "部分云端媒体未下载成功：\(after.added.joined(separator: "、"))，请重试"])
            }
        }
        // 云端已删掉的媒体：本地记录与文件一并清掉（待上传队列里的先豁免，避免误删刚拍的图）
        let pendingKeys = Set(HouseMediaUploadQueue.pendingItems()
            .filter { $0.roomKey == record.roomKey }
            .map { MediaNaming.canonicalKey($0.fileName) })
        var removedFiles: [(name: String, kind: String)] = []
        let cloudKeys = Set(record.mediaNames.map { MediaNaming.canonicalKey($0) })
        let localItems = house.mediaItems    // 先取快照，避免边遍历边删关系数组
        for item in localItems where !cloudKeys.contains(MediaNaming.canonicalKey(item.fileName))
            && !pendingKeys.contains(MediaNaming.canonicalKey(item.fileName)) {
            ctx.delete(item)
            MediaStore.delete(fileName: item.fileName, roomKey: record.roomKey)
            removedFiles.append((item.fileName, item.kind))
        }

        try? ctx.save()
        LocalHouseLedger.save(house)
        CloudRevisionStore.remember([record.roomKey: record.revision ?? 0])
        HouseFreshnessCache.shared.set(record.roomKey, .fresh)
        UnreadCloudHouseStore.clear(record.roomKey)
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)

        if !downloadedFiles.isEmpty {
            let dl = HouseLedgerFormat.split(downloadedFiles)
            parts.append("下载" + HouseLedgerFormat.mediaSummary(images: dl.images.count, videos: dl.videos.count))
        }
        if !removedFiles.isEmpty {
            let rm = HouseLedgerFormat.split(removedFiles)
            parts.append("移除" + HouseLedgerFormat.mediaSummary(images: rm.images.count, videos: rm.videos.count))
        }
        if parts.isEmpty { parts.append("已更新到云端最新") }
        // 云端→本机的拉平动作只记本机操作区，不上云端公共日志（与批量同步「云端更新本机」口径一致）；
        // 云端公共区只保留本机→云端的写 / 删 / 补传操作。
        BackupLogStore.log(category: "同步", action: "单房更新", result: "成功",
                          detail: "\(record.roomKey)：\(parts.joined(separator: "，"))",
                          room: record.roomKey, cloud: false)
        return parts.joined(separator: "，")
    }
}

// MARK: - 草稿数据

struct HouseDraftMedia: Codable, Equatable {
    var fileName: String
    var kind: String
}

struct HouseDraftFields: Codable, Equatable {
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var statusRaw: String
}

struct HouseDraft: Codable, Identifiable, Equatable {
    var id: String                  // UUID 字符串
    var houseID: String             // 编辑前的 House.id.uuidString
    var roomKey: String             // 目标目录 key（可能因改名与 sourceRoomKey 不同）
    var sourceRoomKey: String       // 本次新拍媒体的文件所在目录
    var fields: HouseDraftFields
    var base: HouseDraftFields      // 编辑前旧值（算改动详情 + 冲突比对）
    var addedMedia: [HouseDraftMedia]
    var removedMedia: [String]
    var baseRevision: Int64?        // 存草稿时本机看到的云端修订号
    var reason: String              // 为什么落到草稿箱
    var createdAt: Date

    var displayRoomNo: String {
        HouseSyncGuard.displayRoomNo(roomNo: fields.roomNo, tower: fields.tower)
    }

    /// 一行摘要：租金 800 → 900、房东 A → B…
    var changeSummary: String {
        let lines = changeLines
        if lines.isEmpty { return "无字段改动" }
        return lines.joined(separator: "、")
    }

    /// 逐条改动（详情页展示）
    var changeLines: [String] {
        var out: [String] = []
        if base.roomNo != fields.roomNo { out.append("房号：\(base.roomNo) → \(fields.roomNo)") }
        if base.tower != fields.tower { out.append("座号：\(base.tower)座 → \(fields.tower)座") }
        if base.price != fields.price { out.append("租金：\(base.price) 元 → \(fields.price) 元") }
        if base.landlord != fields.landlord { out.append("房东：\(text(base.landlord)) → \(text(fields.landlord))") }
        if base.layout != fields.layout { out.append("户型：\(text(base.layout)) → \(text(fields.layout))") }
        if base.password != fields.password { out.append("密码：\(text(base.password)) → \(text(fields.password))") }
        if base.remark != fields.remark { out.append("备注：\(text(base.remark)) → \(text(fields.remark))") }
        if base.statusRaw != fields.statusRaw {
            let oldLabel = HouseStatus(rawValue: base.statusRaw)?.label ?? base.statusRaw
            let newLabel = HouseStatus(rawValue: fields.statusRaw)?.label ?? fields.statusRaw
            out.append("状态：\(oldLabel) → \(newLabel)")
        }
        if !addedMedia.isEmpty { out.append("新增媒体：\(addedMedia.count) 个") }
        if !removedMedia.isEmpty { out.append("删除媒体：\(removedMedia.count) 个") }
        return out
    }

    private func text(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "（空）" : t
    }
}

// MARK: - 草稿箱持久化

final class HouseDraftStore: ObservableObject {
    static let shared = HouseDraftStore()
    static let didChange = Notification.Name("houseDraftsChanged")

    @Published private(set) var drafts: [HouseDraft] = []

    private init() { reload() }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HouseDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drafts.json")
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([HouseDraft].self, from: data) else {
            drafts = []
            return
        }
        drafts = list.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(drafts) else { return }
        try? data.write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 同一套房只留最新一份草稿（避免同一房多份互相覆盖）
    func add(_ draft: HouseDraft) {
        drafts.removeAll { $0.houseID == draft.houseID }
        drafts.insert(draft, at: 0)
        persist()
    }

    func remove(id: String) {
        drafts.removeAll { $0.id == id }
        persist()
    }

    func draft(forHouseID id: String) -> HouseDraft? {
        drafts.first { $0.houseID == id }
    }

    var count: Int { drafts.count }
}
