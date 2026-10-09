import SwiftUI

/// 批量结果列表（从完成总结点「查看结果」push 进入），点击行进入单条详情。
/// 使用系统导航栏 + 系统返回，保证返回手势与返回按钮始终可用。
struct BatchResultView: View {
    @EnvironmentObject var history: HistoryStore
    let tasks: [CompressionTaskModel]
    var onContinue: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tasks) { task in
                    NavigationLink {
                        resultDetail(for: task)
                    } label: {
                        TaskResultRow(task: task)
                        if task.id != tasks.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("结果")
        .safeAreaInset(edge: .bottom) {
            if let onContinue {
                Button { onContinue() } label: {
                    Text("完成")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
    }

    /// 有有效压缩记录 → 进入独立结果详情页（对比 + 独立删除）；
    /// 无记录（失败/跳过/无成品）→ 显示明确状态，不空白、不闪退。
    @ViewBuilder
    private func resultDetail(for task: CompressionTaskModel) -> some View {
        if let r = task.status.result,
           let savedID = r.savedPhotoLocalIdentifier,
           let entry = history.entries.first(where: { $0.savedAssetLocalIdentifier == savedID }) {
            ResultDetailView(entryID: entry.id)
        } else {
            noResultDetail(task)
        }
    }

    private func noResultDetail(_ task: CompressionTaskModel) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(task.item.title).font(.headline)
            Text(statusMessage(task.status))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("结果")
    }

    private func statusMessage(_ status: TaskStatus) -> String {
        switch status {
        case .skipped: return "该视频被规则跳过，没有压缩结果"
        case .cancelled: return "该视频已取消"
        case .pending: return "该视频尚未处理"
        case .compressing: return "该视频正在压缩"
        case .saving: return "该视频正在保存"
        case .noGain: return "压缩后未节省空间，没有保存结果（原视频已保留）"
        case .failure(let e): return "压缩失败：\(e.errorDescription)"
        default: return "暂无结果记录"
        }
    }

    private func failedDetail(task: CompressionTaskModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36)).foregroundStyle(.red)
            Text(task.item.title).font(.headline)
            if case .failure(let e) = task.status {
                Text(e.errorDescription).font(.subheadline).foregroundStyle(.secondary)
                Text(e.recoverySuggestion).font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("详情")
    }
}

/// 单个压缩结果详情（只读展示：状态、大小对比、技术参数）。
/// 保存已由管道自动完成；自动删除关闭时，提供手动「删除原视频」入口（仅保存成功后可用）。
struct ResultDetailPage: View {
    let result: CompressionResult
    let status: TaskStatus
    @EnvironmentObject var settings: SettingsStore
    @State private var deleted = false
    @State private var deleting = false
    @State private var deleteError: String?

    private var canManualDelete: Bool {
        if case .success = status {} else { return false }
        return deleted == false &&
               settings.deleteOriginalAfterSave == false &&
               (result.item.localIdentifier ?? "").isEmpty == false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHeader
                sizeSection
                manualDeleteSection
                detailsSection
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(result.item.title)
    }

    @ViewBuilder
    private var manualDeleteSection: some View {
        if canManualDelete {
            VStack(spacing: 8) {
                Button {
                    deleting = true
                    Task {
                        do {
                            guard let orig = result.item.localIdentifier else { return }
                            AppLog.delete("Delete started（手动）：\(result.item.title)")
                            try await PhotoLibraryService.shared.deleteOriginal(localIdentifier: orig)
                            AppLog.delete("Delete succeeded（手动）：\(result.item.title)")
                            deleted = true
                        } catch {
                            AppLog.delete("Delete failed（手动）：\(error.localizedDescription)")
                            deleteError = error.localizedDescription
                        }
                        deleting = false
                    }
                } label: {
                    Label(deleting ? "删除中…" : "删除原视频", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(deleting)
                if let err = deleteError {
                    Text("删除失败：\(err)。原视频仍保留在照片图库中。")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        } else if deleted {
            Label("原视频已删除", systemImage: "trash.fill")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch status {
        case .success:
            Label("已保存到照片图库", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
        case .noGain:
            Label("未节省空间（原视频已保留）", systemImage: "exclamationmark.circle.fill")
                .font(.headline).foregroundStyle(.orange)
        case .failure(let e):
            Label("失败：\(e.errorDescription)", systemImage: "xmark.circle.fill")
                .font(.headline).foregroundStyle(.red)
        default:
            Label(status.title, systemImage: "info.circle")
                .font(.headline).foregroundStyle(.secondary)
        }
    }

    private var sizeSection: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text("原始大小").font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.bytes(result.item.fileSizeBytes))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(result.noGain ? "尝试压缩后" : "压缩后").font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.bytes(result.outputSizeBytes))
                        .font(.title3.weight(.semibold))
                }
            }
            Divider()
            HStack {
                Text(Formatters.sizeChangeText(original: result.item.fileSizeBytes,
                                               compressed: result.outputSizeBytes))
                    .font(.headline)
                    .foregroundStyle(result.isEffective ? Color.green : Color.orange)
                Spacer()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detailsSection: some View {
        VStack(spacing: 8) {
            InfoRow(title: "原始分辨率", value: "\(result.item.width)×\(result.item.height)")
            InfoRow(title: "输出分辨率", value: "\(result.outputWidth)×\(result.outputHeight)")
            InfoRow(title: "原始编码", value: result.item.codecDescription)
            InfoRow(title: "输出编码", value: result.outputCodec)
            InfoRow(title: "压缩模式", value: result.profile.modeDisplayName)
            InfoRow(title: "视频时长", value: Formatters.time(result.durationSeconds))
            if result.savedPhotoLocalIdentifier != nil {
                InfoRow(title: "已保存", value: "照片图库 ✓")
            }
        }
        .font(.subheadline)
    }
}
