import SwiftUI

/// 批量结果列表（从完成总结点「查看结果」进入），点击行进入单条详情。
struct BatchResultView: View {
    let tasks: [CompressionTaskModel]
    var onContinue: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tasks) { task in
                    NavigationLink {
                        if let r = task.status.result {
                            ResultDetailPage(result: r, status: task.status)
                        } else {
                            failedDetail(task: task)
                        }
                    } label: {
                        TaskResultRow(task: task)
                        if task.id != tasks.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top) {
            HStack {
                Button { onContinue?() } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                Text("结果").font(.largeTitle.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if let onContinue {
                Button { onContinue() } label: {
                    Text("完成")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color.accentColor))
                .padding(.horizontal, 24)
                .padding(.bottom, 86)
            }
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
    }
}

/// 单个压缩结果详情（只读展示：状态、大小对比、技术参数）。
/// 保存/删除已由批量管道自动完成，这里仅呈现事实。
struct ResultDetailPage: View {
    let result: CompressionResult
    let status: TaskStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHeader
                sizeSection
                detailsSection
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .buttonStyle(.plain)
                Text(result.item.title).font(.largeTitle.bold()).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
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
            if let id = result.savedPhotoLocalIdentifier {
                InfoRow(title: "已保存", value: "照片图库 ✓")
                InfoRow(title: "资源标识", value: String(id.prefix(12)) + "…")
            }
        }
        .font(.subheadline)
    }
}
