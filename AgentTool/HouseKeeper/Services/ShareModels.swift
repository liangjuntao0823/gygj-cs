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
