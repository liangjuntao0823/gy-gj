//
//  HouseSyncGuard.swift
//  公寓管家 · 房源多设备同步防护（v2.39）
//
//  解决的核心问题：A 手机改完并同步后，B 手机账本还是旧的，直接进编辑页保存，
//  会把云端 A 刚写进去的新账本按字段覆盖掉（CAS 只在读-写几百毫秒窗口内有效，
//  隔几分钟的「旧数据编辑」根本绕不过去）。
//
//  防护分三道：
//  1) 进详情页自动检测（只拉该房 info.json 一个对象，不拉全量账本；15 秒内重复进入复用结果）；
//  2) 保存前强校验（不走缓存）：本地旧值 vs 云端现值逐字段比对，字段被改过就禁止保存；
//  3) 校验不了（断网/弱网）时不落正式数据，本次改动整体存草稿，联网后手动提交。
//
//  判定规则：只有「字段差异」才拦编辑；如果字段一致、仅媒体名单不同（别人只是加/删了图），
//  允许编辑保存，由 uploadGuarded 的媒体并集合并处理，避免为了加一张图也强制全量同步。
//

import Foundation
import SwiftUI
import SwiftData

// MARK: - 云端新鲜度三态

enum HouseCloudState {
    /// 云端与本地逐字段一致（媒体名单也一致）
    case fresh
    /// 字段一致，只有媒体名单差异（允许编辑，保存时自动合并）
    case mediaOnly(CloudHouseRecord)
    /// 字段有更新（禁止直接编辑/保存，必须先同步）
    case updated(CloudHouseRecord, [String])
    /// 云端没有这套房（本地独有，正常上传即可）
    case missing
    /// 检测失败（断网/弱网/权限），不等于「没有更新」
    case unknown(String)

    var hasFieldConflict: Bool {
        if case .updated = self { return true }
        return false
    }
}

// MARK: - 单房检测缓存（省流量）

/// 详情页短时间内反复进出（点开→返回→再点开）复用同一次检测结果，避免重复请求。
/// 保存前的强校验不走缓存；TTL 15 秒，窗口内即使他人写入，保存时那道校验也会兜住。
@MainActor
final class HouseFreshnessCache {
    static let shared = HouseFreshnessCache()
    private var store: [String: (at: Date, state: HouseCloudState)] = [:]
    private let ttl: TimeInterval = 15

    func get(_ roomKey: String) -> HouseCloudState? {
        guard let item = store[roomKey] else { return nil }
        guard Date().timeIntervalSince(item.at) < ttl else {
            store[roomKey] = nil
            return nil
        }
        return item.state
    }

    func set(_ roomKey: String, _ state: HouseCloudState) {
        store[roomKey] = (Date(), state)
    }

    func clear(_ roomKey: String) {
        store[roomKey] = nil
    }
}

// MARK: - 检测 / 比对 / 应用云端

enum HouseSyncGuard {

    /// 由表单字段推导媒体目录 key（与 House.mediaRoomKey、HouseEditView.currentRoomKey 同一口径）
    static func roomKey(roomNo: String, tower: Int) -> String {
        var t = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        let raw = (tower == 2 ? "2-" : "1-") + t
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\u{22}<>")
        return raw.components(separatedBy: illegal).joined(separator: "-")
    }

    /// 把表单可读成「x座xxxx」
    static func displayRoomNo(roomNo: String, tower: Int) -> String {
        var t = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        return "\(tower)座\(t)"
    }

    /// 编辑前旧值 vs 云端现值，逐字段生成人话差异（空数组 = 字段没变）
    @MainActor
    static func fieldDiffs(record: CloudHouseRecord, house: House) -> [String] {
        fieldDiffs(record: record,
                   roomNo: house.roomNo, tower: house.tower,
                   landlord: house.landlord, layout: house.layout,
                   price: house.price, password: house.password,
                   remark: house.remark, statusRaw: house.statusRaw)
    }

