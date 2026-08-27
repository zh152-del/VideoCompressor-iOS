import Foundation
import SwiftUI
import Combine

/// 压缩会话：管理批量任务的运行状态、进度、取消，并在完成后暴露结果。
@MainActor
final class CompressionSession: ObservableObject {
    @Published var tasks: [CompressionTaskModel] = []
    @Published var isRunning = false
    @Published var overallProgress: Double = 0
    @Published var finishedResults: [CompressionResult] = []
    @Published var cancelled = false
    @Published var error: AppError?

    private let service = CompressionService()
    private var runTask: Task<Void, Never>?
    private let temp = TempFileManager.shared
    private let history = HistoryStore.shared

    func run(items: [VideoItem], profile: CompressionProfile) {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        cancelled = false
        overallProgress = 0
        error = nil
        finishedResults.removeAll()
        tasks = items.map { CompressionTaskModel(item: $0, profile: profile) }

        runTask = Task {
            do {
                let results = try await service.compressBatch(items: items, profile: profile,
                    perVideo: { idx, p in
                        Task { @MainActor in
                            guard idx < self.tasks.count else { return }
                            self.tasks[idx].status = .compressing(progress: p)
                        }
                    },
                    progress: { o in
                        Task { @MainActor in self.overallProgress = o }
                    })
                for (idx, r) in results.enumerated() where idx < tasks.count {
                    tasks[idx].status = .success(r)
                }
                finishedResults = results
                // 压缩完成即写入历史（与「是否保存到照片」解耦），保证每次压缩都有记录。
                // savedAssetLocalIdentifier 置 nil：历史只记录压缩结果，保存状态不在 UI 展示。
                for r in results {
                    history.add(r.historyEntry(savedID: nil))
                }
            } catch is CancellationError {
                handleAbort()
            } catch let e as AppError {
                if let idx = tasks.firstIndex(where: { $0.status.isCompressing }) {
                    tasks[idx].status = .failure(e)
                }
            } catch {
                if let idx = tasks.firstIndex(where: { $0.status.isCompressing }) {
                    tasks[idx].status = .failure(.unknown(error.localizedDescription))
                }
            }
            isRunning = false
        }
    }

    private func handleAbort() {
        cancelled = true
        for idx in tasks.indices where tasks[idx].status.isCompressing || tasks[idx].status.isPending {
            tasks[idx].status = .cancelled
        }
        temp.cleanup(finishedResults.map { $0.outputURL })
        finishedResults.removeAll()
    }

    func cancel() {
        service.cancel()
        runTask?.cancel()
    }
}
