//
//  HouseSyncGuard.swift
//  公寓管家 · 房源编辑草稿（断网/弱网时本地暂存）
//
//  旧版云端同步守卫（三态检测、新鲜度缓存、字段比对、云端覆盖应用）随旧桶链路下线已移除；
//  本文件现仅保留编辑页断网存草稿所需的数据结构与草稿箱持久化，待阶段 B 编排收口后迁移。
//

import Foundation
import SwiftUI

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
        var t = fields.roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        return "\(fields.tower)座\(t)"
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
