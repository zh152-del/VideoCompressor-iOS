import SwiftUI

/// 压缩过程与完成总览（全屏覆盖）。
/// 运行中：动态状态（正在压缩 n/N、当前视频、已节省）；
/// 完成后：总结统计 + 查看结果 + 返回压缩。
struct CompressionProgressView: View {
    @ObservedObject var session: CompressionSession
    let onDone: () -> Void
    @State private var showDetails = false
    /// 用户手动上划查看历史日志时为 true（此时不再强制自动滚动到底部）
    @State private var userScrolledUp = false

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

    // MARK: - 运行中（大百分比 + 实时过程面板）

    private var runningView: some View {
        ScrollView {
            VStack(spacing: 14) {
                percentHeader
                if let current = session.currentTask {
                    currentTaskBlock(current)
                } else {
                    // 【修复】当前任务不存在时也必须显示明确状态，而不是让界面元素消失
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(session.isCancelling ? "正在取消…" : "等待下一个任务")
                            .font(.headline)
                        Text("已完成 \(session.finishedCount) / \(session.tasks.count)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
                if session.savedBytesSoFar > 0 {
                    Text("已节省 \(Formatters.bytes(session.savedBytesSoFar))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
                if session.blockedByUncertainTask {
                    Label("任务异常，无法确认安全终止：已阻止后续任务，请返回后重试", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                failuresBlock
                processLogPanel
                cancelButton
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    /// 放大的百分比 + 当前状态 + 任务序号（页面视觉中心）。
    private var percentHeader: some View {
        VStack(spacing: 6) {
            Text(percentText)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(stageStatusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let idx = session.currentIndex, !session.tasks.isEmpty {
                Text("第 \(idx + 1)/\(session.tasks.count) 个任务")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            // 总体进度（真实：已完成任务 + 当前任务帧进度）
            ProgressView(value: min(max(session.overallProgress, 0), 1))
                .padding(.horizontal, 30)
                .padding(.top, 2)
            HStack {
                Text("本任务耗时 \(Formatters.time(Int(session.currentTaskElapsed)))")
                Spacer()
                Text("批次耗时 \(Formatters.time(Int(session.batchElapsed)))")
            }
            .font(.caption2).foregroundStyle(.tertiary)
            .padding(.horizontal, 30)
        }
    }

    /// 真实百分比：来自编码器回调；处于结束阶段时显示 99%（不伪造 100%）。
    private var percentText: String {
        guard let t = session.currentTask else {
            return session.finishedCount > 0 ? "100%" : "0%"
        }
        switch t.status {
        case .compressing(let p):
            // 编码最后一帧后立即进入 finalizing，保留 99% 不跳 100%
            return "\(min(99, max(0, Int(p * 100))))%"
        case .finalizing, .validating, .saving:
            return "99%"
        case .success, .noGain:
            return "100%"
        case .skipped:
            return "跳过"
        case .failure:
            return "失败"
        case .cancelled:
            return "已取消"
        case .pending:
            return "0%"
        }
    }

    /// 统一状态文案（唯一数据源：任务状态）。
    private var stageStatusText: String {
        if session.isCancelling { return "正在取消…" }
        if session.recoveringTaskIndex != nil { return "正在恢复异常任务…" }
        guard let t = session.currentTask else {
            return session.finishedCount >= max(session.tasks.count, 1) ? "本批次处理完成" : "准备中"
        }
        switch t.status {
        case .pending: return "正在准备视频"
        case .compressing: return "正在编码"
        case .finalizing: return "正在结束编码"
        case .validating: return "正在验证输出"
        case .saving: return "正在保存到照片图库"
        case .success: return "已完成"
        case .noGain: return "未节省空间，已保留原视频"
        case .skipped: return "已跳过"
        case .failure: return "处理失败"
        case .cancelled: return "已取消"
        }
    }

    /// 当前任务卡片：封面 + 名称 + 输入/输出大小。
    private func currentTaskBlock(_ t: CompressionTaskModel) -> some View {
        VStack(spacing: 8) {
            AssetThumbnail(assetIdentifier: t.item.localIdentifier, side: 96)
                .id(t.id)
            Text(t.item.title).font(.subheadline.weight(.medium)).lineLimit(1)
            HStack(spacing: 10) {
                Text("输入 \(Formatters.bytes(t.item.fileSizeBytes))")
                if let out = session.currentOutputSize {
                    Text("输出 \(Formatters.bytes(out))")
                }
                Text(Formatters.time(t.item.durationSeconds))
            }
            .font(.caption2).foregroundStyle(.secondary)
            if case .compressing(let p) = t.status {
                ProgressBar(value: p).padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 失败视频列表（实时）。
    @ViewBuilder
    private var failuresBlock: some View {
        let failures = session.tasks.filter {
            if case .failure = $0.status { return true } else { return false }
        }
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("失败的视频（\(failures.count)）")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.red)
                ForEach(failures) { t in
                    HStack(spacing: 8) {
                        AssetThumbnail(assetIdentifier: t.item.localIdentifier, side: 32)
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
        }
    }

    /// 代码式实时过程面板（等宽字体；用户上划查看历史时不强制回到底部）。
    private var processLogPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("实时过程").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(session.liveLog.count) 条").font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.liveLog) { entry in
                            Text(line(for: entry))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: entry.stage))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 150)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: session.liveLog.count) { _, _ in
                    // 仅在用户未手动上划时自动滚到底
                    if !userScrolledUp, let last = session.liveLog.last {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .simultaneousGesture(
                    DragGesture().onChanged { _ in
                        withAnimation(.easeOut(duration: 0.05)) { userScrolledUp = true }
                    }
                )
            }
        }
    }

    private func line(for e: LiveLogEntry) -> String {
        let task = e.taskIndex > 0 ? "[任务 \(e.taskIndex)/\(max(e.taskTotal, e.taskIndex))] " : "[批次] "
        return "\(e.time) \(task)[\(e.stage)] \(e.text)"
    }

    private func color(for stage: String) -> Color {
        switch stage {
        case "失败": return .red
        case "警告", "恢复": return .orange
        case "完成": return .green
        case "取消": return .secondary
        default: return .primary
        }
    }

    private var cancelButton: some View {
        Button(role: .destructive) {
            session.cancel()
        } label: {
            Text(session.isCancelling ? "正在取消…" : "取消")
                .font(.body.weight(.medium))
                .foregroundStyle(session.isCancelling ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(session.isCancelling)
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
                if session.successCount > 0 {
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
                }

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
        case .skipped:
            Text("已跳过（规则排除）").foregroundStyle(.secondary)
        case .finalizing:
            Text("正在完成编码与写入…").foregroundStyle(.secondary)
        case .validating:
            Text("正在验证输出…").foregroundStyle(.secondary)
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
