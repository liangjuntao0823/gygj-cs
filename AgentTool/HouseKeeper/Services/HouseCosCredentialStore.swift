//
//  HouseCosCredentialStore.swift
//  公寓管家 · COS 临时凭证缓存与自动刷新
//
//  服务器签发的临时凭证约 30 分钟有效；本类缓存凭证，过期前（预留 2 分钟）自动重新拉取，
//  媒体上传统一从这里取凭证，App 内不再保存任何 COS 永久密钥。
//

import Foundation

struct HouseCosCredential {
    let secretId: String
    let secretKey: String
    let sessionToken: String
    let expiredTime: TimeInterval
    let bucket: String
    let region: String
    let prefix: String

    /// 预留 120 秒缓冲，避免临界过期导致上传中途失败
    var isValid: Bool {
        Date().timeIntervalSince1970 < expiredTime - 120
    }
}

@MainActor
final class HouseCosCredentialStore {
    static let shared = HouseCosCredentialStore()
    private var cached: HouseCosCredential?
    private var inflight: Task<HouseCosCredential, Error>?

    private init() {}

    /// 取有效凭证；并发调用复用同一个刷新任务，不会重复请求
    func credential() async throws -> HouseCosCredential {
        if let c = cached, c.isValid { return c }
        if let t = inflight { return try await t.value }
        let task = Task {
            let env = try await HouseRemoteClient.shared.fetchCosCredentials()
            let c = HouseCosCredential(
                secretId: env.credentials.secretId,
                secretKey: env.credentials.secretKey,
                sessionToken: env.credentials.token,
                expiredTime: env.credentials.expiredTime,
                bucket: env.bucket, region: env.region,
                prefix: env.prefix ?? "h/")
            cached = c
            inflight = nil
            return c
        }
        inflight = task
        return try await task.value
    }

    /// 切换账号/退出时清空，避免复用旧凭证
    func clear() {
        cached = nil
        inflight = nil
    }
}
