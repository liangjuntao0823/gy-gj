import UIKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// v2.68 分享扩展入口：相册共享菜单下方动作列表「保存到公寓管家」。
/// 自定义 principal VC（非 SLComposeServiceViewController）→ 系统把它放进下方动作列表，
/// 与「保存到美柚」并排，而不是上方 App 排。
class ShareViewController: UIViewController {

    private var staged: [ShareUploadCoordinator.StagedItem] = []
    private let stagingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShareStaging_\(UUID().uuidString)", isDirectory: true)
    private let notificationDelegate = ShareNotificationDelegate()

    override func viewDidLoad() {
        super.viewDidLoad()
        // 进程分支标记：必须在任何 MediaStore/配置读取之前置位
        SharedBridge.isExtension = true
        MediaStore.useSharedContainer = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        view.backgroundColor = .systemBackground
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        Task { await loadItems() }
    }

    /// 从共享菜单收图片/视频：loadFileRepresentation 流式落临时文件（不整读进内存），
    /// 视频按真实容器定后缀（MediaNaming 原函数），图片保留源格式待入库时转 JPEG 0.85。
    private func loadItems() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var providers: [NSItemProvider] = []
        for item in items {
            for att in item.attachments ?? [] {
                if att.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    || att.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    providers.append(att)
                }
            }
        }
        // 与 App 选媒体同量级上限，防一次性塞爆扩展内存
        for provider in providers.prefix(30) {
            let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let typeID = isVideo ? UTType.movie.identifier : UTType.image.identifier
            guard let url = await loadFile(provider: provider, typeID: typeID) else { continue }
            if isVideo {
                let ext = MediaNaming.videoExtension(forFile: url)
                let dest = stagingDir.appendingPathComponent(UUID().uuidString + "." + ext)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    staged.append(.init(kind: "video", url: dest))
                }
            } else {
                let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
                let dest = stagingDir.appendingPathComponent(UUID().uuidString + "." + ext)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    staged.append(.init(kind: "image", url: dest))
                }
            }
        }
        await MainActor.run { showPanel() }
    }

    private func loadFile(provider: NSItemProvider, typeID: String) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                // 回调里的临时 URL 出了闭包即失效——立即拷贝到本扩展 staging 目录
                guard let url else { cont.resume(returning: nil); return }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "dat" : url.pathExtension))
                let ok = (try? FileManager.default.copyItem(at: url, to: tmp)) != nil
                cont.resume(returning: ok ? tmp : nil)
            }
        }
    }

    private func showPanel() {
        let panel = SharePanelView(
            staged: staged,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.finish() })
        let host = UIHostingController(rootView: panel)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func finish() {
        try? FileManager.default.removeItem(at: stagingDir)
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// 扩展前台期间也放行横幅（与主 App LocalNotificationManager 的 willPresent 口径一致）
final class ShareNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
