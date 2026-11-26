import Foundation

/// 媒体活动闸门：保证上传任务严格串行，互不并发。
actor MediaActivityGate {
    static let shared = MediaActivityGate()

    private enum Activity {
        case upload
    }

    private var active: Activity?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private func acquire(_ activity: Activity) async {
        while active != nil {
            let id = UUID()
            await withCheckedContinuation { cont in
                waiters[id] = cont
            }
        }
        active = activity
    }

    private func releaseOne() {
        active = nil
        guard let (id, cont) = waiters.first else { return }
        waiters.removeValue(forKey: id)
        cont.resume()
    }

    func beginUpload() async { await acquire(.upload) }
    func endUpload() { releaseOne() }
}
