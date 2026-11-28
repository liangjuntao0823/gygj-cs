//
//  HouseServerMode.swift
//  公寓管家 · 房源服务器模式
//
//  房源读写统一走 8082 house-keeper 权威接口；未绑定账号令牌时只写本机并挂待补传，
//  绑定后在任务中心手动补传。旧对象存储直连链路已下线，不再提供本地/旧桶回退开关。
//

import Foundation

// 仅读令牌状态，无 UI 状态隔离需求；nonisolated 以便账本存储等非 MainActor 路径同步读取
enum HouseServerMode {
    /// 是否已具备走服务器的条件：已接入账号令牌
    static var ready: Bool {
        MeterCloudSync.hasPersistedToken()
    }

    /// 未接入时给用户的引导文案
    static var notReadyReason: String {
        "尚未绑定账号令牌"
    }
}
