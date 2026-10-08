import SwiftUI

/// 主页「压缩」。
///
/// 交互状态机（由 AppState / CompressionSession 驱动，不再用散落的 Boolean）：
///   idle（无已选视频）→ ready（已选）→ compressing（session.isRunning）→ completed/failed
/// 「开始压缩」按钮在 idle 时 disabled、压缩中显示「正在压缩…」，绝无「点了没反应」。
///
/// Presentation 修饰符分层挂载（关键修复）：
/// SwiftUI 中同一视图叠加多个 present 修饰符（sheet/fullScreenCover/alert）时
/// 只有部分会生效。现拆分为：sheet→ScrollView、fullScreenCover+导航→NavigationStack、
/// alert→header 视图，各自独立节点。
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var temp: TempFileManager
    @EnvironmentObject var settings: SettingsStore
    @State private var showPicker = false
    @State private var showSettingsPage = false
    @State private var error: AppError?

    private var selected: [VideoItem] { appState.selectedVideos }
    private var profile: CompressionProfile { appState.profile }
    private var session: CompressionSession { appState.session }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                        .alert(error?.errorDescription ?? "", isPresented: Binding(
                            get: { error != nil },
                            set: { if !$0 { error = nil } }
                        )) {
                            Button("好", role: .cancel) {}
                        } message: {
                            if let e = error { Text(e.recoverySuggestion) }
                        }
                    mainContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, selected.isEmpty ? 40 : 150)
            }
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPicker) {
                VideoPicker(onPicked: { items in
                    appState.selectedVideos.append(contentsOf: items)
                    AppLog.photo("选择视频 \(items.count) 个，累计 \(appState.selectedVideos.count) 个")
                }, temp: temp)
            }
            // 所有 present 修饰符都挂在 NavigationStack【内部】。
            // 【关键修复】上一版 navigationDestination 挂在 NavigationStack 外部，
            // 这是 SwiftUI 非法结构：状态翻 true 时直接 fatalError——
            // 即「点压缩方式进不去 / 点开始压缩闪退」的根因。
            .navigationDestination(isPresented: $showSettingsPage) {
                CompressionSettingsPage()
            }
            .fullScreenCover(isPresented: $appState.showProgressCover) {
                CompressionProgressView(session: session) {
                    // 用户明确结束本轮：清空已选并关闭进度页
                    appState.finishRound()
                }
                .environmentObject(temp)
                .environmentObject(settings)
            }
        }
        .overlay(alignment: .bottom) {
            // 底部操作区：固定尺寸浮层，不产生全屏透明遮挡
            if !selected.isEmpty && !appState.showProgressCover {
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 92)   // 稳定位于底部导航之上，不重叠
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: selected.isEmpty)
    }

    // MARK: - 顶部大标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("压缩").font(.largeTitle.bold())
            Text("本地处理 · 不上传 · 无需账号")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 主体内容

    @ViewBuilder
    private var mainContent: some View {
        if selected.isEmpty {
            emptyState
        } else {
            selectedList
        }
    }

    /// 空状态：极简文字 + 适中胶囊按钮。
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("还没有视频")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("选择照片图库中的视频开始压缩")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            GlassCapsuleButton(title: "选择视频", systemImage: "plus") {
                AppLog.ui("点击：选择视频")
                showPicker = true
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 130)
    }

    /// 已选视频列表。
    private var selectedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已选择 \(selected.count) 个视频")
                .font(.headline)
                .padding(.bottom, 8)

            ForEach(selected) { item in
                VideoRow(item: item) {
                    appState.removeVideo(item)
                }
                if item.id != selected.last?.id {
                    Divider().padding(.leading, 64)
                }
            }

            compressionMethodRow
                .padding(.top, 20)
        }
    }

    /// 压缩方式入口 + 预估结果（明确标注为估算值）。
    private var compressionMethodRow: some View {
        Button {
            AppLog.ui("进入压缩方式页面（当前模式：\(profile.mode.displayName)）")
            showSettingsPage = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("压缩方式").font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(estimateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(profile.mode.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// 预估文案：明确是估算值；无法压缩的视频如实说明。
    private var estimateText: String {
        let estimates = selected.compactMap { item -> Int64? in
            BitrateCalculator.estimateOutputBytes(fileSizeBytes: item.fileSizeBytes,
                                                  durationSeconds: item.durationSeconds,
                                                  height: item.height, fps: item.fps,
                                                  mode: profile.mode, custom: profile.custom)
        }
        let totalOriginal = selected.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalEstimate = estimates.reduce(Int64(0), +)
        let uncompressible = selected.count - estimates.count

        if selected.count == 1, let est = estimates.first, let orig = selected.first?.fileSizeBytes {
            return "预计约 \(Formatters.bytes(est))（原 \(Formatters.bytes(orig))，以编码结果为准）"
        }
        if totalEstimate < totalOriginal {
            var text = "预计节省约 \(Formatters.bytes(totalOriginal - totalEstimate))（估算值）"
            if uncompressible > 0 {
                text += " · \(uncompressible) 个可能无法压缩"
            }
            return text
        }
        return "所选视频码率已较低，可能无法再压缩"
    }

    // MARK: - 底部操作区（按钮状态由 session.phase 驱动，点击后立即变化）

    private var bottomBar: some View {
        let busy = session.isRunning
        let buttonTitle: String = {
            switch session.phase {
            case .preparing:
                return "准备压缩…"
            case .running:
                if let i = session.currentIndex {
                    return "正在压缩 \(i + 1) / \(session.tasks.count)"
                }
                return "正在压缩…"
            default:
                return "开始压缩"
            }
        }()
        return VStack(spacing: 12) {
            HStack {
                Text("\(selected.count) 个视频")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(estimateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                startCompression()
            } label: {
                Text(buttonTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(busy ? Color.accentColor.opacity(0.5) : Color.accentColor))
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(busy)
            .accessibilityHint(busy ? "压缩任务进行中" : "开始压缩所选视频")
        }
        .padding(16)
        .floatSurface(cornerRadius: 22)
    }

    private func startCompression() {
        AppLog.ui("Start compression tapped，已选 \(selected.count) 个")
        // ---- 压缩前完整输入检查：任何无效情况报错返回，绝不进入编码，绝不 Crash ----
        guard !selected.isEmpty else {
            error = .unknown("请先选择视频")
            return
        }
        // 逐个校验每个视频的有效性（批量串行压缩，逐个处理互不影响）
        for item in selected {
            guard item.fileSizeBytes > 0, item.durationSeconds > 0.2 else {
                error = .videoReadFailed
                return
            }
            guard FileManager.default.fileExists(atPath: item.sourceURL.path) else {
                error = .videoReadFailed
                return
            }
        }
        guard session.phase == .idle || session.phase == .completed || session.phase == .cancelled else {
            error = .unknown("已有压缩任务在进行中")
            return
        }
        guard !session.isRunning else { return }
        AppLog.compress("selectedVideos=1，profile=\(profile.mode.displayName)，source=\(Formatters.bytes(item.fileSizeBytes))")
        session.run(items: selected, profile: profile, settings: settings) { startError in
            // 启动失败必须可见，绝不静默
            Task { @MainActor in error = startError }
        }
        // run 已受理（phase=preparing），立即弹出进度页
        appState.showProgressCover = true
    }
}
