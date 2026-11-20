import Foundation
import SwiftData

/// v2.71：分享扩展的「本地待写账」。
/// 扩展进程写不了主 App 的 SwiftData 库（房源实体在 App 容器里），此前分享新增只上云、
/// 本机没有，要回 App 从云端拉回来——用户实测嫌鸡肋。
/// 现在扩展每次入库（新增/补传/清旧换新）都把「最终云端记录 + 本次本地媒体清单 + 删除清单」
/// 写进 App Group 的 localInbox/；App 启动/回前台第一步收养：建/并房源实体、把共享区媒体
/// 搬进 Documents/media/<房号>/（否则一键备份漏媒体）、写本地账本镜像与单房账本基线、
/// 失败挂任务中心——与 App 内新增保存完全同口径，打开 App 即见，不用手动拉云端。
struct ShareLocalInboxEntry: Codable {
    struct MediaRef: Codable, Hashable {
        let name: String
        let kind: String
    }
    let id: String
    let roomKey: String
    /// 本次是全新房源（App 收养时按表单字段建实体）还是已有房补媒体（只并媒体不动字段）
    let isNewHouse: Bool
    /// 本地口径记录：含本次登记的全部媒体（成功+失败挂起），云端写失败时作本地镜像基线
    let formRecord: CloudHouseRecord
    /// 云端合并写成功后的最终记录（nil = 本次云端账本写失败）
    let cloudRecord: CloudHouseRecord?
    /// 本次登记的媒体文件（已在共享区落盘）
    let localMedia: [MediaRef]
    /// 本次显式清掉的旧媒体名（清旧换新才有）
    let removed: [String]
    /// 清旧时云端删除失败的文件名（App 收养时挂任务中心待重试）
    let failedDeletes: [String]
    let cloudOK: Bool
    let ledgerSynced: Bool
    let date: Date
}

enum ShareLocalInbox {
    static var directory: URL? {
        guard let base = SharedBridge.containerURL else { return nil }
        let dir = base.appendingPathComponent("localInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 扩展侧：一次分享入库写一条（幂等文件名=entry.id）
    static func write(_ entry: ShareLocalInboxEntry) {
        guard let dir = directory, let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: dir.appendingPathComponent("\(entry.id).json"), options: .atomic)
    }

    static func pendingEntries() -> [ShareLocalInboxEntry] {
        guard let dir = directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url -> ShareLocalInboxEntry? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ShareLocalInboxEntry.self, from: data)
            }
            .sorted { $0.date < $1.date }
    }

    static func remove(_ entry: ShareLocalInboxEntry) {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(entry.id).json"))
    }

    /// App 侧：启动/回前台收养全部待写账。返回收养条数。
    /// 顺序保证：媒体搬移 → 实体建/并 → 镜像/账本基线 → 失败挂任务中心 → 删 inbox 文件 → 统一 save。
    @MainActor
    static func adoptAll(houseContext: ModelContext) -> Int {
        let entries = pendingEntries()
        guard !entries.isEmpty else { return 0 }
        let all = (try? houseContext.fetch(FetchDescriptor<House>())) ?? []
        var byKey: [String: House] = [:]
        for h in all where !h.isTrashed { byKey[h.mediaRoomKey] = h }
        var adopted = 0
        for entry in entries {
            let rk = entry.roomKey
            let destDir = MediaStore.houseDirectory(roomKey: rk)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let sharedHouseDir = MediaStore.sharedMediaDirectory?
                .appendingPathComponent(rk, isDirectory: true)

            // 1) 媒体：共享区 → App Documents（同名已存在则只清共享副本，内容以先落盘者为准）
            for ref in entry.localMedia {
                guard let src = sharedHouseDir?.appendingPathComponent(ref.name) else { continue }
                let dst = destDir.appendingPathComponent(ref.name)
                if FileManager.default.fileExists(atPath: src.path) {
                    if !FileManager.default.fileExists(atPath: dst.path) {
                        try? FileManager.default.copyItem(at: src, to: dst)
                    }
                    try? FileManager.default.removeItem(at: src)
                }
            }

            // 2) 房源实体：没有就按表单字段建（与 App 内新增同口径），有则只并媒体清单
            let house: House
            if let h = byKey[rk] {
                house = h
            } else {
                let rec = entry.formRecord
                let h = House(roomNo: rec.roomNo, tower: rec.tower, landlord: rec.landlord,
                              layout: rec.layout, price: rec.price, password: rec.password,
                              remark: rec.remark, status: HouseStatus(rawValue: rec.status) ?? .available)
                houseContext.insert(h)
                house = h
                byKey[rk] = h
            }
            var names = Set(house.mediaItems.map { $0.fileName })
            for ref in entry.localMedia where !names.contains(ref.name) {
                house.mediaItems.append(MediaItem(fileName: ref.name, kind: ref.kind))
                names.insert(ref.name)
            }
            if !entry.removed.isEmpty {
                let removedSet = Set(entry.removed)
                house.mediaItems.removeAll { removedSet.contains($0.fileName) }
                for name in entry.removed { MediaStore.delete(fileName: name, roomKey: rk) }
            }
            house.lastUpdatedAt = (entry.cloudRecord ?? entry.formRecord).updatedAt
            house.cloudStatus = entry.cloudOK ? .both : .local
            house.updatedAt = Date()

            // 3) 本地账本镜像 info.json（与云端同构）：同步对账基线，防 Guard 误报云端有更新
            let mirror = entry.cloudRecord ?? entry.formRecord
            if let data = try? JSONEncoder().encode(mirror) {
                try? data.write(to: destDir.appendingPathComponent("info.json"), options: .atomic)
            }

            // 4) 单房账本：扩展已同步成功的，共享区正式 ledger.json 按 id 去重并入本地正式；
            //    未同步的接管共享待同步事件 + 标脏，App 启动同步链路自动补推
            if let ledgerURL = sharedHouseDir?.appendingPathComponent("ledger.json"),
               let data = try? Data(contentsOf: ledgerURL),
               let file = try? JSONDecoder().decode(HouseLedgerFile.self, from: data) {
                _ = HouseLedgerStore.mergeAndSave(roomKey: rk, events: file.events)
                try? FileManager.default.removeItem(at: ledgerURL)
            }
            HouseLedgerStore.adoptSharedPending(roomKey: rk)
            if !entry.ledgerSynced { HouseLedgerStore.markDirty(rk) }

            // 5) 失败口径与 App 内一致：账本推送失败标 SyncFail（任务中心挂推送任务）、
            //    清旧删云失败挂 mediaDelete 待重试
            #if !APP_EXTENSION
            if !entry.cloudOK { SyncFailStore.mark(rk) }
            if !entry.failedDeletes.isEmpty {
                SyncTaskCenter.shared.reportFailure(
                    kind: .mediaDelete,
                    title: "删云端媒体",
                    roomKeys: [rk],
                    failure: "\(rk) 有 \(entry.failedDeletes.count) 个媒体没从云端删掉；点重试",
                    files: entry.failedDeletes)
            }
            #endif

            remove(entry)
            adopted += 1
        }
        try? houseContext.save()
        return adopted
    }
}