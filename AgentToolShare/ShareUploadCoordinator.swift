import Foundation
import UIKit

/// v2.68 分享扩展上传编排：与 App 内「新增房源 / 编辑保存」同一套函数、同一口径。
/// - 媒体：CosUploader.uploadHouseMedia（命名/压缩/转码/幂等/看门狗全复用）；
///   失败不自动重试（v2.52 口径），预登记在共享队列，主 App 任务中心手动重试；
/// - 账本：CloudHouseSync.uploadGuarded（合并∪−删除、revision+1、CAS）+ HouseLedgerStore.append/sync；
/// - 清单：CloudManifestUpdater.flush（扩展生命周期内必须落地，不能等防抖）；
/// - 日志：BackupLogStore.log(cloud:true) + CloudOps（共享待补队列）；
/// - 通知：HouseActionNotifier（文案与 App 内逐字一致）。
/// 不触碰 SwiftData / SyncTaskCenter / HouseSyncProgress（主 App UI 层）。
@MainActor
final class ShareUploadCoordinator: ObservableObject {

    /// 暂存媒体：kind=image/video，url=扩展临时目录里的源文件（视频已按真实容器定后缀）
    struct StagedItem {
        let kind: String
        let url: URL
    }

    /// 单文件进度行
    struct FileRow: Identifiable {
        let id = UUID()
        let fileName: String
        let kind: String
        var stage: String = "待上传"
        var percent: Double = 0
        var state: String = "pending"   // pending / uploading / success / failed
    }

    struct Outcome {
        var success = 0
        var failed = 0
        var skipped = 0
        var failedFiles: [String] = []
        var lastError = ""
        var ledgerOK = false
        var title = ""
        var body = ""
    }

    @Published var rows: [FileRow] = []
    @Published var phaseText = "准备中"

    /// 新增房源表单（与 HouseEditView 新建默认值一致：状态待租、备注空、密码可空）
    struct NewRoomForm {
        var tower = 1
        var roomNo = ""
        var priceText = ""
        var landlord = ""
        var layout = ""
        var password = ""

        /// 房号归一 + 带座前缀 + 非法字符替换（逐字对齐 House.mediaRoomKey）
        var roomKey: String {
            var s = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixes = ["2-", "1-", "2－", "1－"]
            var changed = true
            while changed {
                changed = false
                for p in prefixes where s.hasPrefix(p) {
                    s = String(s.dropFirst(p.count))
                    changed = true
                }
            }
            let raw = (tower == 2 ? "2-" : "1-") + s
            let illegal = CharacterSet(charactersIn: "/:\\?%*|\u{22}<>")
            return raw.components(separatedBy: illegal).joined(separator: "-")
        }

        var validationError: String? {
            let no = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            if no.isEmpty { return "请填写房号" }
            if landlord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写房东" }
            let p = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty || Int(p) == nil { return "租金请填写数字" }
            return nil
        }

        func record(mediaNames: [String]) -> CloudHouseRecord {
            CloudHouseRecord(
                roomKey: roomKey,
                roomNo: roomNo.trimmingCharacters(in: .whitespacesAndNewlines),
                tower: tower,
                landlord: landlord.trimmingCharacters(in: .whitespacesAndNewlines),
                layout: layout.trimmingCharacters(in: .whitespacesAndNewlines),
                price: Int(priceText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                password: password,
                remark: "",
                status: HouseStatus.available.rawValue,
                updatedAt: Date(),
                updatedBy: CloudUser.signedUsername,
                mediaNames: mediaNames,
                revision: nil
            )
        }
    }

    /// 入库：图片 UIImage→JPEG 0.85（与 loadPhotos 同参数）；视频原文件+真实容器后缀（与 loadVideos 同口径）。
    /// 逐张 autoreleasepool，控制扩展内存峰值。
    private func ingest(_ item: StagedItem, roomKey: String) -> String? {
        if item.kind == "video" {
            return MediaStore.saveFile(from: item.url, roomKey: roomKey)
        }
        return autoreleasepool { () -> String? in
            guard let image = UIImage(contentsOfFile: item.url.path),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
            return MediaStore.save(data: jpeg, ext: "jpg", roomKey: roomKey)
        }
    }

