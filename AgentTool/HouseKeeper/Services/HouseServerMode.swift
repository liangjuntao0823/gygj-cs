//
//  HouseServerMode.swift
//  公寓管家 · 房源服务器模式总开关（灰度路由）
//
//  服务器模式开启且已接入租户令牌时，房源读写走 8082 house-keeper 权威接口；
//  否则回退旧 COS 直连链路兜底，保证任何情况下功能不丢。
//  迁移验证稳定后（P4），旧链路与本开关一并移除。
//

import Foundation

@MainActor
enum HouseServerMode {
    private static let modeKey = "house.serverMode.v1"

    /// 服务器模式开关（默认开启；可在设置页关闭以回退旧链路）
    static var enabled: Bool {
        get {
            if let v = UserDefaults.standard.object(forKey: modeKey) as? Bool { return v }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: modeKey) }
    }

    /// 是否已具备走服务器的条件：开关开 + 已接入租户令牌
    static var ready: Bool {
        enabled && MeterCloudSync.shared.hasToken
    }

    /// 未接入时给用户的引导文案
    static var notReadyReason: String {
        if !enabled { return "服务器模式已关闭" }
        return "尚未接入服务器，请到「电表监控设置」完成接入"
    }
}
