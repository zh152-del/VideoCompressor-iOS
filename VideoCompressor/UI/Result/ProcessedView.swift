import SwiftUI
import AVKit
import Photos

/// 已压页面：集中展示「已压缩完成 / 规则跳过 / 失败」的记录，并提供结果查看与独立删除入口。
/// 不从首页移除任何视频；不自动删除任何 Photos 资源。
struct ProcessedView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, compressed, skipped, failed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .compressed: return "已压缩"
            case .skipped: return "已跳过"
            case .failed: return "失败"
            }
        }
    }

    private var items: [HistoryEntry] {
        switch filter {
        case .all: return history.entries
        case .compressed: return history.entries.filter { $0.outcome == "saved" }
        case .skipped: return history.entries.filter { $0.outcome == "noGain" }
        case .failed: return history.entries.filter { $0.outcome == "failed" }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    VStack(spacing: 8) {
                        Text("暂无记录").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                        Text("压缩完成或被跳过的视频会出现在这里")
                            .font(.subheadline).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.large)
            .navigationTitle("已压")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("分类", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { entry in
                        NavigationLink {
                            ResultDetailView(entryID: entry.id)
                        } label: {
                            ProcessedRow(entry: entry)
                        }
                        .buttonStyle(PressableButtonStyle())
                        if entry.id != items.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// 已压列表行：封面 + 名称 + 大小 + 时长 + 状态 + 跳过原因。
struct ProcessedRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnail(assetIdentifier: entry.savedAssetLocalIdentifier ?? entry.originalAssetIdentifier,
                           side: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
                if entry.outcome == "failed" {
                    Text("\\(Formatters.bytes(entry.originalBytes)) · 压缩失败")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("\\(Formatters.bytes(entry.originalBytes)) → \\(Formatters.bytes(entry.compressedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.sizeChangeText(original: entry.originalBytes, compressed: entry.compressedBytes))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(entry.isEffective ? Color.green : Color.orange)
                }
                if entry.outcome == "noGain" {
                    Text("跳过原因：压缩后未节省空间（原视频保留）")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if entry.originalDeleteStatus == "deleted" {
                    Text("原视频已删除").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var statusLabel: String {
        switch entry.outcome {
        case "failed": return "失败"
        case "noGain": return "已跳过"
        default: return "已压缩"
        }
    }
    private var statusColor: Color {
        switch entry.outcome {
        case "failed": return .red
        case "noGain": return .orange
        default: return .green
        }
    }
}

/// 压缩结果详情页（独立页面）：
/// 原视频 / 压缩成品 前后对比（前 10 秒，各自独立播放）+ 两个独立删除按钮。
struct ResultDetailView: View {
    @EnvironmentObject var history: HistoryStore
    let entryID: UUID

    @State private var confirmDeleteOriginal = false
    @State private var confirmDeleteCompressed = false
    @State private var deleteError: String?

    private var entry: HistoryEntry? { history.entries.first { $0.id == entryID } }

    var body: some View {
        ScrollView {
            if let e = entry {
                VStack(alignment: .leading, spacing: 18) {
                    summary(e)
                    previewSection(title: "原视频", assetID: e.originalAssetIdentifier,
                                   name: e.name, fallback: "原视频不可用")
                    previewSection(title: "压缩成品", assetID: e.savedAssetLocalIdentifier,
                                   name: e.compressedFilename ?? "压缩成品",
                                   fallback: "压缩成品不可用")
                    deleteSection(e)
                    if let err = deleteError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            } else {
                Text("记录不存在").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("压缩结果")
        .background(Color(.systemBackground))
        .confirmationDialog("确定删除原视频《\(entry?.name ?? "")》？",
                            isPresented: $confirmDeleteOriginal, titleVisibility: .visible) {
            Button("删除原视频", role: .destructive) {
                guard let e = entry else { return }
                Task { await history.deleteOriginal(entryID: e.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将从照片图库删除原视频，不影响压缩成品。")
        }
        .confirmationDialog("确定删除压缩成品《\(entry?.compressedFilename ?? "")》？",
                            isPresented: $confirmDeleteCompressed, titleVisibility: .visible) {
            Button("删除压缩成品", role: .destructive) {
                guard let e = entry else { return }
                Task {
                    do { try await history.deleteCompressed(entryID: e.id) }
                    catch { deleteError = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将从照片图库删除压缩成品，不影响原视频。")
        }
    }

    private func summary(_ e: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("原视频", Formatters.bytes(e.originalBytes))
            row("压缩后", Formatters.bytes(e.compressedBytes))
            row("节省", Formatters.sizeChangeText(original: e.originalBytes, compressed: e.compressedBytes))
            row("原分辨率", e.sourceResolution)
            row("输出分辨率", e.outputResolution)
            row("时长", Formatters.time(e.durationSeconds))
            row("状态", statusText(e))
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack {
            Text(t).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.subheadline.weight(.medium))
        }
    }

    private func statusText(_ e: HistoryEntry) -> String {
        switch e.outcome {
        case "failed": return "压缩失败"
        case "noGain": return "未节省空间（原视频保留）"
        default:
            return e.originalDeleteStatus == "deleted" ? "已压缩 · 原视频已删除" : "已压缩"
        }
    }

    @ViewBuilder
    private func previewSection(title: String, assetID: String?, name: String, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let id = assetID, !id.isEmpty,
               PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0 {
                VideoPreview(assetIdentifier: id)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 120)
                    .overlay(Text(fallback).font(.subheadline).foregroundStyle(.secondary))
            }
        }
    }

    private func deleteSection(_ e: HistoryEntry) -> some View {
        VStack(spacing: 10) {
            Button {
                confirmDeleteOriginal = true
            } label: {
                deleteLabel("删除原视频", enabled: history.originalAssetExists(e))
            }
            Button {
                confirmDeleteCompressed = true
            } label: {
                deleteLabel("删除压缩成品", enabled: history.compressedAssetExists(e))
            }
        }
    }

    private func deleteLabel(_ title: String, enabled: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(enabled ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// 视频前 10 秒预览（按需加载，退出即释放；两个预览各自独立播放器）。
struct VideoPreview: View {
    let assetIdentifier: String
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        // 只播放开头 10 秒，不加载完整视频
                        player.seek(to: .zero)
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                        self.player = nil     // 释放播放器与解码器
                    }
            } else {
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.06))
                    ProgressView()
                }
            }
        }
        .task(id: assetIdentifier) {
            guard player == nil else { return }
            guard let url = await Self.playableURL(assetIdentifier: assetIdentifier) else { return }
            let p = AVPlayer(url: url)
            p.actionAtItemEnd = .pause
            // 只对比开头 10 秒（不足 10 秒则播放到结尾）
            p.currentItem?.forwardPlaybackEndTime = CMTime(seconds: 10, preferredTimescale: 600)
            player = p
        }
    }

    /// 通过 PHImageManager 拿视频 URL（AVAsset 从 Photos 打开更轻量）。
    private static func playableURL(assetIdentifier: String) async -> URL? {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            return nil
        }
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: phAsset,
                                                    options: options) { asset, _, _ in
                if let urlAsset = asset as? AVURLAsset {
                    cont.resume(returning: urlAsset.url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