    /// 主流程。existing != nil = 追加到已有房源；否则按 form 新增房源。
    func run(staged: [StagedItem], existing: CloudHouseRecord?, form: NewRoomForm) async -> Outcome {
        var out = Outcome()
        let roomKey = existing?.roomKey ?? form.roomKey
        let isNewHouse = existing == nil

        // 1) 取 COS 配置（云函数 cosCfg，仅内存持有）
        let config: CosConfig
        do {
            config = try await CosConfig.fetchForExtension()
        } catch {
            out.lastError = error.localizedDescription
            out.title = "分享配置未就绪"
            out.body = out.lastError
            return out
        }

        await MediaActivityGate.shared.beginUpload()
        defer { Task { await MediaActivityGate.shared.endUpload() } }

        // 2) 入库 + 预登记队列（即使扩展中途被系统终止，主 App 任务中心也能接手，文件不丢）
        phaseText = "媒体入库中"
        var saved: [(fileName: String, kind: String)] = []
        for item in staged {
            if let name = ingest(item, roomKey: roomKey) {
                saved.append((name, item.kind))
                HouseMediaUploadQueue.enqueue(roomKey: roomKey, fileName: name, kind: item.kind)
            } else {
                out.skipped += 1
            }
        }
        rows = saved.map { FileRow(fileName: $0.fileName, kind: $0.kind) }

        // 3) 逐文件直传（uploadHouseMedia 原函数；失败不自动重试，留在共享队列）
        let compress = SharedBridge.mirroredCompress
        let total = saved.count
        var successNames: [String] = []
        for (idx, file) in saved.enumerated() {
            phaseText = "上传中 \(idx + 1)/\(total)"
            rows[idx].state = "uploading"
            do {
                try await CosUploader.uploadHouseMedia(
                    fileName: file.fileName, kind: file.kind, roomKey: roomKey,
                    config: config, compress: compress,
                    onStage: { stage in
                        Task { @MainActor in self.rows[idx].stage = stage }
                    },
                    onTranscodeProgress: { p in
                        Task { @MainActor in self.rows[idx].percent = max(0, min(1, p.isFinite ? p : 0)) * 0.5 }
                    },
                    onBytes: { p in
                        Task { @MainActor in self.rows[idx].percent = 0.5 + max(0, min(1, p.isFinite ? p : 0)) * 0.5 }
                    })
                HouseMediaUploadQueue.remove(roomKey: roomKey, fileName: file.fileName)
                rows[idx].state = "success"
                rows[idx].percent = 1
                out.success += 1
                successNames.append(file.fileName)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    out.lastError = "已取消"
                    return out
                }
                rows[idx].state = "failed"
                out.failed += 1
                out.failedFiles.append(file.fileName)
                out.lastError = error.localizedDescription
            }
        }

        // 4) 媒体阶段日志（与 uploadMedia 逐字同口径）
        let upSplit = HouseLedgerFormat.split(saved.map { (name: $0.fileName, kind: $0.kind) })
        let upParts = HouseLedgerFormat.mediaParts(images: upSplit.images, videos: upSplit.videos, includeNames: false)
        if out.failed > 0 {
            let upAction = isNewHouse ? "新增房源" : "新增媒体（本地→云端）"
            let upResult = isNewHouse && out.failed >= total ? "失败" : "部分失败"
            let upDetail = isNewHouse
                ? HouseMediaLogFormat.failureDetail(images: upSplit.images.count, videos: upSplit.videos.count, error: out.lastError)
                : upParts.joined(separator: "；") + "；成功 \(out.success) 失败 \(out.failed)（已入队自动补传）" + (out.lastError.isEmpty ? "" : "；错误：\(out.lastError)")
            BackupLogStore.log(category: "房源", action: upAction, result: upResult,
                              detail: upDetail, room: roomKey, cloud: true)
        } else if out.success > 0 && !isNewHouse {
            let upAction: String
            if upSplit.videos.isEmpty { upAction = "新增图片（本地→云端）" }
            else if upSplit.images.isEmpty { upAction = "新增视频（本地→云端）" }
            else { upAction = "新增媒体（本地→云端）" }
            BackupLogStore.log(category: "房源", action: upAction, result: "成功",
                              detail: upParts.joined(separator: "；"), room: roomKey, cloud: true)
        }

