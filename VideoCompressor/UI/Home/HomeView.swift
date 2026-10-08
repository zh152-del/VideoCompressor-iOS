import SwiftUI
import Photos

/// 主页「压缩」：自动扫描相册视频，每 50 个一组，组独立压缩。
/// 已压缩识别：文件名含 __VC__（压缩成品保存时命名，重装 App 后仍可识别）。
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var temp: TempFileManager
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var scanner = PhotoScanner()
    @ObservedObject private var groupStore = GroupStore.shared
    @ObservedObject private var fingerprintStore = FingerprintStore.shared
    @State private var showPicker = false
    @State private var showSettingsPage = false
    @State private var error: AppError?
    @State private var askProcessedItems: [VideoItem]? = nil   // 询问模式待定项
    @State private var pendingRun: [VideoItem]? = nil          // 询问模式待执行的完整队列
    @State private var skipNote: String? = nil
    @State private var activeGroupIndex: Int? = nil            // 本次压缩的组号（手动勾选为 nil）

    private var selected: [VideoItem] { appState.selectedVideos }
    private var profile: CompressionProfile { appState.profile }
    private var session: CompressionSession { appState.session }

    /// 每 50 个一组。
    private let groupSize = 50
    private var groupCount: Int { (scanner.videos.count + groupSize - 1) / groupSize }
    private func groupVideos(_ gi: Int) -> [ScannedVideo] {
        let s = gi * groupSize
        return Array(scanner.videos.dropFirst(s).prefix(groupSize))
    }

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
                    permissionHint
                    pickerEntry
                    completedGroupsEntry
                    mainContent
                    if !selected.isEmpty {
                        compressionMethodRow
                    }
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
            // 所有 present 修饰符都在 NavigationStack 内部（外层=非法结构会闪退）
            .navigationDestination(isPresented: $showSettingsPage) {
                CompressionSettingsPage()
            }
            .navigationDestination(isPresented: $showCompletedGroups) {
                CompletedGroupsView()
            }
            .fullScreenCover(isPresented: $appState.showProgressCover) {
                CompressionProgressView(session: session) {
                    appState.finishRound()
                }
                .environmentObject(temp)
                .environmentObject(settings)
            }
            // 询问模式：一次确认整批已压缩视频
            .confirmationDialog("有 \(pendingProcessedCount) 个视频已压缩过",
                                isPresented: Binding(
                                    get: { pendingRun != nil },
                                    set: { if !$0 { pendingRun = nil } }
                                ), titleVisibility: .visible) {
                Button("跳过这些视频") {
                    let skipIDs = Set((pendingRun ?? []).filter { fingerprintStore.knownByID($0.localIdentifier ?? $0.phAssetID) }.map { $0.id })
                    let remaining = (pendingRun ?? []).filter { !skipIDs.contains($0.id) }
                    launchRun(items: remaining, skippedCount: skipIDs.count)
                }
                Button("重新压缩", role: .destructive) {
                    launchRun(items: pendingRun ?? [], skippedCount: 0)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("文件名含 __VC__ 标记的视频之前已压缩过。跳过不会改动这些视频。")
            }
        }
        .overlay(alignment: .bottom) {
            if !selected.isEmpty && !appState.showProgressCover {
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: selected.isEmpty)
        .onAppear {
            // 每次回到主页重新扫描（元数据级），保证 __VC__ 标记 / 外部删除及时反映
            scanner.scan()
        }
    }

    @State private var showCompletedGroups = false
    private var pendingProcessedCount: Int {
        (pendingRun ?? []).filter { fingerprintStore.knownByID($0.localIdentifier ?? $0.phAssetID) }.count
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("压缩").font(.largeTitle.bold())
            Text("本地处理 · 不上传 · 无需账号")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 权限提示（拒绝/受限时给出去系统设置的入口，绝不 Crash）。
    @ViewBuilder
    private var permissionHint: some View {
        if scanner.status == .denied {
            VStack(alignment: .leading, spacing: 8) {
                Text("没有照片图库权限").font(.headline)
                Text("请在系统设置中允许访问照片，然后返回刷新。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("前往系统设置")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var pickerEntry: some View {
        HStack {
            GlassCapsuleButton(title: "刷新列表", systemImage: "arrow.clockwise") {
                AppLog.ui("手动刷新相册扫描")
                scanner.scan()
            }
            Spacer()
            GlassCapsuleButton(title: "从文件选择", systemImage: "plus") {
                showPicker = true
            }
        }
    }

    /// 已完成组入口（用户主动点击进入，绝不自动跳转）。
    private var completedGroupsEntry: some View {
        Group {
            if !groupStore.records.isEmpty {
                NavigationLink {
                    CompletedGroupsView()
                } label: {
                    HStack {
                        Label("已完成组（\(groupStore.records.count)）", systemImage: "checkmark.rectangle.stack")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var mainContent: some View {
        switch scanner.status {
        case .idle:
            VStack(spacing: 10) {
                Text("还没有视频").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                Text("授权照片访问后自动显示相册中的视频").font(.subheadline).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.top, 100)
        case .scanning:
            HStack { Spacer(); ProgressView(); Text("正在扫描相册视频…").font(.subheadline).foregroundStyle(.secondary); Spacer() }
                .padding(.top, 100)
        case .denied:
            EmptyView()
        case .limited:
            groupedList
        case .done:
            if scanner.videos.isEmpty {
                VStack(spacing: 10) {
                    Text("相册中没有视频").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 100)
            } else {
                groupedList
            }
        }
    }

    /// 分组列表：每 50 个一组，明显分隔 + 组头（状态 / 压缩按钮）。
    private var groupedList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if case .limited = scanner.status {
                Text("受限访问：仅显示你授权的照片视频")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            if !selected.isEmpty {
                Text("已选 \(selected.count) 个视频").font(.headline).padding(.bottom, 8)
            }
            ForEach(0..<max(groupCount, 0), id: \.self) { gi in
                groupHeader(gi)
                ForEach(groupVideos(gi)) { video in
                    ScanVideoRow(
                        video: video,
                        isSelected: selected.contains { $0.localIdentifier == video.id },
                        isKnownProcessed: fingerprintStore.knownByID(video.id),
                        onToggle: { toggle(video) }
                    )
                }
                if gi < groupCount - 1 {
                    // 明显组分隔线
                    Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 1)
                        .padding(.vertical, 14)
                }
            }
            if let note = skipNote {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

    /// 组头：编号 / 范围 / 数量 / 状态 / 压缩按钮。
    @ViewBuilder
    private func groupHeader(_ gi: Int) -> some View {
        let items = groupVideos(gi)
        let record = groupStore.records.first { $0.index == gi }
        let stateText: String = {
            if session.isRunning, session.currentGroupIndex == gi {
                return "压缩中 \(session.finishedCount) / \(session.tasks.count)"
            }
            if let r = record {
                return "已完成 · 成功\(r.succeeded) 失败\(r.failed) 跳过\(r.skipped)"
            }
            return "未开始"
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("第\(gi + 1)组").font(.headline)
                Text("\(gi * groupSize + 1) - \(gi * groupSize + items.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(stateText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(record != nil ? Color.green : (session.isRunning && session.currentGroupIndex == gi) ? Color.accentColor : Color.secondary)
            }
            Text("\(items.count) 个视频").font(.caption).foregroundStyle(.secondary)
            Button {
                startGroup(gi)
            } label: {
                Text(session.isRunning && session.currentGroupIndex == gi ? "压缩中…" : "压缩第\(gi + 1)组")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(session.isRunning ? Color.accentColor.opacity(0.4) : Color.accentColor))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(session.isRunning)
        }
        .padding(.vertical, 10)
    }

    /// 勾选/取消一个扫描视频：直接以 PHAsset 引用加入队列（压缩前才流式导出，不占磁盘）。
    private func toggle(_ video: ScannedVideo) {
        if let idx = selected.firstIndex(where: { $0.localIdentifier == video.id }) {
            appState.selectedVideos.remove(at: idx)
            return
        }
        let item = VideoItem(
            localIdentifier: video.id,
            sourceURL: URL(fileURLWithPath: "/dev/null"),   // 占位：压缩前经 phAssetID 懒导出
            title: video.filename,
            durationSeconds: video.duration,
            fileSizeBytes: video.fileSizeBytes ?? 0,
            width: video.pixelWidth,
            height: video.pixelHeight,
            fps: 0,
            codecDescription: "未知",
            thumbnailURL: nil,
            creationDate: nil,
            phAssetID: video.id
        )
        appState.selectedVideos.append(item)
        AppLog.videoScan("已选择：\(video.filename)")
    }

    /// 压缩方式入口 + 预估结果（明确标注为估算值）。
    private var compressionMethodRow: some View {
        Button {
            AppLog.ui("进入压缩方式页面（当前模式：\(profile.mode.displayName)）")
            showSettingsPage = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("压缩方式").font(.subheadline).foregroundStyle(.primary)
                    Text(estimateText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(profile.mode.displayName).font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

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

        if selected.count == 1, let est = estimates.first, let orig = selected.first?.fileSizeBytes, orig > 0 {
            return "预计约 \(Formatters.bytes(est))（原 \(Formatters.bytes(orig))，以编码结果为准）"
        }
        if selected.count == 1, (selected.first?.fileSizeBytes ?? 0) <= 0 {
            return "大小暂不可用（将在压缩时确认）"
        }
        if totalEstimate < totalOriginal {
            var text = "预计节省约 \(Formatters.bytes(totalOriginal - totalEstimate))（估算值）"
            if uncompressible > 0 { text += " · \(uncompressible) 个可能无法压缩" }
            return text
        }
        return "所选视频码率已较低，可能无法再压缩"
    }

    // MARK: - 底部操作区

    private var bottomBar: some View {
        let busy = session.isRunning
        let buttonTitle: String = {
            switch session.phase {
            case .preparing: return "准备压缩…"
            case .running:
                if let i = session.currentIndex { return "正在压缩 \(i + 1) / \(session.tasks.count)" }
                return "正在压缩…"
            case .recording: return "正在压缩…"
            default: return "开始压缩"
            }
        }()
        return VStack(spacing: 12) {
            HStack {
                Text("\(selected.count) 个视频").font(.subheadline.weight(.medium))
                Spacer()
                Text(estimateText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        }
        .padding(16)
        .floatSurface(cornerRadius: 22)
    }

    private func startCompression() {
        AppLog.ui("Start compression tapped，已选 \(selected.count) 个")
        guard !selected.isEmpty else {
            error = .unknown("请先选择视频")
            return
        }
        guard session.phase == .idle || session.phase == .completed || session.phase == .cancelled else {
            error = .unknown("已有压缩任务在进行中")
            return
        }
        guard !session.isRunning else { return }
        activeGroupIndex = nil
        startRun(selected, skippedCount: 0)
    }

    /// 压缩整组（组内全部视频，不要求逐个手动勾选）。
    private func startGroup(_ gi: Int) {
        guard !session.isRunning else { return }
        let items = groupVideos(gi).map { video in
            VideoItem(
                localIdentifier: video.id,
                sourceURL: URL(fileURLWithPath: "/dev/null"),
                title: video.filename,
                durationSeconds: video.duration,
                fileSizeBytes: video.fileSizeBytes ?? 0,
                width: video.pixelWidth,
                height: video.pixelHeight,
                fps: 0,
                codecDescription: "未知",
                thumbnailURL: nil,
                creationDate: nil,
                phAssetID: video.id
            )
        }
        guard !items.isEmpty else { return }
        activeGroupIndex = gi
        AppLog.ui("压缩第\(gi + 1)组（\(items.count) 个）")
        startRun(items, skippedCount: 0)
    }

    /// 已压缩策略分发（skip / ask / recompress），随后启动。
    private func startRun(_ items: [VideoItem], skippedCount: Int) {
        let processed = items.filter { fingerprintStore.knownByID($0.localIdentifier ?? $0.phAssetID) }
        switch settings.processedPolicy {
        case .skip where !processed.isEmpty:
            let remaining = items.filter { !processed.contains($0) }
            guard !remaining.isEmpty else {
                error = .unknown("所选视频都已压缩过（设置中可更改处理方式）")
                return
            }
            skipNote = "已自动跳过 \(processed.count) 个已压缩视频"
            launchRun(items: remaining, skippedCount: skippedCount + processed.count)
        case .ask where !processed.isEmpty:
            pendingRun = items
        default:
            launchRun(items: items, skippedCount: skippedCount)
        }
    }

    private func launchRun(items: [VideoItem], skippedCount: Int) {
        guard !items.isEmpty else {
            error = .unknown("没有可压缩的视频")
            return
        }
        for item in items {
            guard item.durationSeconds > 0.2 else {
                error = .videoReadFailed
                return
            }
            guard item.phAssetID != nil || FileManager.default.fileExists(atPath: item.sourceURL.path) else {
                error = .videoReadFailed
                return
            }
        }
        AppLog.compress("selectedVideos=\(items.count)，profile=\(profile.mode.displayName)，group=\(activeGroupIndex.map { "\($0 + 1)" } ?? "无")")
        session.run(items: items, profile: profile, settings: settings,
                    groupIndex: activeGroupIndex, skippedCount: skippedCount) { startError in
            Task { @MainActor in error = startError }
        }
        appState.showProgressCover = true
    }
}

/// 扫描列表行：封面 + 名称 + 规格 + 已压缩徽章 + 勾选。
struct ScanVideoRow: View {
    let video: ScannedVideo
    let isSelected: Bool
    let isKnownProcessed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                ZStack(alignment: .center) {
                    AssetThumbnail(assetIdentifier: video.id, side: 52)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: 52, height: 52)
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(video.filename).font(.subheadline.weight(.medium)).lineLimit(1)
                        if isKnownProcessed {
                            Text("已压缩")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                    }
                    Text("\(video.fileSizeBytes.map { Formatters.bytes($0) } ?? "大小暂不可用") · \(Formatters.time(video.duration)) · \(video.resolutionText) · \(video.aspectText)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}
