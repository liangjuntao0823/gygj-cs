import Foundation
import SwiftData
import SwiftUI

@Model
final class Property {
    var id: UUID
    var roomNumber: String
    var landlord: String
    var unitType: String
    var rent: Double
    var deposit: Double
    var prepayment: Double
    var leaseStart: String
    var leaseEnd: String
    var leaseDuration: String
    var rentDueDay: Int // 1-31
    var waterMeterBase: Int
    var electricMeterBase: Int
    var propertyType: String // 管理, 包租, 托管
    var monthlyRentRecords: [RentMonthRecord]
    var quarterlyUtilityRecords: [UtilityQuarterRecord]
    var utilitySettlementFrequency: String = "quarterly"
    var utilitySettlementRecords: [UtilitySettlementRecord] = []
    var notes: String
    var createdAt: Date
    var isTerminated: Bool = false
    var terminationDate: Date?
    var terminationReason: String = ""
    var depositRefundStatus: String = ""
    var roomDamageStatus: String = ""
    var utilitySettlementStatus: String = ""
    var terminationPerson: String = ""
    var terminationPhone: String = ""
    var isDeleted: Bool = false
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), roomNumber: String = "", landlord: String = "", unitType: String = "",
         rent: Double = 0, deposit: Double = 0, prepayment: Double = 0,
         leaseStart: String = "", leaseEnd: String = "", leaseDuration: String = "",
         rentDueDay: Int = 1, waterMeterBase: Int = 0, electricMeterBase: Int = 0,
         propertyType: String = "管理", notes: String = "", isTerminated: Bool = false,
         terminationDate: Date? = nil, terminationReason: String = "",
         depositRefundStatus: String = "", roomDamageStatus: String = "",
         utilitySettlementStatus: String = "", terminationPerson: String = "",
         terminationPhone: String = "") {
        self.id = id
        self.roomNumber = roomNumber
        self.landlord = landlord
        self.unitType = unitType
        self.rent = rent
        self.deposit = deposit
        self.prepayment = prepayment
        self.leaseStart = leaseStart
        self.leaseEnd = leaseEnd
        self.leaseDuration = leaseDuration
        self.rentDueDay = rentDueDay
        self.waterMeterBase = waterMeterBase
        self.electricMeterBase = electricMeterBase
        self.propertyType = propertyType
        self.monthlyRentRecords = []
        self.quarterlyUtilityRecords = []
        self.utilitySettlementFrequency = "quarterly"
        self.utilitySettlementRecords = []
        self.notes = notes
        self.createdAt = Date()
        self.isTerminated = isTerminated
        self.terminationDate = terminationDate
        self.terminationReason = terminationReason
        self.depositRefundStatus = depositRefundStatus
        self.roomDamageStatus = roomDamageStatus
        self.utilitySettlementStatus = utilitySettlementStatus
        self.terminationPerson = terminationPerson
        self.terminationPhone = terminationPhone
    }

    var building: String {
        roomNumber.hasPrefix("2-") ? "2座" : "1座"
    }

    var isManaged: Bool {
        propertyType == "包租" || propertyType == "托管"
    }

    // 统一显示名称（旧数据"普通"映射为"管理"）
    var typeDisplayName: String {
        propertyType == "普通" ? "管理" : propertyType
    }

    // 类型对应的单字
    var typeChar: String {
        switch typeDisplayName {
        case "包租": return "包"
        case "托管": return "托"
        default: return "管"
        }
    }

    // 类型对应的颜色
    var typeColor: Color {
        switch typeDisplayName {
        case "包租": return Color(hex: "7B61FF")
        case "托管": return Color(hex: "E09A2F")
        default: return Color(hex: "0FA48B")
        }
    }

    // 类型对应的浅色背景
    var typeBgColor: Color {
        switch typeDisplayName {
        case "包租": return Color(hex: "F0EDFF")
        case "托管": return Color(hex: "FBF1DE")
        default: return Color(hex: "E2F4EF")
        }
    }
}

@Model
final class RentMonthRecord {
    var id: UUID
    var year: Int // 年份，如2026
    var month: Int // 1-12
    var amount: Double
    var isPaid: Bool
    var paidDate: Date?

    init(id: UUID = UUID(), year: Int, month: Int, amount: Double = 0, isPaid: Bool = false) {
        self.id = id
        self.year = year
        self.month = month
        self.amount = amount
        self.isPaid = isPaid
        self.paidDate = nil
    }
}

@Model
final class UtilityQuarterRecord {
    var id: UUID
    var quarter: Int // 1-4
    var electricAmount: Double
    var waterAmount: Double
    var isSettled: Bool

