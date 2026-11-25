import Foundation

// MARK: - v2.68 分享卡片值类型（原在 HouseDetailView，搬至独立文件供主 App 与分享扩展共用）

struct ShareMediaFile: Hashable, Codable {
    let name: String
    let kind: String
}

struct ShareHouseInfo: Equatable, Codable {
    let displayRoomNo: String
    let towerLabel: String
    let layout: String
    let statusLabel: String
    let priceText: String
    let landlord: String
    let password: String
    let remark: String
    let name: String?   // v1.21：分享名片姓名（设置页可编辑；Optional 兼容旧版缓存 JSON，缺失时按默认值渲染）
    let phone: String?  // v1.21：分享名片电话
}

extension ShareHouseInfo {
    /// App 内分享纯文字文案（不生成 H5 链接；名片姓名/电话来自本机钥匙串）。
    var shareText: String {
        var lines: [String] = []
        lines.append("\(towerLabel)\(displayRoomNo)")
        if !layout.isEmpty { lines.append("户型：\(layout)") }
        lines.append("状态：\(statusLabel)")
        if !priceText.isEmpty { lines.append("租金：\(priceText)") }
        if !landlord.isEmpty { lines.append("房东：\(landlord)") }
        if !password.isEmpty { lines.append("密码：\(password)") }
        if !remark.isEmpty { lines.append("备注：\(remark)") }
        if let name, !name.isEmpty {
            var contact = name
            if let phone, !phone.isEmpty { contact += " \(phone)" }
            lines.append(contact)
        }
        return lines.joined(separator: "\n")
    }
}