    /// 值类型版本（草稿比对用，不碰 SwiftData）
    static func fieldDiffs(record: CloudHouseRecord,
                           roomNo: String, tower: Int,
                           landlord: String, layout: String,
                           price: Int, password: String,
                           remark: String, statusRaw: String) -> [String] {
        var out: [String] = []
        if record.roomNo != roomNo { out.append("房号：\(roomNo) → \(record.roomNo)") }
        if record.tower != tower { out.append("座号：\(tower)座 → \(record.tower)座") }
        if record.price != price { out.append("租金：\(price) 元 → \(record.price) 元") }
        if record.landlord != landlord { out.append("房东：\(self.text(landlord)) → \(self.text(record.landlord))") }
        if record.layout != layout { out.append("户型：\(self.text(layout)) → \(self.text(record.layout))") }
        if record.password != password { out.append("密码：\(self.text(password)) → \(self.text(record.password))") }
        if record.remark != remark { out.append("备注：\(self.text(remark)) → \(self.text(record.remark))") }
        if record.status != statusRaw {
            let oldLabel = HouseStatus(rawValue: statusRaw)?.label ?? statusRaw
            let newLabel = HouseStatus(rawValue: record.status)?.label ?? record.status
            out.append("状态：\(oldLabel) → \(newLabel)")
        }
        return out
    }

    private static func text(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "（空）" : t
    }

    /// 云端有、本地没有 / 本地有、云端没有 的媒体名单
    @MainActor
    static func mediaDiff(record: CloudHouseRecord, house: House) -> (added: [String], removed: [String]) {
        let pendingKeys = Set(HouseMediaUploadQueue.pendingItems()
            .filter { $0.roomKey == record.roomKey }
            .map { MediaNaming.canonicalKey($0.fileName) })
        let localKeys = Set(house.mediaItems.map { MediaNaming.canonicalKey($0.fileName) }).subtracting(pendingKeys)
        let cloudKeys = Set(record.mediaNames.map { MediaNaming.canonicalKey($0) })
        let added = record.mediaNames.filter { !localKeys.contains(MediaNaming.canonicalKey($0)) }
        let removed = house.mediaItems.map { $0.fileName }
            .filter { !cloudKeys.contains(MediaNaming.canonicalKey($0)) && !pendingKeys.contains(MediaNaming.canonicalKey($0)) }
        return (added, removed)
    }

    /// 单房检测：只拉这一套的 info.json（约 1KB），不拉全量账本、不拉总清单。
    /// - useCache: 详情页自动检测用 true；保存前强校验必须 false。
    @MainActor
    static func check(house: House, config: CosConfig, useCache: Bool = true) async -> HouseCloudState {
        let roomKey = house.mediaRoomKey
        guard !roomKey.isEmpty else { return .unknown("房号为空") }
        if useCache, let cached = HouseFreshnessCache.shared.get(roomKey) {
            return cached
        }
        let state: HouseCloudState
        do {
            guard let rec = try await CloudHouseSync.fetchOne(roomKey: roomKey, config: config) else {
                state = .missing
                HouseFreshnessCache.shared.set(roomKey, state)
                return state
            }
            let diffs = fieldDiffs(record: rec, house: house)
            if !diffs.isEmpty {
                state = .updated(rec, diffs)
            } else {
                let md = mediaDiff(record: rec, house: house)
                if md.added.isEmpty && md.removed.isEmpty {
                    state = .fresh
                } else {
                    state = .mediaOnly(rec)
                }
            }
        } catch {
            // 网络失败绝不能当成「没有更新」——否则下一屏就是静默覆盖
            state = .unknown(error.localizedDescription)
        }
        HouseFreshnessCache.shared.set(roomKey, state)
        return state
    }

