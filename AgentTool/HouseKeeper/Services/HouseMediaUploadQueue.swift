import Foundation

/// 房源媒体待上传队列（过渡用）：分享上传失败时入队并广播，任务中心实时并入；
/// 启动时任务中心会把残留队列一次性迁移走并清空。任务持久化在 UserDefaults（按用户名分 key）。
enum HouseMediaUploadQueue {
    struct Item: Codable, Equatable, Hashable {
        let roomKey: String
        let fileName: String
        let kind: String
    }

    /// 新条目入队时广播：任务中心收到后立即并入中心（中心为准，旧队列只做过渡）
    static let didEnqueue = Notification.Name("houseMediaQueue.didEnqueue")

    private static var pendingKey: String { "houseMediaPending.\(CloudUser.safeName)" }

    static func pendingItems() -> [Item] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Item]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }

    /// 媒体上传失败时入队（同房同文件只保留一条）
    static func enqueue(roomKey: String, fileName: String, kind: String) {
        var list = pendingItems()
        let item = Item(roomKey: roomKey, fileName: fileName, kind: kind)
        guard !list.contains(item) else { return }
        list.append(item)
        if list.count > 200 { list = Array(list.suffix(200)) }
        save(list)
        NotificationCenter.default.post(name: didEnqueue, object: nil)
    }

    static func remove(roomKey: String, fileName: String) {
        var list = pendingItems()
        list.removeAll { $0.roomKey == roomKey && $0.fileName == fileName }
        save(list)
    }

    /// 清空整个队列：任务中心 bootstrap 迁移完旧队列后调用
    static func clearAll() {
        save([])
    }

    /// v2.53：全量撤回——移除某套房在待上传队列里的全部登记
    static func removeRoom(_ roomKey: String) {
        let list = pendingItems()
        save(list.filter { $0.roomKey != roomKey })
    }
}
