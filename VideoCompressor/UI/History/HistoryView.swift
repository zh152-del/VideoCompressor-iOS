import SwiftUI

/// 历史页：按日期分组（今天/昨天/M月d日）的滚动列表，低视觉噪音。
/// 有效压缩 → 绿色「节省 x MB · x%」；未节省空间 → 橙色；真实字节计算，绝无「约 0.0%」。
struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var confirmClear = false

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
                        HistoryRow(entry: entry)
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
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("历史").font(.largeTitle.bold())
                        Text("共 \(history.entries.count) 条记录")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !history.entries.isEmpty {
                        Button("清空") { confirmClear = true }
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .background(Color(.systemGroupedBackground))
            }
    }
}

/// 历史条目行：缩略图 + 名称 + 大小变化 + 右侧状态。
struct HistoryRow: View {
    let entry: HistoryEntry

    private var isNoGain: Bool { entry.compressedBytes >= entry.originalBytes }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(Formatters.bytes(entry.originalBytes)) → \(Formatters.bytes(entry.compressedBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Formatters.sizeChangeText(original: entry.originalBytes,
                                               compressed: entry.compressedBytes))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isNoGain ? Color.orange : Color.green)
            }
            Spacer()
            Text(isNoGain ? "未节省" : "已完成")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
