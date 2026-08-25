import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    EmptyStateView(systemImage: "clock", title: "暂无压缩历史",
                                   message: "压缩完成的视频会记录在这里，便于查看与对比。")
                } else {
                    List {
                        ForEach(history.entries) { entry in
                            HistoryRow(entry: entry)
                        }
                        .onDelete { indexSet in
                            indexSet.map { history.entries[$0].id }.forEach { history.remove($0) }
                        }
                    }
                }
            }
            .navigationTitle("压缩历史")
            .toolbar {
                if !history.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空") { confirmClear = true }
                    }
                }
            }
            .alert("清空全部历史？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { history.clear() }
            } message: {
                Text("此操作仅删除本地记录，不会影响已保存到照片图库中的视频。")
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text(Formatters.savedPercent(entry.compressionRatio)).font(.subheadline).foregroundStyle(.green)
            }
            HStack {
                Text("\(Formatters.bytes(entry.originalBytes)) → \(Formatters.bytes(entry.compressedBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(entry.mode).font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