    /// 把云端记录应用到本地（字段 + 媒体补缺/删除），返回人话摘要
    @MainActor
    @discardableResult
    static func apply(record: CloudHouseRecord, to house: House, ctx: ModelContext, config: CosConfig) async throws -> String {
        var parts: [String] = []
        let diffs = fieldDiffs(record: record, house: house)
        // 字段差异直接带人话明细（如「租金：1400 元 → 1500 元」），不再只记数量
        if !diffs.isEmpty { parts.append(diffs.joined(separator: "、")) }

        house.roomNo = record.roomNo
        house.tower = record.tower
        house.landlord = record.landlord
        house.layout = record.layout
        house.price = record.price
        house.password = record.password
        house.remark = record.remark
        house.statusRaw = record.status
        house.lastUpdatedAt = record.updatedAt
        house.cloudStatus = .both

        let md = mediaDiff(record: record, house: house)
        var downloadedFiles: [(name: String, kind: String)] = []
        if !md.added.isEmpty {
            // v2.54：下载失败必须上抛，不能再用 try? 吞掉——否则本地媒体没补齐却被标记 fresh（假收敛），
            // 15 秒缓存过期后再检测又算出 added，反复提示同步。
            let files = try await CosUploader.downloadHouseMedia(roomKey: record.roomKey,
                                                                expectedNames: record.mediaNames,
                                                                config: config)
            for f in files where !house.mediaItems.contains(where: {
                MediaNaming.canonicalKey($0.fileName) == MediaNaming.canonicalKey(f.fileName)
            }) {
                let item = MediaItem(fileName: f.fileName, kind: f.kind)
                item.house = house
                ctx.insert(item)
                downloadedFiles.append((f.fileName, f.kind))
            }
            // 下载后校验：仍有云端媒体没补齐（如云端账本引用了桶里不存在的对象），明确报错，不标记 fresh
            let after = mediaDiff(record: record, house: house)
            if !after.added.isEmpty {
                throw NSError(domain: "HouseSyncGuard", code: -1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "部分云端媒体未下载成功：\(after.added.joined(separator: "、"))，请重试"])
            }
        }
        // 云端已删掉的媒体：本地记录与文件一并清掉（待上传队列里的先豁免，避免误删刚拍的图）
        let pendingKeys = Set(HouseMediaUploadQueue.pendingItems()
            .filter { $0.roomKey == record.roomKey }
            .map { MediaNaming.canonicalKey($0.fileName) })
        var removedFiles: [(name: String, kind: String)] = []
        let cloudKeys = Set(record.mediaNames.map { MediaNaming.canonicalKey($0) })
        let localItems = house.mediaItems    // 先取快照，避免边遍历边删关系数组
        for item in localItems where !cloudKeys.contains(MediaNaming.canonicalKey(item.fileName))
            && !pendingKeys.contains(MediaNaming.canonicalKey(item.fileName)) {
            ctx.delete(item)
            MediaStore.delete(fileName: item.fileName, roomKey: record.roomKey)
            removedFiles.append((item.fileName, item.kind))
        }

        try? ctx.save()
        LocalHouseLedger.save(house)
        CloudRevisionStore.remember([record.roomKey: record.revision ?? 0])
        HouseFreshnessCache.shared.set(record.roomKey, .fresh)
        UnreadCloudHouseStore.clear(record.roomKey)
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)

        if !downloadedFiles.isEmpty {
            let dl = HouseLedgerFormat.split(downloadedFiles)
            parts.append("下载" + HouseLedgerFormat.mediaSummary(images: dl.images.count, videos: dl.videos.count))
        }
        if !removedFiles.isEmpty {
            let rm = HouseLedgerFormat.split(removedFiles)
            parts.append("移除" + HouseLedgerFormat.mediaSummary(images: rm.images.count, videos: rm.videos.count))
        }
        if parts.isEmpty { parts.append("已更新到云端最新") }
        // 云端→本机的拉平动作只记本机操作区，不上云端公共日志（与批量同步「云端更新本机」口径一致）；
        // 云端公共区只保留本机→云端的写 / 删 / 补传操作。
        BackupLogStore.log(category: "同步", action: "单房更新", result: "成功",
                          detail: "\(record.roomKey)：\(parts.joined(separator: "，"))",
                          room: record.roomKey, cloud: false)
        return parts.joined(separator: "，")
    }
}

// MARK: - 草稿数据

struct HouseDraftMedia: Codable, Equatable {
    var fileName: String
    var kind: String
}

struct HouseDraftFields: Codable, Equatable {
    var roomNo: String
    var tower: Int
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var statusRaw: String
}

struct HouseDraft: Codable, Identifiable, Equatable {
    var id: String                  // UUID 字符串
    var houseID: String             // 编辑前的 House.id.uuidString
    var roomKey: String             // 目标目录 key（可能因改名与 sourceRoomKey 不同）
    var sourceRoomKey: String       // 本次新拍媒体的文件所在目录
    var fields: HouseDraftFields
    var base: HouseDraftFields      // 编辑前旧值（算改动详情 + 冲突比对）
    var addedMedia: [HouseDraftMedia]
    var removedMedia: [String]
    var baseRevision: Int64?        // 存草稿时本机看到的云端修订号
    var reason: String              // 为什么落到草稿箱
    var createdAt: Date

