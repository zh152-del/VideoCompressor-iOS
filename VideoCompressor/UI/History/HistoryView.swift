import SwiftUI

/// 历史页：封面 + 日期分组 + 原视频删除管理。
/// 数据关系：删除按钮只针对 originalAssetIdentifier（原视频）；
/// 压缩成品（outputAssetIdentifier / savedAssetLocalIdentifier）永远保留在 Photos；
/// 删除原视频不删除历史记录本身。
struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var confirmClear = false
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteSingle: HistoryEntry?
    @State private var deleting = false

    /// 待删除数量：严格等于「压缩成功 + 已保存 Photos + 有可靠标识 + 未删除」的记录数。
    private var pendingDeleteCount: Int { history.deletableEntries.count }

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("清空全部历史？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { history.clear() }
            } message: {
                Text("此操作仅删除本地记录，不会影响已保存到照片图库中的视频。")
            }
            // 一键删除：只弹一次确认
            .confirmationDialog("确定删除 \(pendingDeleteCount) 个原视频吗？",
                                isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("删除 \(pendingDeleteCount) 个原视频", role: .destructive) {
                    Task {
                        deleting = true
                        let n = await history.deleteAllOriginalVideos()
                        TempFileManager.shared.cleanupAll()   // 清理 App 自建临时文件（仅 VideoCompressor/ 目录）
                        AppLog.history("一键删除完成：\(n) 个")
                        deleting = false
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除压缩成功且已保存到照片图库的原始视频。压缩后的视频与历史记录会保留。")
            }
            // 单条删除确认
            .confirmationDialog("确定删除这个原视频吗？",
                                isPresented: Binding(
                                    get: { confirmDeleteSingle != nil },
                                    set: { if !$0 { confirmDeleteSingle = nil } }
                                ), titleVisibility: .visible) {
                Button("删除原视频", role: .destructive) {
                    guard let entry = confirmDeleteSingle else { return }
                    Task {
                        deleting = true
                        await history.deleteOriginal(entryID: entry.id)
                        TempFileManager.shared.cleanupAll()
                        deleting = false
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除原始视频，压缩后的视频会保留在照片图库中。")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("暂无历史").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            Text("压缩完成的视频会记录在这里").font(.subheadline).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        List {
            ForEach(groups, id: \.label) { group in
                Section {
                    ForEach(group.entries) { entry in
                        HistoryRow(entry: entry,
                                   onDelete: entry.canDeleteOriginal ? { confirmDeleteSingle = entry } : nil)
                    }
                    .onDelete { offsets in
                        offsets.map { group.entries[$0].id }.forEach { history.remove($0) }
                    }
                } header: {
                    let saved = group.entries.reduce(Int64(0)) { $0 + max($1.savedBytes, 0) }
                    if saved > 0 {
                        Text("\(group.label) · 节省 \(Formatters.bytes(saved))")
                    } else {
                        Text(group.label)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("历史").font(.largeTitle.bold())
                        Text("共 \(history.entries.count) 条记录")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清空") { confirmClear = true }
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                // 顶部一键删除：数量动态计算，只统计「可删除」的记录
                if pendingDeleteCount > 0 {
                    Button {
                        confirmDeleteAll = true
                    } label: {
                        Text(deleting ? "删除中…" : "一键删除原视频（\(pendingDeleteCount)）")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(deleting)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .onAppear {
            // 同步系统照片 App 中的外部删除（只检查记录引用的 Asset ID，不扫全库）
            history.syncOriginalsWithPhotos()
        }
    }

    /// 按天分组（保持倒序）。
    private var groups: [(label: String, entries: [HistoryEntry])] {
        var ordered: [Date: [HistoryEntry]] = [:]
        for e in history.entries {
            ordered[DateGrouper.dayKey(for: e.date), default: []].append(e)
        }
        return ordered.keys.sorted(by: >).map { day in
            let entries = ordered[day] ?? []
            return (DateGrouper.label(for: entries[0].date), entries)
        }
    }
}

/// 历史条目行：封面 + 名称 + 大小变化 + 原视频状态 + 单条删除。
struct HistoryRow: View {
    let entry: HistoryEntry
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // 封面：优先压缩成品 PHAsset（outputAssetIdentifier）；失败记录用占位图
            AssetThumbnail(assetIdentifier: entry.savedAssetLocalIdentifier, side: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)

                if entry.outcome == "failed" {
                    Text("\(Formatters.bytes(entry.originalBytes)) · 压缩失败")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("\(Formatters.bytes(entry.originalBytes)) → \(Formatters.bytes(entry.compressedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.sizeChangeText(original: entry.originalBytes,
                                                   compressed: entry.compressedBytes))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(entry.isEffective ? Color.green : Color.orange)
                }

                Text("\(DateGrouper.label(for: entry.date)) \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if let onDelete {
                    Button(action: onDelete) {
                        Text("删除原视频")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.secondarySystemBackground),
                                        in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var statusLabel: String {
        switch entry.outcome {
        case "failed":  return "压缩失败"
        case "noGain":  return "未节省空间"
        default:
            return entry.originalDeleteStatus == "deleted" ? "原视频已删除" : "原视频未删除"
        }
    }

    private var statusColor: Color {
        switch entry.outcome {
        case "failed":  return .red
        case "noGain":  return .orange
        default:
            return entry.originalDeleteStatus == "deleted" ? Color.secondary : Color.green
        }
    }
}
