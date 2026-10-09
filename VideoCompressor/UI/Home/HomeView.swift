import SwiftUI
import Photos

/// 主页「压缩」：自动扫描相册视频 + 规格展示 + 选择压缩 + 底部操作区。
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var temp: TempFileManager
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var scanner = PhotoScanner()
    @State private var showPicker = false
    @State private var showSettingsPage = false
    @State private var error: AppError?
    @State private var showBatchPanel = false
    @State private var batchPreparing: (done: Int, total: Int)? = nil
    /// 通过「一键选择」加入的项（阈值规则只作用于这些）
    @State private var batchSelectedIDs: Set<String> = []
    @State private var exportingIDs: Set<String> = []

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
                    permissionHint
                    pickerEntry
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
            .sheet(isPresented: $showBatchPanel) {
                BatchSelectPanel(
                    totalScanned: scanner.videos.count,
                    thresholdEnabled: settings.skipSmallVideosEnabled,
                    thresholdMB: settings.skipSmallVideosThresholdMB,
                    skipEstimate: { n, _ in
                        let cands = Array(scanner.videos.prefix(n))
                        guard settings.skipSmallVideosEnabled else { return 0 }
                        let th = Int64(settings.skipSmallVideosThresholdMB * 1024 * 1024)
                        return cands.filter { v in
                            guard let sz = v.fileSizeBytes, sz > 0 else { return false }
                            return sz < th
                        }.count
                    },
                    onApply: { count, all in applyBatchSelection(count: count, all: all) }
                )
            }
            .sheet(isPresented: $showPicker) {
                VideoPicker(onPicked: { items in
                    appState.selectedVideos.append(contentsOf: items)
                    AppLog.photo("选择视频 \(items.count) 个，累计 \(appState.selectedVideos.count) 个")
                }, temp: temp)
            }
            // 所有 present 修饰符都在 NavigationStack 内部（navigationDestination 在外层=非法结构会闪退）
            .navigationDestination(isPresented: $showSettingsPage) {
                CompressionSettingsPage()
            }
            .fullScreenCover(isPresented: $appState.showProgressCover) {
                CompressionProgressView(session: session) {
                    appState.finishRound()
                }
                .environmentObject(temp)
                .environmentObject(settings)
                .environmentObject(history)
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
            // 每次回到主页都重新扫描（轻量元数据），保证 __VC__ 标记/外部删除状态及时反映
            scanner.scan()
        }
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
        VStack(spacing: 10) {
            HStack {
                GlassCapsuleButton(title: "刷新列表", systemImage: "arrow.clockwise") {
                    AppLog.ui("手动刷新相册扫描")
                    scanner.scan()
                }
                Spacer()
                GlassCapsuleButton(title: "一键选择", systemImage: "checkmark.circle") {
                    AppLog.ui("打开一键选择面板")
                    showBatchPanel = true
                }
                Spacer()
                GlassCapsuleButton(title: "从文件选择", systemImage: "plus") {
                    showPicker = true
                }
            }
            // 排序（默认大小从大到小）
            HStack {
                Text("共 \(scanner.videos.count) 个视频").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(ScanSortMode.allCases) { m in
                        Button {
                            scanner.sortMode = m
                        } label: {
                            Text(m.displayName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.caption)
                        Text(scanner.sortMode.displayName).font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
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
            scannedList
        case .done:
            if scanner.videos.isEmpty {
                VStack(spacing: 10) {
                    Text("相册中没有视频").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 100)
            } else {
                scannedList
            }
        }
    }

    /// 扫描列表：懒加载，封面按需获取（AssetThumbnail 内部 NSCache + 小图请求）。
    private var scannedList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if case .limited = scanner.status {
                Text("受限访问：仅显示你授权的照片视频")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            if let p = batchPreparing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在准备 \(p.done) / \(p.total)").font(.caption.weight(.medium))
                    ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                }
                .padding(.bottom, 8)
            }
            if !selected.isEmpty {
                Text("已选 \(selected.count) 个视频").font(.headline).padding(.bottom, 8)
            }
            ForEach(scanner.videos) { video in
                ScanVideoRow(
                    video: video,
                    isSelected: selected.contains { $0.localIdentifier == video.id },
                    isExporting: exportingIDs.contains(video.id),
                    onToggle: { toggle(video) }
                )
                if video.id != scanner.videos.last?.id {
                    Divider().padding(.leading, 64)
                }
            }
        }
    }

    /// 勾选/取消一个扫描视频：勾选时先导出本地副本（流式，非整段载入内存），再进入压缩队列。
    private func toggle(_ video: ScannedVideo, markAsBatch: Bool = false) {
        if let idx = selected.firstIndex(where: { $0.localIdentifier == video.id }) {
            batchSelectedIDs.remove(selected[idx].id.uuidString)
            appState.selectedVideos.remove(at: idx)
            return
        }
        guard !exportingIDs.contains(video.id) else { return }
        exportingIDs.insert(video.id)
        Task {
            do {
                let url = try await PhotoLibraryService.shared.exportVideo(from: video.asset)
                let meta = try? await VideoInfoReader.readInfo(at: url)
                let thumbURL = temp.newThumbnailURL()
                try? await VideoInfoReader.generateThumbnail(from: url, to: thumbURL)
                let item = VideoItem(
                    localIdentifier: video.id,
                    sourceURL: url,
                    title: video.filename,
                    durationSeconds: meta?.durationSeconds ?? video.duration,
                    fileSizeBytes: meta?.fileSizeBytes ?? video.fileSizeBytes ?? 0,
                    width: meta?.width ?? video.pixelWidth,
                    height: meta?.height ?? video.pixelHeight,
                    fps: meta?.fps ?? 0,
                    codecDescription: meta?.codecDescription ?? "未知",
                    thumbnailURL: thumbURL,
                    creationDate: nil
                )
                if markAsBatch { batchSelectedIDs.insert(item.id.uuidString) }
                appState.selectedVideos.append(item)
                AppLog.videoScan("已选择：\(video.filename)，\(Formatters.bytes(item.fileSizeBytes))")
            } catch {
                self.error = .videoReadFailed
            }
            exportingIDs.remove(video.id)
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

        if selected.count == 1, let est = estimates.first, let orig = selected.first?.fileSizeBytes {
            return "预计约 \(Formatters.bytes(est))（原 \(Formatters.bytes(orig))，以编码结果为准）"
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
        // 有任务因超时被跳过（已放弃并请求安全终止）时，允许直接开始新任务，不提示"任务占用"
        let canStart = (session.phase == .idle || session.phase == .completed || session.phase == .cancelled)
            || session.hasAbandonedStalledTask
        guard canStart else {
            error = .unknown("已有压缩任务在进行中")
            return
        }
        // 旧任务已被放弃（超时跳过）时不再阻塞新任务
        if session.isRunning, !session.hasAbandonedStalledTask { return }

        // 阈值规则只作用于「一键选择」纳入的项；手动选择不受影响
        let thresholdBytes = settings.skipSmallVideosEnabled
            ? Int64(settings.skipSmallVideosThresholdMB * 1024 * 1024) : nil
        if let th = thresholdBytes {
            let batch = selected.filter { batchSelectedIDs.contains($0.id.uuidString) }
            let isBelowThreshold: (VideoItem) -> Bool = { item in
                guard item.fileSizeBytes > 0 else { return false }   // 大小未知不跳过
                return item.fileSizeBytes < th                        // 严格小于才跳过
            }
            let skipped = batch.filter(isBelowThreshold)
            let kept = batch.filter { !isBelowThreshold($0) }
            if !skipped.isEmpty {
                launchRun(items: kept + selected.filter { !batchSelectedIDs.contains($0.id.uuidString) },
                          ruleSkipped: skipped)
                return
            }
        }
        launchRun(items: selected)
    }

    /// 一键选择：按当前排序取前 N 个（或全部）候选，逐个准备加入队列（显示真实进度）。
    private func applyBatchSelection(count: Int?, all: Bool) {
        let candidates = all ? scanner.videos : Array(scanner.videos.prefix(max(0, count ?? 0)))
        let thresholdBytes = settings.skipSmallVideosEnabled
            ? Int64(settings.skipSmallVideosThresholdMB * 1024 * 1024) : nil
        let willSkip = candidates.filter { v in
            guard let th = thresholdBytes, let sz = v.fileSizeBytes, sz > 0 else { return false }
            return sz < th
        }.count
        let willCompress = candidates.count - willSkip
        AppLog.ui("一键选择：候选 \(candidates.count)，预计跳过 \(willSkip)，准备压缩 \(willCompress)")

        batchPreparing = (0, candidates.count)
        Task {
            for (i, v) in candidates.enumerated() {
                if selected.contains(where: { $0.localIdentifier == v.id }) { continue }
                toggle(v, markAsBatch: true)
                batchPreparing = (i + 1, candidates.count)
                // 顺序准备，避免同时导出大量文件
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            batchPreparing = nil
        }
    }


    private func launchRun(items: [VideoItem], ruleSkipped: [VideoItem] = []) {
        guard !items.isEmpty else {
            error = .unknown("没有可压缩的视频")
            return
        }
        for item in items {
            guard item.fileSizeBytes > 0, item.durationSeconds > 0.2,
                  FileManager.default.fileExists(atPath: item.sourceURL.path) else {
                error = .videoReadFailed
                return
            }
        }
        AppLog.compress("selectedVideos=\(items.count)，规则跳过 \(ruleSkipped.count)，profile=\(profile.mode.displayName)")
        session.run(items: items, profile: profile, settings: settings, ruleSkipped: ruleSkipped) { startError in
            Task { @MainActor in error = startError }
        }
        appState.showProgressCover = true
    }
}

/// 扫描列表行：封面 + 名称 + 规格 + 已压缩徽章 + 勾选。
struct ScanVideoRow: View {
    let video: ScannedVideo
    let isSelected: Bool
    let isExporting: Bool
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
                    if isExporting {
                        ProgressView()
                            .frame(width: 52, height: 52)
                            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.filename).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(video.fileSizeBytes.map { Formatters.bytes($0) } ?? "大小未知") · \(Formatters.time(video.duration)) · \(video.resolutionText) · \(video.aspectText)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isExporting)
    }
}
