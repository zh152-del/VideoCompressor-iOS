import SwiftUI

/// 压缩进度与结果总览（全屏覆盖）。
struct CompressionProgressView: View {
    @ObservedObject var session: CompressionSession
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if session.isRunning {
                    runningView
                } else {
                    resultView
                }
            }
            .padding()
            .navigationTitle(session.isRunning ? "压缩中" : "压缩完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !session.isRunning {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { onDone() }
                    }
                }
            }
        }
    }

    private var runningView: some View {
        VStack(spacing: 20) {
            Text("正在压缩 \(completedCount)/\(session.tasks.count)").font(.headline)
            ProgressBar(value: session.overallProgress)
            Text(Formatters.percent(session.overallProgress))
                .font(.largeTitle).fontWeight(.bold)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(session.tasks) { task in
                        TaskRow(task: task)
                    }
                }
            }
            Button(role: .destructive) {
                session.cancel()
            } label: {
                Label("取消", systemImage: "xmark.circle").frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
            .background(Color(.systemFill))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var completedCount: Int {
        session.tasks.filter { if case .success = $0.status { return true } else { return false } }.count
    }

    private var resultView: some View {
        Group {
            if session.cancelled {
                EmptyStateView(systemImage: "xmark.circle", title: "已取消",
                               message: "压缩任务已停止，临时文件已清理，原视频未受影响。")
            } else if session.tasks.contains(where: { if case .failure = $0.status { return true } else { return false } }) {
                failedView
            } else if session.finishedResults.count == 1, let r = session.finishedResults.first {
                ResultView(result: r, onContinue: onDone)
            } else {
                BatchResultView(results: session.finishedResults, onContinue: onDone)
            }
        }
    }

    private var failedView: some View {
        VStack(spacing: 12) {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "部分任务失败",
                           message: "请查看下方列表了解详情，可返回重新选择视频重试。")
            ForEach(session.tasks) { task in
                TaskRow(task: task)
            }
        }
    }
}

/// 单个任务进度行。
struct TaskRow: View {
    let task: CompressionTaskModel
    var body: some View {
        HStack(spacing: 12) {
            AsyncThumbnail(url: task.item.thumbnailURL)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(task.item.title).font(.subheadline).lineLimit(1)
                Text(task.status.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if task.status.isCompressing {
                ProgressBar(value: task.progressValue).frame(width: 90)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
