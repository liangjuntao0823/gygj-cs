import Foundation

// MARK: - v1.12 操作日志（幂等与校验：每次备份/恢复/上传/同步记录 时间/类型/结果/校验和）
// 本地 UserDefaults 存储（v1.13 需求8：只保留最近一个月；上限 200 条），设置页可查看。

struct BackupLogEntry: Codable, Hashable {
    var date: Date
    var category: String     // 备份 / 恢复 / 上传 / 删除 / 同步 / 房源 / 成交 / 收租 / 水电 ...
    var action: String       // 快速备份 / 全量备份 / 恢复完成 / 上传成功 等
    var result: String       // 成功 / 失败
    var detail: String       // 统计摘要 / 错误信息
    var checksum: String     // sha1（zip 或 JSON 数据），失败时为空
    var username: String?    // v1.19：操作者用户名（云端/多用户操作显示是谁）
    var room: String?        // v2.47：房号（本机日志卡片与云端一致展示房号行）
}

enum BackupLogStore {
    private static let key = "backupLogs.v1"
    private static let maxCount = 500
    /// v1.13 需求8：日志只保留最近 30 天；v1.19 需求：改为 45 天
    private static let retentionDays = 45

    static func all() -> [BackupLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([BackupLogEntry].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    static func log(category: String, action: String, result: String, detail: String = "", checksum: String = "", username: String? = nil, room: String = "", cloud: Bool = false) {
        // 旧桶公共日志上行已随 COS 链路下线；操作日志只保留本机留痕（cloud 参数保留兼容旧调用）。
        writeLocal(makeEntry(category: category, action: action, result: result, detail: detail,
                             checksum: checksum, username: username, room: room))
    }

    /// 分享扩展可靠版：本地留痕同 log()。旧桶公共日志上行已随 COS 链路下线。
    static func logAwait(category: String, action: String, result: String, detail: String = "", checksum: String = "", username: String? = nil, room: String = "", cloud: Bool = false) async {
        writeLocal(makeEntry(category: category, action: action, result: result, detail: detail,
                             checksum: checksum, username: username, room: room))
    }

    private static func makeEntry(category: String, action: String, result: String, detail: String, checksum: String, username: String?, room: String) -> BackupLogEntry {
        let name = username ?? CloudUser.username
        return BackupLogEntry(date: Date(), category: category, action: action, result: result, detail: detail, checksum: checksum,
                              username: name.isEmpty ? nil : name, room: room.isEmpty ? nil : room)
    }

    private static func writeLocal(_ entry: BackupLogEntry) {
        // v2.68：扩展进程的本地日志写共享区待合并数组（扩展 standard 与主 App 隔离），
        // 主 App 启动/回前台 mergeExtensionLogs 并入本机日志；云端日志两进程走同一共享队列。
        if SharedBridge.isExtension {
            let d = SharedBridge.defaults
            var ext = (try? JSONDecoder().decode([BackupLogEntry].self, from: d.data(forKey: extPendingKey) ?? Data())) ?? []
            ext.insert(entry, at: 0)
            if ext.count > maxCount { ext = Array(ext.prefix(maxCount)) }
            if let data = try? JSONEncoder().encode(ext) {
                d.set(data, forKey: extPendingKey)
            }
            return
        }
        var list = all()
        list.insert(entry, at: 0)
        // v1.13 需求8：超过保留天数的日志自动清理
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        list = list.filter { $0.date >= cutoff }
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// v2.68：共享区扩展待合并日志键
    private static let extPendingKey = "backupLogs.extPending"

    /// v2.68：主 App 启动/回前台把分享扩展写的本地日志并入本机日志（按整条去重，幂等）。
    static func mergeExtensionLogs() {
        let d = SharedBridge.defaults
        guard let data = d.data(forKey: extPendingKey),
              let ext = try? JSONDecoder().decode([BackupLogEntry].self, from: data),
              !ext.isEmpty else { return }
        var list = all()
        let known = Set(list)
        for e in ext where !known.contains(e) {
            list.append(e)
        }
        list.sort { $0.date > $1.date }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        list = list.filter { $0.date >= cutoff }
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        if let encoded = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
        d.removeObject(forKey: extPendingKey)
    }

    /// v1.19：日志占用空间（字节），设置页展示用
    static func sizeBytes() -> Int {
        UserDefaults.standard.data(forKey: key)?.count ?? 0
    }

    /// v1.37：删除指定日志（操作日志左滑 / 多选删除）
    static func remove(_ entry: BackupLogEntry) {
        var list = all()
        list.removeAll { $0 == entry }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