        // 5) 账本事件 + 记录推送（新增：先媒体后账本；失败文件名不进 mediaNames）
        phaseText = "同步账本"
        let successSplit = HouseLedgerFormat.split(saved.filter { successNames.contains($0.fileName) }.map { (name: $0.fileName, kind: $0.kind) })
        var record: CloudHouseRecord
        let action: String
        let changeText: String
        if isNewHouse {
            let initial = HouseLedgerFormat.mediaSummary(images: successSplit.images.count, videos: successSplit.videos.count)
            action = "新增房源"
            changeText = "新建房源，" + (initial.isEmpty ? "无媒体" : initial)
            record = form.record(mediaNames: successNames)
            if out.success > 0 || total == 0 {
                HouseLedgerStore.append(roomKey: roomKey, action: action, detail: changeText)
            }
        } else {
            var base = existing!
            let addedParts = HouseLedgerFormat.mediaParts(images: successSplit.images, videos: successSplit.videos, includeNames: false)
            action = successSplit.videos.isEmpty ? "新增图片"
                : (successSplit.images.isEmpty ? "新增视频" : "新增媒体")
            changeText = addedParts.map { "新增\($0)" }.joined(separator: "；")
            base.mediaNames = Array(Set(base.mediaNames).union(successNames))
            base.updatedAt = Date()
            base.updatedBy = CloudUser.signedUsername
            record = base
            if !addedParts.isEmpty {
                HouseLedgerStore.append(roomKey: roomKey, action: action, detail: changeText)
            }
        }

        do {
            let (merged, hadExisting) = try await CloudHouseSync.uploadGuarded(record: record, removedMedia: [], config: config)
            // 合并注记与 uploadLedger 同口径（集合差判定）
            let cloudOnly = Set(merged.mediaNames).subtracting(Set(record.mediaNames))
            let mergeNote = (hadExisting && !cloudOnly.isEmpty)
                ? "；已合并云端原有 \(cloudOnly.count) 个媒体"
                : ""
            let mainLogged = isNewHouse ? out.failed == 0 : true
            if mainLogged && (isNewHouse || !changeText.isEmpty) {
                BackupLogStore.log(category: "房源", action: action, result: "成功",
                                  detail: changeText + mergeNote, room: roomKey, cloud: true)
            } else if !mergeNote.isEmpty {
                BackupLogStore.log(category: "同步", action: "合并云端更新", result: "成功",
                                  detail: "云端有别人的更新，已合并：媒体 \(record.mediaNames.count) 个 → \(merged.mediaNames.count) 个", room: roomKey, cloud: true)
            }
            out.ledgerOK = true

            // 6) 单房账本合并上传（扩展内显式 await；失败留 dirty+共享 pending，主 App 启动接手）
            do {
                try await HouseLedgerStore.sync(roomKey: roomKey, config: config)
            } catch {
                HouseLedgerStore.markDirty(roomKey)
            }
            // 7) 清单必须在扩展生命周期内落地
            await CloudManifestUpdater.shared.flush()
        } catch {
            BackupLogStore.log(category: "房源", action: action, result: "失败",
                              detail: "云端更新失败：\(error.localizedDescription)", room: roomKey, cloud: true)
            out.lastError = error.localizedDescription
            if error is CloudSyncConflict {
                HouseActionNotifier.shared.send(
                    key: "conflict.\(roomKey)",
                    title: "修改没传上去",
                    body: "\(roomKey) 刚被其他设备更新，本次改动只存本机；请刷新同步后再编辑",
                    silent: true)
            } else {
                HouseActionNotifier.shared.send(
                    key: "syncfail.\(roomKey)",
                    title: "同步失败",
                    body: "\(roomKey) 云端同步失败：已挂同步任务中心，联网后点重试",
                    silent: true)
            }
            out.title = "同步失败"
            out.body = "\(roomKey) 云端同步失败：已挂同步任务中心，联网后点重试"
            return out
        }

        // 8) 系统通知（文案与 notifySaved 逐字一致）
        let images = staged.filter { $0.kind == "image" }.count
        let videos = staged.filter { $0.kind == "video" }.count
        var mediaSuffix = ""
        if images > 0 || videos > 0 { mediaSuffix = "（照片\(images)、视频\(videos)）" }
        if isNewHouse {
            if out.failed > 0 {
                out.title = "房源已保存，媒体待补传"
                out.body = "\(roomKey) 已存本机，\(out.failed) 个媒体没传上，联网后在同步任务中心点重试"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body, silent: true)
            } else {
                out.title = "房源已上传"
                out.body = "\(roomKey) 已同步到云端\(mediaSuffix)"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body)
            }
        } else {
            if out.failed > 0 {
                out.title = "修改已保存，媒体待补传"
                out.body = "\(roomKey) 的改动已存本机，\(out.failed) 个媒体没传上，联网后在同步任务中心点重试"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body, silent: true)
            } else {
                out.title = "修改已同步"
                out.body = "\(roomKey) 的改动已同步到云端\(mediaSuffix)"
                HouseActionNotifier.shared.send(key: "save.\(roomKey)", title: out.title, body: out.body)
            }
        }
        return out
    }
}