    var displayRoomNo: String {
        HouseSyncGuard.displayRoomNo(roomNo: fields.roomNo, tower: fields.tower)
    }

    /// 一行摘要：租金 800 → 900、房东 A → B…
    var changeSummary: String {
        let lines = changeLines
        if lines.isEmpty { return "无字段改动" }
        return lines.joined(separator: "、")
    }

    /// 逐条改动（详情页展示）
    var changeLines: [String] {
        var out: [String] = []
        if base.roomNo != fields.roomNo { out.append("房号：\(base.roomNo) → \(fields.roomNo)") }
        if base.tower != fields.tower { out.append("座号：\(base.tower)座 → \(fields.tower)座") }
        if base.price != fields.price { out.append("租金：\(base.price) 元 → \(fields.price) 元") }
        if base.landlord != fields.landlord { out.append("房东：\(text(base.landlord)) → \(text(fields.landlord))") }
        if base.layout != fields.layout { out.append("户型：\(text(base.layout)) → \(text(fields.layout))") }
        if base.password != fields.password { out.append("密码：\(text(base.password)) → \(text(fields.password))") }
        if base.remark != fields.remark { out.append("备注：\(text(base.remark)) → \(text(fields.remark))") }
        if base.statusRaw != fields.statusRaw {
            let oldLabel = HouseStatus(rawValue: base.statusRaw)?.label ?? base.statusRaw
            let newLabel = HouseStatus(rawValue: fields.statusRaw)?.label ?? fields.statusRaw
            out.append("状态：\(oldLabel) → \(newLabel)")
        }
        if !addedMedia.isEmpty { out.append("新增媒体：\(addedMedia.count) 个") }
        if !removedMedia.isEmpty { out.append("删除媒体：\(removedMedia.count) 个") }
        return out
    }

    private func text(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "（空）" : t
    }
}

// MARK: - 草稿箱持久化

final class HouseDraftStore: ObservableObject {
    static let shared = HouseDraftStore()
    static let didChange = Notification.Name("houseDraftsChanged")

    @Published private(set) var drafts: [HouseDraft] = []

    private init() { reload() }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HouseDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drafts.json")
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([HouseDraft].self, from: data) else {
            drafts = []
            return
        }
        drafts = list.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(drafts) else { return }
        try? data.write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 同一套房只留最新一份草稿（避免同一房多份互相覆盖）
    func add(_ draft: HouseDraft) {
        drafts.removeAll { $0.houseID == draft.houseID }
        drafts.insert(draft, at: 0)
        persist()
    }

    func remove(id: String) {
        drafts.removeAll { $0.id == id }
        persist()
    }

    func draft(forHouseID id: String) -> HouseDraft? {
        drafts.first { $0.houseID == id }
    }

    var count: Int { drafts.count }
}

// MARK: - 草稿提交

enum HouseDraftError: LocalizedError {
    case offline
    case cloudConfigMissing
    case cloudChanged([String])

    var errorDescription: String? {
        switch self {
        case .offline: return "网络仍不可用，草稿未提交"
        case .cloudConfigMissing: return "未配置云存储，无法提交草稿"
        case .cloudChanged(let lines):
            return "云端已有更新：" + lines.joined(separator: "、")
        }
    }
}

enum HouseDraftSubmitter {

    /// 提交一条草稿：先校验云端是否又被别人改过，再落本地 + 上传媒体 + 合并写账本。
    /// - force: 用户看过冲突提示后选择「仍然覆盖」
    @MainActor
    static func submit(draft: HouseDraft, ctx: ModelContext, force: Bool) async throws -> String {
        guard let config = CosConfig.load(), config.isValid else { throw HouseDraftError.cloudConfigMissing }
        guard await NetworkMonitor.shared.awaitReachable(timeout: 2.5) else { throw HouseDraftError.offline }

        // 1) 冲突校验：revision 变过 + 字段确实不同 → 交回用户确认
        let cloud = try await CloudHouseSync.fetchOne(roomKey: draft.roomKey, config: config)
        if let cloud, !force {
            let baseRev = draft.baseRevision ?? 0
            let nowRev = cloud.revision ?? 0
            if nowRev > baseRev {
                let diffs = HouseSyncGuard.fieldDiffs(
                    record: cloud,
                    roomNo: draft.base.roomNo, tower: draft.base.tower,
                    landlord: draft.base.landlord, layout: draft.base.layout,
                    price: draft.base.price, password: draft.base.password,
                    remark: draft.base.remark, statusRaw: draft.base.statusRaw)
                if !diffs.isEmpty { throw HouseDraftError.cloudChanged(diffs) }
            }
        }

        // 2) 找到本地房源（按 id，其次按房号）
        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        var target = all.first { $0.id.uuidString == draft.houseID }
        if target == nil {
            target = all.first { $0.mediaRoomKey == draft.roomKey && !$0.isTrashed }
        }
        guard let house = target else {
            throw NSError(domain: "HouseDraft", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "本地已找不到这套房源（可能已被删除），草稿无法提交"])
        }