    init(id: UUID = UUID(), quarter: Int, electricAmount: Double = 0, waterAmount: Double = 0, isSettled: Bool = false) {
        self.id = id
        self.quarter = quarter
        self.electricAmount = electricAmount
        self.waterAmount = waterAmount
        self.isSettled = isSettled
    }

    var total: Double { electricAmount + waterAmount }
}



@Model
final class UtilitySettlementRecord {
    var id: UUID
    var year: Int
    var period: Int
    var frequency: String
    var electricAmount: Double
    var waterAmount: Double
    var balance: Double
    var isSettled: Bool
    var statement: String
    var settledAt: Date?
    var dueDate: Date?
    init(id: UUID = UUID(), year: Int, period: Int, frequency: String, electricAmount: Double = 0, waterAmount: Double = 0, balance: Double = 0, isSettled: Bool = false, statement: String = "", settledAt: Date? = nil, dueDate: Date? = nil) { self.id=id;self.year=year;self.period=period;self.frequency=frequency;self.electricAmount=electricAmount;self.waterAmount=waterAmount;self.balance=balance;self.isSettled=isSettled;self.statement=statement;self.settledAt=settledAt;self.dueDate=dueDate }
}

@Model
final class TodoItem {
    var id: UUID
    var content: String
    var createdDate: Date
    var isCompleted: Bool
    var completedDate: Date?
    var sortOrder: Int
    var reminderDate: Date?
    var isDeleted: Bool = false
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), content: String = "", createdDate: Date = Date(), isCompleted: Bool = false,
         completedDate: Date? = nil, sortOrder: Int = 0, reminderDate: Date? = nil,
         isDeleted: Bool = false, deletedAt: Date? = nil) {
        self.id = id
        self.content = content
        self.createdDate = createdDate
        self.isCompleted = isCompleted
        self.completedDate = completedDate
        self.sortOrder = sortOrder
        self.reminderDate = reminderDate
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }
}


// MARK: - 收租计划口径统一入口
/// 所有「应收期 / 已收未收 / 提醒」判定都只认 monthlyRentRecords 这份计划：
/// 计划未覆盖的月份（首期之前、租期结束之后）一律不虚构应收期，计划对则状态与提醒都不会错。
extension Property {
    /// 收租计划按年-月排序
    var sortedRentRecords: [RentMonthRecord] {
        monthlyRentRecords.sorted { $0.year != $1.year ? $0.year < $1.year : $0.month < $1.month }
    }

    /// 计划内最早一条未交记录；全部收齐返回 nil（不再用当前日历月反推）
    func earliestUnpaidRentRecord() -> RentMonthRecord? {
        sortedRentRecords.first { !$0.isPaid }
    }

    /// 某期应收日：交租日收敛到当月最后一天（沿用 v2.19 口径）
    func rentDueDate(of record: RentMonthRecord) -> Date {
        let cal = Calendar.current
        var monthFirst = DateComponents()
        monthFirst.year = record.year
        monthFirst.month = record.month
        monthFirst.day = 1
        let first = cal.date(from: monthFirst) ?? Date()
        let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 31
        var comps = DateComponents()
        comps.year = record.year
        comps.month = record.month
        comps.day = min(max(rentDueDay, 1), daysInMonth)
        return cal.date(from: comps) ?? first
    }

    /// 计划内截至当前月仍未交的记录（不含计划未覆盖的月份）
    func outstandingRecords(upTo date: Date = Date()) -> [RentMonthRecord] {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        return sortedRentRecords.filter { !$0.isPaid && ($0.year < y || ($0.year == y && $0.month <= m)) }
    }

    /// 收租卡片已收/未收状态：下一期交租日前 3 天转为未收；首期晚于当前月时按首期是否已交判定
    var isPaidForCard: Bool {
        let cal = Calendar.current
        let now = Date()
        let cy = cal.component(.year, from: now)
        let cm = cal.component(.month, from: now)
        let sorted = sortedRentRecords
        guard !sorted.isEmpty else { return false }

        // 计划内今天及以前仍有未交 → 逾期，待收
        let outstandingNow = sorted.contains { !$0.isPaid && ($0.year < cy || ($0.year == cy && $0.month <= cm)) }
        if outstandingNow { return false }

        let hasRecordUpToNow = sorted.contains { $0.year < cy || ($0.year == cy && $0.month <= cm) }
        if !hasRecordUpToNow {
            // 计划尚未到当前月（首期在未来）：首期未交 → 待收；首期已交 → 已收
            return sorted.first!.isPaid
        }

        guard let next = sorted.first(where: { !$0.isPaid }) else { return true }
        let nextDue = rentDueDate(of: next)
        let days = cal.dateComponents([.day], from: now, to: nextDue).day ?? 0
        // 距离下一期交租日 <= 3 天（含已逾期）→ 显示未收
        return days > 3
    }
}
