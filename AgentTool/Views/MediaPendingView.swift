import SwiftUI

/// 旧的「待补传媒体」页：补传队列已整体并入任务中心，这里直接呈现任务中心，
/// 失败项在「待处理」里手动点重试，成功后自动进「最近完成」。
struct MediaPendingView: View {
    var body: some View {
        TaskCenterView()
    }
}
