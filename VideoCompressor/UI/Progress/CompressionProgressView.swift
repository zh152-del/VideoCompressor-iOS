import SwiftUI

/// 压缩过程与完成总览（全屏覆盖）。
/// 运行中：动态状态（正在压缩 n/N、当前视频、已节省）；
/// 完成后：总结统计 + 查看结果 + 返回压缩。
struct CompressionProgressView: View {
    @ObservedObject var session: CompressionSession
    let onDone: () -> Void
    @State private var showDetails = false

    var body: some View {
        NavigationStack {
            Group {
                if session.isRunning {
                    runningView
                } else if session.cancelled {
                    cancelledView
                } else {
                    summaryView
                }
            }
            // 【修复】navigationDestination 必须挂在 NavigationStack 内的稳定节点上。
            // 原先挂在 summaryView（if/else 条件分支内），任务结束分支切换时注册失效 →
            // 「查看结果」点击无响应。
            .navigationDestination(isPresented: $showDetails) {
                BatchResultView(tasks: session.tasks, onContinue: onDone)
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .alert(session.error?.errorDescription ?? "", isPresented: Binding(
                get: { session.error != nil },
                set: { if !$0 { session.error = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                if let e = session.error { Text(e.recoverySuggestion) }
            }
        }
    }

    // MARK: - 运行中

    private var runningView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("正在压缩").font(.title2.bold())
                Text("\(session.finishedCount) / \(session.tasks.count)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 60)

            if let current = session.currentTask {
                VStack(spacing: 6) {
                    // 当前压缩视频封面：按 task.id 绑定，任务切换自动换图，异步结果不串图
                    AssetThumbnail(assetIdentifier: current.item.localIdentifier, side: 120)
                        .id(current.id)
                    Text("当前压缩视频").font(.caption).foregroundStyle(.secondary)
                    Text(current.item.title).font(.headline).lineLimit(1)
                    // 阶段文案：让用户知道 App 正在工作，不是卡死
                    Text(stageText(for: current))
                        .font(.caption).foregroundStyle(.secondary)
                    if current.status.isCompressing {
                        ProgressBar(value: current.progressValue)
                            .padding(.horizontal, 40)
                            .padding(.top, 6)
                    }
                }
                .padding(.top, 20)
            }

            if session.savedBytesSoFar > 0 {
                Text("已节省 \(Formatters.bytes(session.savedBytesSoFar))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.top, 16)
            }

            // 失败视频列表：实时更新（每失败一个立即出现，不等批次结束）
            let failures = session.tasks.filter {
                if case .failure = $0.status { return true } else { return false }
            }
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("失败的视频（\(failures.count)）")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.red)
                    ForEach(failures) { t in
                        HStack(spacing: 8) {
                            AssetThumbnail(assetIdentifier: t.item.localIdentifier, side: 36)
                                .id(t.id)
                            Text(t.item.title).font(.caption).lineLimit(1)
                            Spacer()
                            if case .failure(let e) = t.status {
                                Text(e.errorDescription).font(.caption2).foregroundStyle(.red).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.top, 14)
            }

            Spacer()

            Button(role: .destructive) {
                session.cancel()
            } label: {
                Text("取消")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
    }

    /// 当前阶段文案。
    private func stageText(for task: CompressionTaskModel) -> String {
        switch task.status {
        case .compressing(let p):
            return "\(Formatters.bytes(task.item.fileSizeBytes)) → 编码中… \(Formatters.percent(p))"
        case .saving:
            return "编码完成，验证输出并保存到照片…"
        default:
            return "准备中…"
        }
    }

    // MARK: - 完成总结

    private var summaryView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("压缩完成").font(.title2.bold())
                Text("\(session.tasks.count) 个视频")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 56)

            VStack(spacing: 8) {
                countRow(text: "成功压缩 \(session.successCount) 个（已保存到照片）", color: .green)
                if session.skippedCount > 0 {
                    countRow(text: "已跳过 \(session.skippedCount) 个（规则排除，未压缩）", color: .secondary)
                }
                if session.noGainCount > 0 {
                    countRow(text: "未节省空间 \(session.noGainCount) 个（原视频已保留）", color: .orange)
                }
                if session.failureCount > 0 {
                    countRow(text: "失败 \(session.failureCount) 个（原视频已保留）", color: .red)
                }
                if !session.deletedOriginalIDs.isEmpty {
                    countRow(text: "原视频已删除 \(session.deletedOriginalIDs.count) 个", color: .secondary)
                }
            }
            .padding(.top, 22)

            // 手动批量删除 / 重试删除：一次性删除全部「已成功保存到 Photos」的原视频
            if !session.pendingDeleteIDs.isEmpty {
                Button {
                    Task { await session.deletePendingOriginals() }
                } label: {
                    Text("删除原视频（\(session.pendingDeleteIDs.count)）")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, 24)
                .padding(.top, 14)
            }

            if session.successCount > 0 {
                VStack(spacing: 10) {
                    statRow(title: "原始大小", value: Formatters.bytes(session.totalOriginalBytes))
                    statRow(title: "压缩后", value: Formatters.bytes(session.totalCompressedBytes))
                    Divider()
                    let saved = session.totalOriginalBytes - session.totalCompressedBytes
                    let pct = session.totalOriginalBytes > 0
                        ? Double(saved) / Double(session.totalOriginalBytes) * 100 : 0
                    HStack {
                        Text("节省").font(.headline).foregroundStyle(.green)
                        Spacer()
                        Text("\(Formatters.bytes(saved)) · \(String(format: "%.1f%%", pct))")
                            .font(.headline).foregroundStyle(.green)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .floatSurface(cornerRadius: 18)
                .padding(.horizontal, 24)
                .padding(.top, 26)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    AppLog.ui("点击：查看结果")
                    showDetails = true
                } label: {
                    Text("查看结果")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color.accentColor))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    onDone()
                } label: {
                    Text("返回压缩")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
    }

    private func countRow(text: String, color: Color) -> some View {
        Text(text).font(.subheadline.weight(.medium)).foregroundStyle(color)
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 已取消

    private var cancelledView: some View {
        VStack(spacing: 10) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("已取消").font(.headline)
            Text("压缩任务已停止，临时文件已清理，原视频未受影响。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onDone()
            } label: {
                Text("返回压缩")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// 单个任务结果行（结果列表用）。
struct TaskResultRow: View {
    let task: CompressionTaskModel

    var body: some View {
        HStack(spacing: 12) {
            AsyncThumbnail(url: task.item.thumbnailURL)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(task.item.title).font(.subheadline).lineLimit(1)
                statusText.font(.caption)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusText: some View {
        switch task.status {
        case .success(let r):
            Text(Formatters.sizeChangeText(original: r.item.fileSizeBytes, compressed: r.outputSizeBytes))
                .foregroundStyle(.green)
        case .noGain(let r):
            Text("\(Formatters.bytes(r.item.fileSizeBytes)) → \(Formatters.bytes(r.outputSizeBytes)) · 未节省空间")
                .foregroundStyle(.orange)
        case .failure(let e):
            Text(e.errorDescription).foregroundStyle(.red)
        case .saving:
            Text("保存到照片…").foregroundStyle(.secondary)
        case .cancelled:
            Text("已取消").foregroundStyle(.secondary)
        case .pending:
            Text("等待中").foregroundStyle(.secondary)
        case .compressing(let p):
            Text("压缩中 \(Formatters.percent(p))").foregroundStyle(.secondary)
        }
    }
}