        // 3) 媒体目录可能因改名而不同：先把本次新拍的文件挪到目标目录
        if !draft.sourceRoomKey.isEmpty, draft.sourceRoomKey != draft.roomKey {
            MediaStore.migrateHouseDirectory(from: draft.sourceRoomKey, to: draft.roomKey)
        }

        // 4) 字段落库
        house.roomNo = draft.fields.roomNo
        house.tower = draft.fields.tower
        house.landlord = draft.fields.landlord
        house.layout = draft.fields.layout
        house.price = draft.fields.price
        house.password = draft.fields.password
        house.remark = draft.fields.remark
        house.statusRaw = draft.fields.statusRaw
        house.lastUpdatedAt = Date()

        // 5) 媒体：删掉草稿里标记删除的，补上新增的
        for name in draft.removedMedia {
            if let item = house.mediaItems.first(where: { $0.fileName == name }) { ctx.delete(item) }
            MediaStore.delete(fileName: name, roomKey: draft.roomKey)
        }
        for m in draft.addedMedia where !house.mediaItems.contains(where: { $0.fileName == m.fileName }) {
            let item = MediaItem(fileName: m.fileName, kind: m.kind)
            item.house = house
            ctx.insert(item)
        }
        try ctx.save()
        LocalHouseLedger.save(house)

        // 6) 新增媒体上传（失败入队，不阻断账本）
        var mediaFailed = 0
        for m in draft.addedMedia {
            let url = MediaStore.url(for: m.fileName, roomKey: draft.roomKey)
            guard FileManager.default.fileExists(atPath: url.path) else {
                HouseMediaUploadQueue.enqueue(roomKey: draft.roomKey, fileName: m.fileName, kind: m.kind)
                mediaFailed += 1
                continue
            }
            do {
                try await CosUploader.uploadHouseMedia(fileName: m.fileName, kind: m.kind,
                                                       roomKey: draft.roomKey, config: config,
                                                       compress: shareCompressionEnabled)
                HouseMediaUploadQueue.remove(roomKey: draft.roomKey, fileName: m.fileName)
            } catch {
                HouseMediaUploadQueue.enqueue(roomKey: draft.roomKey, fileName: m.fileName, kind: m.kind)
                mediaFailed += 1
            }
        }

        // 7) 账本合并写（uploadGuarded 会做写前二次校验，冲突照样抛出）
        let record = CloudHouseSync.record(from: house, username: CloudUser.username)
        let (merged, _) = try await CloudHouseSync.uploadGuarded(record: record,
                                                                removedMedia: Set(draft.removedMedia),
                                                                config: config)
        house.cloudStatus = .both
        SyncFailStore.clear(draft.roomKey)
        CloudRevisionStore.remember([draft.roomKey: merged.revision ?? 0])
        try? ctx.save()

        HouseDraftStore.shared.remove(id: draft.id)
        HouseFreshnessCache.shared.set(draft.roomKey, .fresh)
        UnreadCloudHouseStore.clear(draft.roomKey)
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)

        BackupLogStore.log(category: "房源", action: "提交草稿", result: "成功",
                          detail: "\(draft.displayRoomNo)：\(draft.changeSummary)"
                            + (mediaFailed > 0 ? "；媒体 \(mediaFailed) 个待补传" : ""),
                          room: draft.roomKey, cloud: true)
        return mediaFailed > 0 ? "改动已同步；\(mediaFailed) 个媒体上传失败，已排队自动补传" : "改动已同步到云端"
    }
}

