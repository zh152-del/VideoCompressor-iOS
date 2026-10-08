import Foundation
import SwiftUI
import Combine

/// 压缩会话：管理批量任务的完整生命周期。
///
/// 每个视频的流水线（顺序严格，绝不可颠倒）：
///   压缩 → 校验输出（存在/大小>0/小于原文件）→ 保存到照片图库
///   → 确认 PHPhotoLibrary 保存成功 → （可选）删除原视频 → 清理临时输出文件
///
/// 关键约束：
/// - 只有「保存成功」的视频才允许删除原视频。
/// - 未节省空间（noGain）的视频：不保存、不删除原视频，历史如实记录。
/// - 保存失败：原视频保留，任务标记失败，输出临时文件清理。
@MainActor
final class CompressionSession: ObservableObject {
    @Published var tasks: [CompressionTaskModel] = []
    @Published var isRunning = false
    @Published var overallProgress: Double = 0
    @Published var cancelled = false
    @Published var error: AppError?

    private let service = CompressionService()
    private var runTask: Task<Void, Never>?
    private let temp = TempFileManager.shared
    private let history = HistoryStore.shared

    // MARK: - 统计（从任务状态实时推导）

    var successCount: Int { tasks.filter { if case .success = $0.status { return true } else { return false } }.count }
    var noGainCount: Int { tasks.filter { if case .noGain = $0.status { return true } else { return false } }.count }
    var failureCount: Int { tasks.filter { if case .failure = $0.status { return true } else { return false } }.count }
    var finishedCount: Int { tasks.filter { $0.status.isFinished }.count }

    /// 当前正在压缩的下标（无则 nil）。
    var currentIndex: Int? { tasks.firstIndex { $0.status.isCompressing } }

    /// 当前正在压缩的任务。
    var currentTask: CompressionTaskModel? { currentIndex.map { tasks[$0] } }

    /// 已成功保存的视频累计节省字节。
    var savedBytesSoFar: Int64 {
        tasks.reduce(Int64(0)) { sum, t in
            if case .success(let r) = t.status { return sum + r.savedBytes }
            return sum
        }
    }

    /// 全部任务原始总大小。
    var totalOriginalBytes: Int64 { tasks.reduce(0) { $0 + $1.item.fileSizeBytes } }

    /// 已成功任务的压缩后总大小。
    var totalCompressedBytes: Int64 {
        tasks.reduce(Int64(0)) { sum, t in
            if case .success(let r) = t.status { return sum + r.outputSizeBytes }
            return sum
        }
    }

    // MARK: - 启动

    func run(items: [VideoItem], profile: CompressionProfile, settings: SettingsStore) {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        cancelled = false
        overallProgress = 0
        error = nil
        tasks = items.map { CompressionTaskModel(item: $0, profile: profile) }

        runTask = Task {
            for idx in items.indices {
                if Task.isCancelled || service.isCancelledFlag { break }
                tasks[idx].status = .compressing(progress: 0)
                overallProgress = Double(idx) / Double(items.count)

                do {
                    let result = try await service.compress(item: items[idx], profile: profile,
                                                            preferredCodec: settings.preferredCodec) { [weak self] p in
                        Task { @MainActor in
                            guard let self, idx < self.tasks.count else { return }
                            self.tasks[idx].status = .compressing(progress: p)
                        }
                    }

                    if result.noGain {
                        // 未节省空间：不保存、不删原视频、历史如实记录（体积对比仍写入）
                        tasks[idx].status = .noGain(result)
                        history.add(result.historyEntry(savedID: nil))
                        continue
                    }

                    // ---- 保存到照片图库（成功后才允许删除原视频）----
                    guard let outputURL = result.outputURL else {
                        tasks[idx].status = .failure(.outputFileMissing)
                        continue
                    }
                    do {
                        let savedID = try await PhotoLibraryService.shared.saveVideo(at: outputURL)
                        // 保存成功 → 记录标识 → 清理临时输出
                        var final = result
                        final.savedPhotoLocalIdentifier = savedID
                        temp.remove(outputURL)
                        tasks[idx].status = .success(final)
                        history.add(final.historyEntry(savedID: savedID))

                        // ---- 保存成功后才删除原视频 ----
                        if settings.deleteOriginalAfterSave, let orig = items[idx].localIdentifier {
                            do {
                                try await PhotoLibraryService.shared.deleteOriginal(localIdentifier: orig)
                            } catch {
                                // 删除失败不回滚保存状态：原视频仍在图库，用户可手动删
                                self.error = (error as? AppError) ?? .deleteOriginalFailed(error.localizedDescription)
                            }
                        }
                    } catch {
                        // 保存失败：原视频保留、输出清理、任务标记失败
                        temp.remove(outputURL)
                        tasks[idx].status = .failure((error as? AppError) ?? .saveToPhotoFailed(error.localizedDescription))
                    }
                } catch is CancellationError {
                    tasks[idx].status = .cancelled
                } catch let e as AppError {
                    if e.isCancellation {
                        tasks[idx].status = .cancelled
                    } else {
                        tasks[idx].status = .failure(e)
                    }
                } catch {
                    tasks[idx].status = .failure(.unknown(error.localizedDescription))
                }
            }

            overallProgress = 1.0
            isRunning = false
        }
    }

    private func handleAbort() {
        cancelled = true
        for idx in tasks.indices where tasks[idx].status.isCompressing || tasks[idx].status.isPending {
            tasks[idx].status = .cancelled
        }
    }

    func cancel() {
        service.cancel()
        runTask?.cancel()
    }
}
