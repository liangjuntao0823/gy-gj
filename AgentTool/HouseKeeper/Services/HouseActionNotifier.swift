import Foundation
import SwiftUI
import UserNotifications

/// v2.44：房源板块动作的系统通知发送层。
/// - 走 UNUserNotificationCenter，前台也显示横幅（由 LocalNotificationManager 的 willPresent 放行 .banner）
/// - v2.45：取消「同一房源同一动作 10 秒内只发一条」——改一次提醒一次，每条都独立投递不互相覆盖
/// - 通知权限被关闭时自动降级为顶部页内光条，不静默
@MainActor
final class HouseActionNotifier: ObservableObject {
    static let shared = HouseActionNotifier()

    /// 权限被拒时的页内降级光条文案
    @Published private(set) var fallbackText: String?

    private let center = UNUserNotificationCenter.current()
    private var authorizationDenied = false
    private var checkedAuthorization = false
    private var fallbackToken = 0
    /// 每条通知独立标识计数器，保证连续动作各发一条、全部保留
    private var identifierCounter = 0

    /// 启动时预热一次权限状态（首次进入时若未决定会顺带申请）
    func prepare() {
        let center = self.center
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in
                self.authorizationDenied = denied
                self.checkedAuthorization = true
            }
        }
    }

    /// 发一条即时系统通知。key 仅用于标识来源（建议：「动作.房号」），不再做任何去重——每次调用都发。
    func send(key: String, title: String, body: String, silent: Bool = false) {
        if !checkedAuthorization { prepare() }
        if authorizationDenied {
            showFallback("\(title)：\(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !silent { content.sound = .default }
        content.threadIdentifier = "house.action"
        content.interruptionLevel = .active

        // v2.45：每次调用生成独立标识，连续改动各发一条、互不覆盖，通知中心里全部保留
        identifierCounter += 1
        let identifier = "house.action.\(key).\(identifierCounter)"
        center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.3, repeats: false)
        ))
    }

    private func showFallback(_ text: String) {
        fallbackToken += 1
        let token = fallbackToken
        withAnimation(.easeOut(duration: 0.2)) { fallbackText = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard token == fallbackToken else { return }
            withAnimation(.easeIn(duration: 0.2)) { fallbackText = nil }
        }
    }
}

/// 权限被拒时的顶部兜底光条（挂在 MainTabView 最上层）
struct HouseNoticeBannerOverlay: View {
    @ObservedObject private var notifier = HouseActionNotifier.shared

    var body: some View {
        if let text = notifier.fallbackText {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}
