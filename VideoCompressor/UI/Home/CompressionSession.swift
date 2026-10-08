import Foundation
import SwiftUI
import Combine

/// 压缩会话：管理批量任务的完整生命周期（应用级单例持有，不随页面销毁）。
///
/// 每个视频的流水线（顺序严格，绝不可颠倒）：
///   压缩 → 校验输出（存在/大小>0/小于原文件）→ 保存到照片图库
///   → 确认 PHPhotoLibrary 保存成功 → （可选）删除原视频 → 清理临时输出文件
///
/// 关键约束：
/// - 只有「保存成功」的视频才允许删除原视频。
/// - 未节省空间（noGain）的视频：不保存、不删除原视频，历史如实记录。
/// - 保存失败：原视频保留，任务标记失败，输出临时文件清理。
/// - 任何失败都通过任务状态 / error 暴露，绝不静默吞掉。
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

    var currentIndex: Int? { tasks.firstIndex { $0.status.isCompressing } }
    var currentTask: CompressionTaskModel? { currentIndex.map { tasks[$0] } }

    var savedBytesSoFar: Int64 {
        tasks.reduce(Int64(0)) { sum, t in
            if case .success(let r) = t.status { return sum + r.savedBytes }
            return sum
        }
    }

    var totalOriginalBytes: Int64 { tasks.reduce(0) { $0 + $1.item.fileSizeBytes } }

    var totalCompressedBytes: Int64 {
        tasks.reduce(Int64(0)) { sum, t in
            if case .success(let r) = t.status { return sum + r.outputSizeBytes }
            return sum
        }
    }

    // MARK: - 启动

    /// 启动批量压缩。启动被拒（无视频 / 正在运行 / 源文件已失效）时通过 `onStartError`
    /// 回调向 UI 报告，绝不静默返回。
    func run(items: [VideoItem], profile: CompressionProfile,
             settings: SettingsStore,
             onStartError: ((AppError) -> Void)? = nil) {
        guard !items.isEmpty else {
            onStartError?(.unknown("尚未选择视频"))
            return
        }
        guard !isRunning else {
            onStartError?(.unknown("已有压缩任务在进行中"))
            return
        }
        // 源文件预检：已被系统清理的临时视频直接报错，不进入任务队列
        let missing = items.filter { !FileManager.default.fileExists(atPath: $0.sourceURL.path) }
        if !missing.isEmpty {
            AppLog.compress("启动拒绝：\(missing.count) 个源文件不存在")
            onStartError?(.videoReadFailed)
            return
        }

        isRunning = true
        cancelled = false
        overallProgress = 0
        error = nil
        tasks = items.map { CompressionTaskModel(item: $0, profile: profile) }
        AppLog.compress("开始任务：\(items.count) 个视频，模式：\(profile.mode.displayName)")

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
                        AppLog.compress("[\(items[idx].title)] 未节省空间（\(Formatters.bytes(result.outputSizeBytes)) ≥ 原 \(Formatters.bytes(items[idx].fileSizeBytes))），保留原视频")
                        tasks[idx].status = .noGain(result)
                        history.add(result.historyEntry(savedID: nil))
                        AppLog.history("写入历史（noGain）：\(items[idx].title)")
                        continue
                    }

                    // ---- 保存到照片图库（成功后才允许删除原视频）----
                    guard let outputURL = result.outputURL else {
                        tasks[idx].status = .failure(.outputFileMissing)
                        continue
                    }
                    do {
                        AppLog.photo("开始保存：\(items[idx].title)")
                        let savedID = try await PhotoLibraryService.shared.saveVideo(at: outputURL)
                        AppLog.photo("保存成功：\(items[idx].title) → \(savedID)")
                        var final = result
                        final.savedPhotoLocalIdentifier = savedID
                        temp.remove(outputURL)
                        tasks[idx].status = .success(final)
                        history.add(final.historyEntry(savedID: savedID))
                        AppLog.history("写入历史：\(items[idx].title)，节省 \(Formatters.bytes(final.savedBytes))")

                        // ---- 保存成功后才删除原视频 ----
                        if settings.deleteOriginalAfterSave, let orig = items[idx].localIdentifier {
                            do {
                                try await PhotoLibraryService.shared.deleteOriginal(localIdentifier: orig)
                                AppLog.delete("原视频已删除：\(items[idx].title)")
                            } catch {
                                // 删除失败不回滚保存状态：原视频仍在图库，用户可手动删
                                AppLog.delete("删除失败（原视频保留）：\(error.localizedDescription)")
                                self.error = (error as? AppError) ?? .deleteOriginalFailed(error.localizedDescription)
                            }
                        }
                    } catch {
                        AppLog.photo("保存失败（原视频保留）：\(error.localizedDescription)")
                        temp.remove(outputURL)
                        tasks[idx].status = .failure((error as? AppError) ?? .saveToPhotoFailed(error.localizedDescription))
                    }
                } catch is CancellationError {
                    tasks[idx].status = .cancelled
                } catch let e as AppError {
                    if e.isCancellation {
                        tasks[idx].status = .cancelled
                    } else {
                        AppLog.compress("任务失败：\(e.errorDescription) - \(e.recoverySuggestion)")
                        tasks[idx].status = .failure(e)
                    }
                } catch {
                    AppLog.compress("任务失败（未知）：\(error.localizedDescription)")
                    tasks[idx].status = .failure(.unknown(error.localizedDescription))
                }
            }

            overallProgress = 1.0
            isRunning = false
            AppLog.compress("任务结束：成功 \(successCount) / noGain \(noGainCount) / 失败 \(failureCount)")
        }
    }

    func cancel() {
        AppLog.compress("用户取消任务")
        service.cancel()
        runTask?.cancel()
    }
}
