import Foundation
import Security

/// 分享名片（姓名/电话）本机存取。
/// 只读写本机钥匙串，不进入服务器、不上传对象存储；分享链接生成时作为查询参数携带。
enum ShareProfileStore {
    private static let nameKey = "share.name"
    private static let phoneKey = "share.phone"

    static func load() -> (name: String, phone: String) {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let name = (KeychainStore.load(nameKey) ?? "").trimmingCharacters(in: trimSet)
        let phone = (KeychainStore.load(phoneKey) ?? "").trimmingCharacters(in: trimSet)
        return (name, phone)
    }

    @discardableResult
    static func save(name: String, phone: String) -> Bool {
        let trimSet = CharacterSet.whitespacesAndNewlines
        let n = name.trimmingCharacters(in: trimSet)
        let p = phone.trimmingCharacters(in: trimSet)
        var ok = KeychainStore.save(n, for: nameKey)
        ok = KeychainStore.save(p, for: phoneKey) && ok
        return ok
    }

    static func clear() {
        KeychainStore.delete(nameKey)
        KeychainStore.delete(phoneKey)
    }
}
