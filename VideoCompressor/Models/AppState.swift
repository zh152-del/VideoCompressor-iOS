import Foundation
import SwiftUI
import Combine

/// 应用级共享状态：在 App 根部创建一次，经 environmentObject 共享。
///
/// 承载跨页面生命周期数据（绝不放在 View 的 @State 里）：
/// - 已选视频列表（切 Tab / 进二级页 / 返回 都不能丢）
/// - 当前压缩模式
/// - 压缩会话（压缩任务在后台继续，不因页面切换被销毁）
///
/// 清空已选视频的唯一途径：
/// 1. 用户主动逐个移除
/// 2. 压缩完成后用户点击「返回压缩」（明确结束本轮）
/// 3. App 重启（冷启动自然为空）
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedVideos: [VideoItem] = []
    @Published var profile = CompressionProfile()
    @Published var showProgressCover = false

    let session = CompressionSession()

    private init() {
        profile.mode = SettingsStore.shared.defaultMode
        AppLog.app("启动：AppState 初始化完成")
        // 启动恢复：上次退出时未完成的任务标记为"中断待处理"（绝不伪装成成功）
        HistoryStore.shared.recoverInterrupted()
    }

    var isBusy: Bool { session.isRunning }

    /// 移除单个已选视频（用户主动）。
    func removeVideo(_ item: VideoItem) {
        selectedVideos.removeAll { $0.id == item.id }
        AppLog.ui("移除已选视频：\(item.title)，剩余 \(selectedVideos.count)")
    }

    /// 压缩完成返回后清空（用户明确结束本轮）。
    func finishRound() {
        selectedVideos = []
        showProgressCover = false
        AppLog.ui("本轮压缩结束，清空已选列表")
    }
}
