import SwiftUI

/// 主页「压缩」：顶部大标题 + 简洁空状态 / 已选视频列表 + 压缩方式 + 底部悬浮玻璃操作区。
struct HomeView: View {
    @EnvironmentObject var temp: TempFileManager
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var session = CompressionSession()
    @State private var selected: [VideoItem] = []
    @State private var profile = CompressionProfile()
    @State private var showPicker = false
    @State private var showProgress = false
    @State private var showSettingsPage = false
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    mainContent
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, selected.isEmpty ? 40 : 140)
            }
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                // 底部悬浮玻璃操作区：仅已选视频时出现，避开底部玻璃导航
                if !selected.isEmpty && !showProgress {
                    bottomBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 86)
                }
            }
            .sheet(isPresented: $showPicker) {
                VideoPicker(onPicked: { items in
                    selected.append(contentsOf: items)
                }, temp: temp)
            }
            .fullScreenCover(isPresented: $showProgress) {
                CompressionProgressView(session: session) {
                    showProgress = false
                    selected.removeAll()
                }
                .environmentObject(temp)
                .environmentObject(settings)
            }
            .navigationDestination(isPresented: $showSettingsPage) {
                CompressionSettingsPage(profile: $profile)
            }
            .alert(error?.errorDescription ?? "", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                if let e = error { Text(e.recoverySuggestion) }
            }
            .onAppear { profile.mode = settings.defaultMode }
        }
    }

    // MARK: - 顶部大标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("压缩").font(.largeTitle.bold())
            Text("本地处理 · 不上传 · 无需账号")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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

    /// 空状态：极简，仅文字 + 一个适中尺寸的胶囊按钮（不占满屏宽）。
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("还没有视频")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("选择照片图库中的视频开始压缩")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            GlassCapsuleButton(title: "选择视频", systemImage: "plus") {
                showPicker = true
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 130)
    }

    /// 已选视频列表（纵向滚动、轻分隔线、小圆角缩略图、右侧状态）。
    private var selectedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已选择 \(selected.count) 个视频")
                .font(.headline)
                .padding(.bottom, 8)

            ForEach(selected) { item in
                VideoRow(item: item) {
                    selected.removeAll { $0.id == item.id }
                }
                if item.id != selected.last?.id {
                    Divider().padding(.leading, 64)
                }
            }

            compressionMethodRow
                .padding(.top, 20)
        }
    }

    /// 压缩方式入口 + 预估结果。
    private var compressionMethodRow: some View {
        Button { showSettingsPage = true } label: {
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
        .buttonStyle(.plain)
    }

    /// 预估文案：单个 → 「428 MB → 约 180 MB」；多个 → 「预计节省约 1.2 GB」。
    private var estimateText: String {
        let estimates = selected.compactMap { item -> Int64? in
            BitrateCalculator.estimateOutputBytes(fileSizeBytes: item.fileSizeBytes,
                                                  durationSeconds: item.durationSeconds,
                                                  height: item.height, fps: item.fps,
                                                  mode: profile.mode, custom: profile.custom)
        }
        let originals = selected.map { $0.fileSizeBytes }
        let totalOriginal = originals.reduce(Int64(0), +)
        let totalEstimate = estimates.reduce(Int64(0), +)
        let uncompressible = selected.count - estimates.count

        if selected.count == 1, let est = estimates.first, let orig = originals.first {
            return "\(Formatters.bytes(orig)) → 约 \(Formatters.bytes(est)) · 实际以编码后文件为准"
        }
        if totalEstimate < totalOriginal {
            let saved = totalOriginal - totalEstimate
            var text = "预计节省约 \(Formatters.bytes(saved))"
            if uncompressible > 0 {
                text += " · \(uncompressible) 个可能无法压缩"
            }
            return text
        }
        return "所选视频码率已较低，可能无法再压缩"
    }

    // MARK: - 底部悬浮操作区（玻璃）

    private var bottomBar: some View {
        VStack(spacing: 12) {
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
                Text("开始压缩")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.accentColor))
        }
        .padding(16)
        .glassPanel(cornerRadius: 22)
    }

    private func startCompression() {
        session.run(items: selected, profile: profile, settings: settings)
        showProgress = true
    }
}
