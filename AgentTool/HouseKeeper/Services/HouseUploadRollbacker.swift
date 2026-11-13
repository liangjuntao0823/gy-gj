import Foundation
import SwiftData

/// v2.53：房源上传任务「彻底取消」的全量撤回执行器。
/// 目标：把本次任务涉及的账本改动与媒体改动（本地 + 云端、已传 + 未传）全部删除并恢复原样；
/// 撤回只写操作日志（BackupLog），不写单套房账本（HouseLedger）。
/// 全部在主线程执行（操作 ModelContext），云端可重试错误会让任务回到待处理、可再次撤回；
/// 数据确实已不存在（如云端 404）只记 warning，不假装恢复成功。
@MainActor
enum HouseUploadRollbacker {

    struct Result {
        var failed = false
        var errorText = ""
        var warnings: [String] = []
    }

    // MARK: 入口

    static func revoke(_ record: TaskRecord,
                       payload: HouseUploadRollback,
                       ctx: ModelContext) async -> Result {
        switch payload.scene {
        case .newHouse:
            return await revokeNewHouse(payload, ctx: ctx)
        case .plainEdit:
            return await revokePlainEdit(payload, ctx: ctx)
        case .rename:
            return await revokeRename(payload, ctx: ctx)
        }
    }

    // MARK: 通用工具

    /// 视频在云端存为 .mp4，图片保持原名
    private static func remoteName(_ ref: HouseUploadMediaRef) -> String {
        guard ref.kind == "video" else { return ref.fileName }
        let base = (ref.fileName as NSString).deletingPathExtension
        return base + ".mp4"
    }

    private static func findHouse(roomKey: String, ctx: ModelContext) -> House? {
        let houses = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        return houses.first { $0.mediaRoomKey == roomKey }
    }

    private static func restoreFields(house: House, before: HouseUploadBeforeSnapshot) {
        house.roomNo = before.roomNo
        house.tower = before.tower
        house.landlord = before.landlord
        house.layout = before.layout
        house.price = before.price
        house.password = before.password
        house.remark = before.remark
        house.statusRaw = before.statusRaw
    }

    /// 从云端下载恢复被删媒体并重建 MediaItem。
    /// 404（云端也没有，数据真没了）记 warning；网络/写盘等可重试错误记 cloudErrors。
    private static func restoreRemoved(roomKey: String,
                                      refs: [HouseUploadMediaRef],
                                      house: House,
                                      ctx: ModelContext,
                                      config: CosConfig,
                                      warnings: inout [String],
                                      cloudErrors: inout [String]) async {
        for ref in refs {
            let path = "h/\(roomKey)/\(remoteName(ref))"
            do {
                let data = try await CosUploader.fetchObjectData(path: path, config: config)
                guard MediaStore.write(data: data, fileName: ref.fileName, roomKey: roomKey) else {
                    cloudErrors.append("媒体写回本地失败：\(ref.fileName)")
                    continue
                }
                let item = MediaItem(fileName: ref.fileName, kind: ref.kind)
                item.house = house
                ctx.insert(item)
            } catch is CosObjectNotFoundError {
                warnings.append("媒体已无法恢复（云端也没有）：\(ref.fileName)")
            } catch {
                cloudErrors.append("媒体恢复失败：\(ref.fileName)（\(error.localizedDescription)）")
            }
        }
    }

    /// 汇总云端可重试错误：有则任务回待处理（可再次撤回），否则撤回完成
    private static func finalize(cloudErrors: [String],
                                 warnings: [String],
                                 action: String,
                                 room: String) -> Result {
        if !cloudErrors.isEmpty {
            let text = cloudErrors.joined(separator: "；")
            BackupLogStore.log(category: "撤回", action: action, result: "未完成",
                              detail: "本地已撤回，云端未完成：\(text)", room: room, cloud: true)
            return Result(failed: true, errorText: text, warnings: warnings)
        }
        let detail = warnings.isEmpty
            ? "本地与云端全部恢复原样"
            : "已撤回；提示：\(warnings.joined(separator: "；"))"
        BackupLogStore.log(category: "撤回", action: action, result: "成功",
                          detail: detail, room: room, cloud: true)
        return Result(failed: false, errorText: "", warnings: warnings)
    }

