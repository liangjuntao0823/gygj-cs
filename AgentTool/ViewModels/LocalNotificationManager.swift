import Foundation
import UserNotifications
import SwiftData

private struct NotificationLedgerEntry: Codable {
    let id: String
    let title: String
    let body: String
    let fireDate: Date
    let tab: Int
}

@MainActor
final class LocalNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationManager()
    static let navigationNotification = Notification.Name("localNotificationNavigation")
    private let center = UNUserNotificationCenter.current()
    private let ledgerKey = "localNotificationLedger"
    private var rebuildGeneration = 0

    /// v2.18：移除「自定义音」选项——四个场景原本共用一个 custom-notification.caf，
    /// 工程内从未打包该音频文件，选它永远回落系统音（形同虚设）。现统一使用系统默认提示音。
    private func sound(for category: String) -> UNNotificationSound {
        _ = category
        return .default
    }

    func configure() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { print("通知授权失败: \(error)") }
            print("本地通知授权: \(granted)")
        }
    }

    func rebuildAll(modelContext: ModelContext, syncTodoRemote: Bool = true) {
        rebuildGeneration += 1; let generation = rebuildGeneration
        let properties = (try? modelContext.fetch(FetchDescriptor<Property>(predicate: #Predicate { !$0.isDeleted }))) ?? []
        let payouts = (try? modelContext.fetch(FetchDescriptor<PayoutRecord>(predicate: #Predicate { !$0.isDeleted }))) ?? []
        let todos = (try? modelContext.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isDeleted }))) ?? []
        // 待办采用「远程优先、本地兜底」：远程通道可绑定且上报成功时，未来待办只由服务器 Bark 发；
        // 未绑定/开关关闭/上报失败时仍由本机排未来待办，已到点的待办始终保留本机每小时重复兜底。
        if syncTodoRemote {
            TodoReminderSync.shared.sync(todos: todos, modelContext: modelContext)
        }
        center.getPendingNotificationRequests { [weak self] existing in
            guard let self else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix("zfgj-") })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard generation == self.rebuildGeneration else { return }
                self.schedule(properties: properties, payouts: payouts, todos: todos)
            }
        }
    }

    func deliverMissedNotifications() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: ledgerKey), let ledger = try? JSONDecoder().decode([NotificationLedgerEntry].self, from: data) else { return }
        let now = Date(), cutoff = now.addingTimeInterval(-6 * 3600)
        let delivered = Set(defaults.stringArray(forKey: "deliveredLedgerIDs") ?? [])
        let missed = ledger.filter { $0.fireDate >= cutoff && $0.fireDate <= now && !delivered.contains($0.id) }
        guard !missed.isEmpty else { return }
        var updated = delivered
        for (index, entry) in missed.prefix(10).enumerated() {
            let content = UNMutableNotificationContent(); content.title = "补发：\(entry.title)"; content.body = entry.body; content.sound = sound(for: category(for: entry.title)); content.badge = 1; content.userInfo = ["tab": entry.tab]
            center.add(UNNotificationRequest(identifier: "zfgj-catchup-\(entry.id)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(index + 1), repeats: false)))
            updated.insert(entry.id)
        }
        defaults.set(Array(updated.suffix(200)), forKey: "deliveredLedgerIDs")
    }

    private func schedule(properties: [Property], payouts: [PayoutRecord], todos: [TodoItem]) {
        let todo = todoRequests(todos, skipFuture: TodoReminderSync.shared.remoteReady)
        let business = businessRequests(properties: properties, payouts: payouts)
        let selected = Array((todo + business).prefix(60))
        var ledger: [NotificationLedgerEntry] = []
        for (index, request) in selected.enumerated() {
            let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
            mutable?.badge = NSNumber(value: index + 1)
            let content = mutable ?? request.content
            let updatedRequest = UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger)
            center.add(updatedRequest) { error in if let error { print("添加通知失败: \(error)") } }
            if let item = ledgerEntry(updatedRequest) { ledger.append(item) }
        }
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: ledgerKey) }
    }

    private func businessRequests(properties: [Property], payouts: [PayoutRecord]) -> [UNNotificationRequest] {
        let calendar = Calendar.current, now = Date(), today = calendar.startOfDay(for: now)
        var result: [UNNotificationRequest] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), let fire = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: day), fire > now else { continue }
            for p in properties where !p.isTerminated {
                // 应收期直接取收租计划里最早一条未交记录，计划未覆盖的月份不催租
                if let target = p.earliestUnpaidRentRecord() {
                    let due = p.rentDueDate(of: target)
                    let days = calendar.dateComponents([.day], from: day, to: due).day ?? 99
                    if days <= 3 {
                        let body = days >= 0 ? "🟢\(p.roomNumber)房\(p.rentDueDay)号交租，还剩\(days)天，请关注！" : "🔴\(p.roomNumber)房\(p.rentDueDay)号交租，已逾期\(-days)天，请关注！"
                        result.append(request(id: "zfgj-rent-\(dateKey(day))-\(p.id)", title: "收租提醒", body: body, date: fire, tab: 3))
                    }
                }
                if let end = parseLeaseEnd(p.leaseEnd) {
                    let days = calendar.dateComponents([.day], from: day, to: end).day ?? 99
                    if days <= 7 {
                        let dueDay = calendar.component(.day, from: end)
                        let body = days >= 0 ? "🟢\(p.roomNumber)房\(dueDay)号到期，房东\(p.landlord)，还剩\(days)天，请关注！" : "🔴\(p.roomNumber)房\(dueDay)号到期，房东\(p.landlord)，已超期\(-days)天，请关注！"
                        result.append(request(id: "zfgj-expiry-\(dateKey(day))-\(p.id)", title: "租期到期提醒", body: body, date: fire, tab: 3))
                    }
                }
            }
            for payout in payouts {
                if let due = nextUnpaidPayoutDate(payout, relativeTo: day) {
                    let days = calendar.dateComponents([.day], from: day, to: due).day ?? 99
                    if days <= 3 {
                        let dueDay = calendar.component(.day, from: due)
                        let body = days >= 0 ? "🟢\(payout.roomNumber)包租房\(dueDay)号付租，还剩\(days)天，请关注！" : "🔴\(payout.roomNumber)包租房\(dueDay)号付租，已逾期\(-days)天，请关注！"
                        result.append(request(id: "zfgj-payout-\(dateKey(day))-\(payout.id)", title: "包租付租提醒", body: body, date: fire, tab: 4))
                    }
                }
            }
        }
        return result.sorted(by: requestDate)
    }

    private func todoRequests(_ todos: [TodoItem], skipFuture: Bool = false) -> [UNNotificationRequest] {
        let now = Date()
        let eligible = todos.filter {
            guard !$0.isCompleted, let date = $0.reminderDate else { return false }
            // 远程已接管未来提醒时，本机不再排未来待办，避免 Bark 与本 App 各弹一次；
            // 已过点的待办仍保留本机每小时兜底，防止服务器不可达时彻底漏提醒。
            if skipFuture && date > now { return false }
            return true
        }
        return eligible.sorted { $0.id.uuidString < $1.id.uuidString }.enumerated().map { index, item in
            let date = item.reminderDate!, content = UNMutableNotificationContent(); content.title = "待办提醒"; content.body = item.content; content.sound = sound(for: "todo"); content.badge = 1
            content.userInfo = ["tab": 0, "itemID": item.id.uuidString, "plannedAt": date.timeIntervalSince1970]
            if date <= now { return UNNotificationRequest(identifier: "zfgj-todo-hourly-\(item.id)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: true)) }
            return UNNotificationRequest(identifier: "zfgj-todo-first-\(item.id)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(2, date.timeIntervalSinceNow + Double(index)), repeats: false))
        }
    }

    private func nextUnpaidPayoutDate(_ p: PayoutRecord, relativeTo day: Date) -> Date? {
        let cal = Calendar.current; let interval: Int
        switch p.paymentMethod { case "季付": interval=3; case "半年付": interval=6; case "年付": interval=12; default: interval=1 }
        var due = p.leaseStartDate, index = 0
        while due <= p.leaseEndDate {
            let recordMonth: Int = p.paymentMethod == "季付" ? (index+1)*3 : p.paymentMethod == "半年付" ? (index+1)*6 : p.paymentMethod == "年付" ? 12 : index+1
            let paid = p.monthlyPayouts.first(where: { $0.month == recordMonth })?.isPaid ?? false
            if !paid && due >= Calendar.current.date(byAdding: .day, value: -30, to: day)! { return due }
            index += 1; due = cal.date(byAdding: .month, value: interval, to: due) ?? p.leaseEndDate.addingTimeInterval(1)
        }
        return nil
    }

    private func parseLeaseEnd(_ text:String)->Date? { let f=DateFormatter();f.dateFormat="yyyy.M.d";return f.date(from:text) }
    private func dateKey(_ date:Date)->String { let f=DateFormatter();f.dateFormat="yyyyMMdd";return f.string(from:date) }
    private func request(id:String,title:String,body:String,date:Date,tab:Int)->UNNotificationRequest { let c=UNMutableNotificationContent();c.title=title;c.body=body;c.sound = sound(for: category(for: title));c.badge=1;c.userInfo=["tab":tab,"plannedAt":date.timeIntervalSince1970];let d=Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],from:date);return UNNotificationRequest(identifier:id,content:c,trigger:UNCalendarNotificationTrigger(dateMatching:d,repeats:false)) }
    private func requestDate(_ a:UNNotificationRequest,_ b:UNNotificationRequest)->Bool { guard let x=a.trigger as? UNCalendarNotificationTrigger,let y=b.trigger as? UNCalendarNotificationTrigger,let dx=Calendar.current.date(from:x.dateComponents),let dy=Calendar.current.date(from:y.dateComponents) else{return false};return dx<dy }
    private func category(for title: String) -> String { if title.contains("收租") { return "rent" }; if title.contains("包租") { return "payout" }; if title.contains("到期") { return "expiry" }; return "todo" }
    private func ledgerEntry(_ r:UNNotificationRequest)->NotificationLedgerEntry? { guard let planned=r.content.userInfo["plannedAt"] as? Double else{return nil};let tab=r.content.userInfo["tab"] as? Int ?? 0;return NotificationLedgerEntry(id:r.identifier,title:r.content.title,body:r.content.body,fireDate:Date(timeIntervalSince1970:planned),tab:tab) }

    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping(UNNotificationPresentationOptions)->Void){completionHandler([.banner,.list,.sound])}
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping()->Void){let info=response.notification.request.content.userInfo;DispatchQueue.main.async{NotificationCenter.default.post(name:Self.navigationNotification,object:nil,userInfo:info)};completionHandler()}
}

