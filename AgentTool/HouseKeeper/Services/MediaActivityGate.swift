import Foundation

/// 媒体活动闸门：保证「上传/转码」与「孤儿清理」两类操作严格串行，互不并发。
/// 根因防护：上传任务可能出现「文件已传上桶、但账本 info.json 尚未写好」的时间窗，
/// 若此时孤儿清理并发扫描，会把新上传的文件误判为孤儿删除（云端突然丢某间房媒体的诱因之一）。
/// 清理进行中时，上传等待；上传进行中时，清理等待。
actor MediaActivityGate {
    static let shared = MediaActivityGate()

    private enum Activity {
        case upload
        case cleanup
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

    func beginCleanup() async { await acquire(.cleanup) }
    func endCleanup() { releaseOne() }
}