    // MARK: 场景一：新增房源（整套撤回）

    private static func revokeNewHouse(_ p: HouseUploadRollback, ctx: ModelContext) async -> Result {
        let warnings: [String] = []
        var cloudErrors: [String] = []
        let roomKey = p.roomKey

        // 1. 云端整个文件夹（h/<key>/ + 用户分享页），best-effort
        if let config = CosConfig.load(), config.isValid {
            do {
                try await CloudBackupService.deleteHouseRemoteFolder(
                    roomKey: roomKey, config: config, writeLog: false)
            } catch {
                cloudErrors.append("云端文件夹没删干净：\(error.localizedDescription)")
            }
        }

        // 2. 本地：删 House 模型 + 整个媒体目录 + 待上传队列/失败标记
        // 安全闸：纯「新增」任务的 before 快照必为 nil。若带 before 却走到这里，说明该房本就存在、
        // scene 可能错乱，绝不物理删除，记日志并判失败，从源头杜绝误删真实房源。
        guard p.before == nil else {
            BackupLogStore.log(category: "撤回", action: "撤回新增房源", result: "已中止",
                              detail: "任务带编辑前快照、不是纯新增，为防误删已跳过物理删除，请人工核对",
                              room: roomKey, cloud: true)
            return Result(failed: true,
                          errorText: "安全校验未通过：该房源可能已存在，未执行删除",
                          warnings: [])
        }
        if let h = findHouse(roomKey: roomKey, ctx: ctx) {
            ctx.delete(h)
        }
        MediaStore.deleteHouseDirectory(roomKey: roomKey)
        HouseMediaUploadQueue.removeRoom(roomKey)
        SyncFailStore.clear(roomKey)

        do {
            try ctx.save()
        } catch {
            return Result(failed: true,
                          errorText: "本地撤回失败：\(error.localizedDescription)",
                          warnings: warnings)
        }

        return await finalize(cloudErrors: cloudErrors, warnings: warnings,
                             action: "撤回新增房源", room: roomKey)
    }

    // MARK: 场景二：普通编辑

    private static func revokePlainEdit(_ p: HouseUploadRollback, ctx: ModelContext) async -> Result {
        var warnings: [String] = []
        var cloudErrors: [String] = []
        let roomKey = p.roomKey
        let ids = Set(p.ledgerEventIds)

        guard let house = findHouse(roomKey: roomKey, ctx: ctx) else {
            // v2.55：房源已被用户删除时，本地改动随删除已不存在，走「房源已删」收口，
            // best-effort 清理云端残留后移除任务，不再因找不到房而永久失败死锁
            return await revokeAfterHouseDeleted(p, ctx: ctx)
        }
        let config = CosConfig.load().flatMap { $0.isValid ? $0 : nil }

        // 1. 本地删本次新增媒体（MediaItem + 文件）
        let addedNames = Set(p.added.map { $0.fileName })
        for item in house.mediaItems where addedNames.contains(item.fileName) {
            ctx.delete(item)
            MediaStore.delete(fileName: item.fileName, roomKey: roomKey)
        }

        // 2. 从云端恢复被删媒体（无云配置只能提示）
        if let config {
            await restoreRemoved(roomKey: roomKey, refs: p.removed, house: house, ctx: ctx,
                                 config: config, warnings: &warnings, cloudErrors: &cloudErrors)
        } else {
            for ref in p.removed { warnings.append("无云端配置，无法恢复：\(ref.fileName)") }
        }

        // 3. 字段恢复
        if let before = p.before { restoreFields(house: house, before: before) }

        // 4. 本地账本移除本次事件（pending + 正式）
        HouseLedgerStore.removePendingEvents(roomKey: roomKey, eventIds: ids)
        HouseLedgerStore.purgeEventsLocal(roomKey: roomKey, eventIds: ids)

        do {
            try ctx.save()
        } catch {
            return Result(failed: true, errorText: "本地撤回失败：\(error.localizedDescription)")
        }
        // 5. 重写本地账本镜像 info.json
        LocalHouseLedger.save(house)

        // 6. 云端回滚
        if let config {
            // 6.1 删本次已传的新增媒体
            for ref in p.added {
                do {
                    try await CosUploader.deleteRemoteMedia(
                        fileName: ref.fileName, kind: ref.kind,
                        roomKey: roomKey, config: config)
                } catch {
                    cloudErrors.append("云端媒体没删掉：\(ref.fileName)（\(error.localizedDescription)）")
                }
            }
            // 6.2 info.json 回滚：把 added 远程名放进 removedMedia，防止并集合并把已传 added 保留
            let rollbackRecord = CloudHouseSync.record(from: house, username: CloudUser.username)
            let addedRemoteNames = Set(p.added.map { remoteName($0) })
            do {
                _ = try await CloudHouseSync.uploadGuarded(
                    record: rollbackRecord, removedMedia: addedRemoteNames, config: config)
            } catch {
                cloudErrors.append("云端账本未回滚：\(error.localizedDescription)")
            }
            // 6.3 正式账本移除本次事件
            do {
                try await HouseLedgerStore.purgeEventsSync(
                    roomKey: roomKey, eventIds: ids, config: config)
            } catch {
                cloudErrors.append("云端账本事件未移除：\(error.localizedDescription)")
            }
        }

        return await finalize(cloudErrors: cloudErrors, warnings: warnings,
                             action: "撤回编辑", room: roomKey)
    }