// MARK: - 待办远程提醒同步（Bark 远程优先 / 本机本地兜底）

@MainActor
final class TodoReminderSync {
    static let shared = TodoReminderSync()
    private var syncTask: Task<Void, Never>?
    private var lastFingerprint: String?
    private var clearedWhenUnavailable = false
    /// 最近一次上报是否成功；只有成功且通道/模块开关打开时才让本机放弃未来待办本地通知
    private(set) var remoteReady = false

    private init() {}

    /// 设置页切换总开关/待办开关、绑定/解绑后调用：强制重算一次本地与远程归属。
    func refresh(modelContext: ModelContext) {
        let todos = (try? modelContext.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isDeleted }))) ?? []
        sync(todos: todos, modelContext: modelContext, force: true)
    }

    func sync(todos: [TodoItem], modelContext: ModelContext? = nil, force: Bool = false) {
        let available = NotifyHub.shared.isBound
            && NotifyHub.shared.channelEnabled
            && NotifyHub.shared.todoModuleEnabled
        guard available else {
            let wasReady = remoteReady
            remoteReady = false
            lastFingerprint = nil
            // 绑定着账号但总开关/待办开关刚关掉时，清掉服务端本设备残留，避免以后再打开时补推旧待办
            if !clearedWhenUnavailable, NotifyHub.shared.isBound {
                clearedWhenUnavailable = true
                Task { _ = await NotifyHub.shared.replaceTodoReminders([]) }
            }
            if wasReady, let modelContext {
                LocalNotificationManager.shared.rebuildAll(modelContext: modelContext, syncTodoRemote: false)
            }
            return
        }
        clearedWhenUnavailable = false

        // 只上报未来待办；已过点的交给本机每小时兜底，避免服务器补推旧提醒
        let payload = todos.compactMap { item -> [String: Any]? in
            guard !item.isCompleted, let date = item.reminderDate, date > Date() else { return nil }
            return [
                "id": item.id.uuidString,
                "dueAt": date.timeIntervalSince1970,
                "title": "待办提醒",
                "body": item.content
            ]
        }
        let fingerprint = payload.map { item -> String in
            let id = item["id"] as? String ?? ""
            let due = item["dueAt"] as? Double ?? 0
            return "\(id):\(due)"
        }.joined(separator: "|")
        if !force && fingerprint == lastFingerprint { return }

        syncTask?.cancel()
        syncTask = Task { [weak self] in
            // 合并短时间内的连续增删改，避免每次保存都打服务器
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            let error = await NotifyHub.shared.replaceTodoReminders(payload)
            guard !Task.isCancelled else { return }
            let wasReady = self.remoteReady
            self.remoteReady = (error == nil)
            if error == nil {
                self.lastFingerprint = fingerprint
            } else {
                self.lastFingerprint = nil
            }
            if wasReady != self.remoteReady, let modelContext {
                LocalNotificationManager.shared.rebuildAll(modelContext: modelContext, syncTodoRemote: false)
            }
        }
    }
}