// MARK: - 草稿箱界面（详情页入口 → 列表 → 改动详情）

struct HouseDraftListView: View {
    let ctx: ModelContext
    let currentRoomKey: String

    @ObservedObject private var store = HouseDraftStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: HouseDraft?

    var body: some View {
        NavigationStack {
            List {
                if store.drafts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("草稿箱是空的")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(store.drafts) { draft in
                        Button {
                            selected = draft
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(draft.displayRoomNo)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)
                                        if draft.roomKey == currentRoomKey {
                                            Text("本房")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.themeAccent)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(draft.changeSummary)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                    Text("\(draft.createdAt.houseDraftTimeText) · \(draft.reason)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary.opacity(0.8))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.remove(id: draft.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("草稿箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .sheet(item: $selected) { draft in
            HouseDraftDetailView(ctx: ctx, draft: draft)
        }
    }
}

struct HouseDraftDetailView: View {
    let ctx: ModelContext
    @State var draft: HouseDraft

    @ObservedObject private var store = HouseDraftStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var submitting = false
    @State private var message: String?
    @State private var conflictLines: [String] = []
    @State private var showConflict = false
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section("改动详情") {
                    if draft.changeLines.isEmpty {
                        Text("本次没有字段改动")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(draft.changeLines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 14))
                                .foregroundColor(.primary)
                        }
                    }
                }

                if !draft.addedMedia.isEmpty || !draft.removedMedia.isEmpty {
                    Section("媒体变化") {
                        ForEach(draft.addedMedia, id: \.fileName) { m in
                            HStack {
                                Label("新增", systemImage: "plus.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                                Text(m.fileName)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        ForEach(draft.removedMedia, id: \.self) { name in
                            HStack {
                                Label("删除", systemImage: "minus.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                Text(name)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section("记录") {
                    LabeledContent("房号", value: draft.displayRoomNo)
                    LabeledContent("存草稿时间", value: draft.createdAt.houseDraftFullTimeText)
                    LabeledContent("原因", value: draft.reason)
                }

                Section {
                    Button {
                        Task { await submit(force: false) }
                    } label: {
                        HStack {
                            Spacer()
                            if submitting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(submitting ? "正在提交…" : "提交这次改动")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(submitting)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("删除草稿")
                            Spacer()
                        }
                    }
                    .disabled(submitting)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("草稿详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("此房云端已有更新", isPresented: $showConflict) {
                Button("仍然覆盖云端", role: .destructive) {
                    Task { await submit(force: true) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("其他人已改过这套房：\n" + conflictLines.joined(separator: "\n")
                     + "\n\n继续提交会用你的草稿覆盖对方改动。")
            }
            .alert("提交结果", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) { message = nil; dismiss() }
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog("删除这条草稿？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除草稿", role: .destructive) {
                    cleanupDraftFiles()
                    store.remove(id: draft.id)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("草稿里新拍的照片/视频文件会一并清掉，已存在房源上的媒体不受影响。")
            }
            .onChange(of: store.drafts) { _, newValue in
                // 草稿已被别处删除（例如提交成功）→ 自动关闭
                if !newValue.contains(where: { $0.id == draft.id }) { dismiss() }
            }
        }
    }

    private func submit(force: Bool) async {
        submitting = true
        defer { submitting = false }
        do {
            let msg = try await HouseDraftSubmitter.submit(draft: draft, ctx: ctx, force: force)
            message = msg
        } catch let e as HouseDraftError {
            if case .cloudChanged(let lines) = e {
                conflictLines = lines
                showConflict = true
            } else {
                message = e.localizedDescription
            }
        } catch {
            message = "提交失败：\(error.localizedDescription)"
        }
    }

    /// 删除草稿时清掉本次新拍、还没挂到房源上的媒体文件
    private func cleanupDraftFiles() {
        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        let attached = Set(all.flatMap { $0.mediaItems.map { $0.fileName } })
        for m in draft.addedMedia where !attached.contains(m.fileName) {
            MediaStore.delete(fileName: m.fileName, roomKey: draft.roomKey)
        }
    }
}

// MARK: - 时间格式

extension Date {
    var houseDraftTimeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: self)
    }

    var houseDraftFullTimeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: self)
    }
}
