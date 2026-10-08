import SwiftUI
import Photos

/// 已完成组列表（二级页面，用户从首页主动进入）。
/// 「移出」= 修改 App 内部归属状态；绝不删除视频、绝不触碰 __VC__ 标记。
struct CompletedGroupsView: View {
    @ObservedObject private var store = GroupStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.records.isEmpty {
                    Text("暂无已完成组").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 100)
                } else {
                    ForEach(store.records) { record in
                        NavigationLink {
                            GroupDetailView(record: record)
                        } label: {
                            GroupCard(record: record)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .foregroundStyle(.primary)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.large)
        .navigationTitle("已完成组")
        .background(Color(.systemBackground))
    }
}

private struct GroupCard: View {
    let record: GroupRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("第\(record.index + 1)组").font(.headline)
                Text("\(record.totalCount) 个视频 · \(DateGrouper.label(for: record.date))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("成功：\(record.succeeded) · 失败：\(record.failed) · 跳过：\(record.skipped)")
                    .font(.caption).foregroundStyle(.secondary)
                if record.markFailedCount > 0 {
                    Text("标记失败：\(record.markFailedCount) 个").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text("查看本组")
                .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 单个已完成组详情：全部视频（含已移出的标记）+ 多选移出。
struct GroupDetailView: View {
    @ObservedObject private var store = GroupStore.shared
    let record: GroupRecord

    @State private var selectedIDs: Set<String> = []
    @State private var confirmRemove = false
    @State private var removeProgress: (done: Int, total: Int)? = nil

    /// 当前记录（移出后实时刷新）。
    private var current: GroupRecord? { store.records.first { $0.index == record.index } }
    private var items: [GroupItemSnapshot] { current?.items ?? record.items }
    private var activeItems: [GroupItemSnapshot] { items.filter { !$0.removed } }
    private var succeededCount: Int { activeItems.filter { $0.outcome == "saved" }.count }
    private var failedCount: Int { activeItems.filter { $0.outcome == "failed" }.count }
    private var skippedCount: Int { activeItems.filter { $0.outcome == "skipped" }.count }
    private var removedCount: Int { items.filter { $0.removed }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if let p = removeProgress {
                    Text("正在移出已完成组 \(p.done) / \(p.total)")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        GroupItemRow(item: item,
                                     isSelected: selectedIDs.contains(item.assetID),
                                     onToggle: { toggle(item) },
                                     onRemove: item.removed == false ? { selectedIDs = [item.assetID]; confirmRemove = true } : nil)
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.large)
        .navigationTitle("第\(record.index + 1)组")
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            if !selectedIDs.isEmpty && removeProgress == nil {
                Button {
                    confirmRemove = true
                } label: {
                    Text("移出所选（\(selectedIDs.count)）")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color.accentColor))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
        .confirmationDialog("确定移出 \(selectedIDs.count) 个视频？",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("确认移出", role: .destructive) {
                Task { await removeSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移出后：该视频会从已完成组中移除，但不会删除视频，也不会清除 __VC__ 标记。")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(record.totalCount) 个视频").font(.headline)
            Text("成功：\(succeededCount) · 失败：\(failedCount) · 跳过：\(skippedCount)")
                .font(.subheadline).foregroundStyle(.secondary)
            if removedCount > 0 {
                Text("已移出：\(removedCount) 个（仍可在首页重新压缩，__VC__ 标记保持不变）")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func toggle(_ item: GroupItemSnapshot) {
        if item.removed { return }
        if selectedIDs.contains(item.assetID) {
            selectedIDs.remove(item.assetID)
        } else {
            selectedIDs.insert(item.assetID)
        }
    }

    /// 批量移出：显示真实进度（逐个更新），只改组归属，不动视频与标记。
    private func removeSelected() async {
        let ids = selectedIDs
        removeProgress = (0, ids.count)
        var done = 0
        for id in ids {
            await Task.yield()
            _ = store.removeItems(groupIndex: record.index, assetIDs: [id])
            done += 1
            removeProgress = (done, ids.count)
        }
        selectedIDs.removeAll()
        removeProgress = nil
    }
}

/// 组内视频行。
private struct GroupItemRow: View {
    let item: GroupItemSnapshot
    let isSelected: Bool
    let onToggle: () -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .center) {
                AssetThumbnail(assetIdentifier: item.savedAssetID ?? item.assetID, side: 44)
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).font(.subheadline.weight(.medium)).lineLimit(1)
                switch item.outcome {
                case "saved":
                    Text("\(Formatters.bytes(item.originalBytes)) → \(Formatters.bytes(item.compressedBytes ?? 0)) · 节省 \(Formatters.bytes(max(item.originalBytes - (item.compressedBytes ?? 0), 0)))")
                        .font(.caption).foregroundStyle(.secondary)
                case "failed":
                    Text("压缩失败").font(.caption).foregroundStyle(.red)
                default:
                    Text("已跳过").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(ProcessedMark.isProcessed(filename: item.filename) ? "__VC__ ✓" : "无标记")
                        .font(.caption2).foregroundStyle(.secondary)
                    if item.removed {
                        Text("已移出本组").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if let onRemove {
                Button(action: onRemove) {
                    Text("移出")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}