    // MARK: 场景三：撤回时本地房源已被删除（打破死锁）

    /// v2.55：用户在撤回前已删除这套房，本地 House 不存在，字段/媒体的本地改动随删除已不存在。
    /// 这里只做 best-effort 的云端残留清理与本地残留清理，然后让任务正常移除；
    /// 仅网络/限流等可重试错误才回待处理（可再次撤回），数据确实不存在（404）记 warning，不再死锁。
    private static func revokeAfterHouseDeleted(_ p: HouseUploadRollback, ctx: ModelContext) async -> Result {
        var warnings: [String] = []
        var cloudErrors: [String] = []
        let roomKey = p.roomKey
        let ids = Set(p.ledgerEventIds)

        if let config = CosConfig.load().flatMap({ $0.isValid ? $0 : nil }) {
            do {
                let remoteRec = try await CloudHouseSync.fetchOne(roomKey: roomKey, config: config)
                if remoteRec != nil {
                    // 云端还在（用户仅删本地）：清理本次任务直接产生的残留——已传 added 媒体 + 账本事件。
                    // 不做字段级 info.json 回滚（本地已无房，无法构造完整 record）；云端其余状态保持。
                    for ref in p.added {
                        do {
                            try await CosUploader.deleteRemoteMedia(
                                fileName: ref.fileName, kind: ref.kind,
                                roomKey: roomKey, config: config)
                        } catch {
                            cloudErrors.append("云端媒体没删掉：\(ref.fileName)（\(error.localizedDescription)）")
                        }
                    }
                    do {
                        try await HouseLedgerStore.purgeEventsSync(
                            roomKey: roomKey, eventIds: ids, config: config)
                    } catch {
                        cloudErrors.append("云端账本事件未移除：\(error.localizedDescription)")
                    }
                } else {
                    // 云端也没有这套房（双端删除）：无云端可清理
                    warnings.append("云端已无这套房，无需云端撤回")
                }
            } catch {
                // 无法确认云端状态（网络/限流）：可重试错误，回待处理等下次撤回
                cloudErrors.append("云端状态检查失败：\(error.localizedDescription)")
            }
        }

        // 本地残留清理（目录/队列/失败标记/账本事件，均 best-effort，目录可能已随删房清掉）
        MediaStore.deleteHouseDirectory(roomKey: roomKey)
        HouseMediaUploadQueue.removeRoom(roomKey)
        SyncFailStore.clear(roomKey)
        HouseLedgerStore.removePendingEvents(roomKey: roomKey, eventIds: ids)
        HouseLedgerStore.purgeEventsLocal(roomKey: roomKey, eventIds: ids)

        return await finalize(cloudErrors: cloudErrors, warnings: warnings,
                             action: "撤回（房源已删除）", room: roomKey)
    }

    // MARK: 场景四：改名（先在新 key 回滚，再迁回旧 key）

    private static func revokeRename(_ p: HouseUploadRollback, ctx: ModelContext) async -> Result {
        var warnings: [String] = []
        var cloudErrors: [String] = []
        let newKey = p.roomKey
        let oldKey = p.oldRoomKey
        let ids = Set(p.ledgerEventIds)

        guard let house = findHouse(roomKey: newKey, ctx: ctx) else {
            // v2.55：改名任务的房源已被删除，走「房源已删」收口，不再退化为必败的普通编辑
            return await revokeAfterHouseDeleted(p, ctx: ctx)
        }
        guard !oldKey.isEmpty else {
            // 仅缺旧 key 信息（房子还在），退化为普通编辑回滚
            return await revokePlainEdit(p, ctx: ctx)
        }
        let config = CosConfig.load().flatMap { $0.isValid ? $0 : nil }

        // 1. 本地删本次新增媒体（在 newKey 目录）
        let addedNames = Set(p.added.map { $0.fileName })
        for item in house.mediaItems where addedNames.contains(item.fileName) {
            ctx.delete(item)
            MediaStore.delete(fileName: item.fileName, roomKey: newKey)
        }
        // 2. 字段恢复（含旧房号），恢复后 house.mediaRoomKey 变为 oldKey
        if let before = p.before { restoreFields(house: house, before: before) }
        // 3. newKey 本地账本移除本次事件
        HouseLedgerStore.removePendingEvents(roomKey: newKey, eventIds: ids)
        HouseLedgerStore.purgeEventsLocal(roomKey: newKey, eventIds: ids)
        do {
            try ctx.save()
        } catch {
            return Result(failed: true, errorText: "本地撤回失败：\(error.localizedDescription)")
        }
        // 4. 本地媒体目录迁回 oldKey（账本文件随目录一起迁）
        MediaStore.migrateHouseDirectory(from: newKey, to: oldKey)

        // 5. 在 oldKey 恢复被删媒体（改名时删除针对 oldKey 云端）
        if let config {
            await restoreRemoved(roomKey: oldKey, refs: p.removed, house: house, ctx: ctx,
                                 config: config, warnings: &warnings, cloudErrors: &cloudErrors)
            do {
                try ctx.save()
            } catch {
                cloudErrors.append("恢复媒体后保存失败：\(error.localizedDescription)")
            }
        } else {
            for ref in p.removed { warnings.append("无云端配置，无法恢复：\(ref.fileName)") }
        }

        // 6. 重写 oldKey 本地账本镜像
        LocalHouseLedger.save(house)

        // 7. 云端
        if let config {
            // 7.1 删新 key 整个云端目录（连带 added 媒体）
            do {
                try await CloudBackupService.deleteHouseRemoteFolder(
                    roomKey: newKey, config: config, writeLog: false)
            } catch {
                cloudErrors.append("云端新目录没删干净：\(error.localizedDescription)")
            }
            // 7.2 旧 key 云端：正常应仍在；若 info.json 已被删（极端）则用恢复后的 house 重建
            do {
                let oldRec = try await CloudHouseSync.fetchOne(roomKey: oldKey, config: config)
                if oldRec == nil {
                    let rec = CloudHouseSync.record(from: house, username: CloudUser.username)
                    _ = try await CloudHouseSync.uploadGuarded(record: rec, config: config)
                }
            } catch {
                cloudErrors.append("旧云端目录检查/恢复失败：\(error.localizedDescription)")
            }
            // 7.3 旧 key 正式账本移除本次事件（若已落到旧 key）
            do {
                try await HouseLedgerStore.purgeEventsSync(
                    roomKey: oldKey, eventIds: ids, config: config)
            } catch {
                cloudErrors.append("旧云端账本事件未移除：\(error.localizedDescription)")
            }
        }

        return await finalize(cloudErrors: cloudErrors, warnings: warnings,
                             action: "撤回改名", room: oldKey)
    }
}
