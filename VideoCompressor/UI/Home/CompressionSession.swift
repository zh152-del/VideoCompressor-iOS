import Foundation
import SwiftUI
import UIKit
import Combine

/// 压缩会话：唯一任务管理器（应用级持有，不随页面销毁）。
///
/// 统一状态机（避免多个 Boolean 互相矛盾）：
///   idle → preparing → running → completed
///                          ↘ cancelled（用户取消）
/// 单个任务内部阶段：pending → compressing → saving → success / noGain / failure。
///
/// 每个视频的流水线（顺序严格，绝不可颠倒）：
///   压缩 → 校验输出（存在/大小>0/小于原文件）→ 保存到照片图库
///   → 确认 PHPhotoLibrary 保存成功 → （可选）删除原视频 → 清理临时输出文件
///
/// 关键约束：
/// - 只有「保存成功」的视频才允许删除原视频。
/// - 未节省空间（noGain）：不保存、不删除原视频，历史如实记录。
/// - 保存失败：原视频保留，任务标记失败，输出临时文件清理。
/// - 任何失败都通过任务状态 / error 暴露，绝不静默吞掉。
@MainActor
final class CompressionSession: ObservableObject {

    /// 会话级统一状态。
    enum Phase: Equatable {
        case idle        // 无任务
        case preparing   // 已受理，正在准备
        case running     // 正在逐个压缩/保存
        case recording   // 正在记录压缩状态（验证成品 __VC__ 标记，真实进度）
        case completed   // 全部结束（含部分失败）
        case cancelled   // 用户取消
    }

    struct MarkProgress: Equatable { let done: Int; let total: Int }

    @Published var tasks: [CompressionTaskModel] = []
    @Published var phase: Phase = .idle
    @Published var overallProgress: Double = 0
    @Published var error: AppError?
    @Published var markProgress: MarkProgress? = nil            // 标记验证进度（x / N）
    @Published var markFailedTitles: [String] = []              // 标记验证失败的视频名
    /// 当前压缩的组号（0-based；非分组压缩为 nil）。
    @Published private(set) var currentGroupIndex: Int? = nil
    /// 待删除原视频（仅包含「压缩成功且已确认保存到 Photos」的原视频标识）。
    /// 手动模式：用户在完成页一键删除；自动模式：批次结束后统一删除。
    @Published private(set) var pendingDeleteIDs: [String] = []
    /// 已成功删除的原视频标识。
    @Published private(set) var deletedOriginalIDs: [String] = []

    /// 兼容读取：是否正在执行任务。
    var isRunning: Bool { phase == .preparing || phase == .running || phase == .recording }
    var cancelled: Bool { phase == .cancelled }

    private let service = CompressionService()
    private var runTask: Task<Void, Never>?
    private let temp = TempFileManager.shared
    private let history = HistoryStore.shared

    // MARK: - 统计（从任务状态实时推导）

    var successCount: Int { tasks.filter { if case .success = $0.status { return true } else { return false } }.count }
    var noGainCount: Int { tasks.filter { if case .noGain = $0.status { return true } else { return false } }.count }
    var failureCount: Int { tasks.filter { if case .failure = $0.status { return true } else { return false } }.count }
    var finishedCount: Int { tasks.filter { $0.status.isFinished }.count }
    var savedToPhotosCount: Int { successCount }

    var currentIndex: Int? { tasks.firstIndex { $0.status.isCompressing || $0.status.isSaving } }
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

    /// 启动批量压缩。单个与批量共用同一核心流程（items.count == 1 时 UI 展示不同而已）。
    /// 启动被拒（无视频 / 正在运行 / 源文件已失效）时通过 `onStartError` 回调报告，绝不静默。
    func run(items: [VideoItem], profile: CompressionProfile,
             settings: SettingsStore,
             groupIndex: Int? = nil, skippedCount: Int = 0,
             onStartError: ((AppError) -> Void)? = nil) {
        guard !items.isEmpty else {
            onStartError?(.unknown("尚未选择视频"))
            return
        }
        guard phase == .idle || phase == .completed || phase == .cancelled else {
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

        phase = .preparing
        overallProgress = 0
        error = nil
        pendingDeleteIDs = []
        deletedOriginalIDs = []
        markProgress = nil
        markFailedTitles = []
        currentGroupIndex = groupIndex
        tasks = items.map { CompressionTaskModel(item: $0, profile: profile) }
        service.resetCancellation()
        AppLog.compress("Run started：\(items.count) 个视频，模式：\(profile.mode.displayName)")

        // 后台任务包裹（在 MainActor 上调用 UIApplication，保证线程安全；begin/end 严格成对）
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        if UIApplication.shared.responds(to: #selector(UIApplication.beginBackgroundTask(withName:expirationHandler:))) {
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoCompression") {
                // 过期：系统要求尽快结束。停止编码并结束后台任务。
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
        }

        runTask = Task {
            self.phase = .running
            for idx in items.indices {
                if Task.isCancelled || service.isCancelledFlag { break }
                tasks[idx].status = .compressing(progress: 0)
                overallProgress = Double(idx) / Double(items.count)
                AppLog.compress("Task started [\(idx + 1)/\(items.count)]：\(items[idx].title)，原始 \(Formatters.bytes(items[idx].fileSizeBytes))")

                do {
                    let result = try await service.compress(item: items[idx], profile: profile,
                                                            preferredCodec: settings.preferredCodec) { [weak self] p in
                        Task { @MainActor in
                            guard let self, idx < self.tasks.count else { return }
                            self.tasks[idx].status = .compressing(progress: p)
                        }
                    }

                    if result.noGain {
                        AppLog.compress("No gain：\(items[idx].title)（\(Formatters.bytes(result.outputSizeBytes)) ≥ 原 \(Formatters.bytes(items[idx].fileSizeBytes))），保留原视频")
                        tasks[idx].status = .noGain(result)
                        self.writeHistory(result.historyEntry(savedID: nil, outcome: "noGain"))
                        continue
                    }

                    // ---- 保存到照片图库（成功后才允许删除原视频）----
                    guard let outputURL = result.outputURL else {
                        tasks[idx].status = .failure(.outputFileMissing)
                        self.writeHistory(Self.failedEntry(for: items[idx], profile: profile))
                        continue
                    }
                    do {
                        tasks[idx].status = .saving
                        AppLog.photo("Save started：\(items[idx].title)")
                        // 压缩成品以 __VC__ 标记文件名保存（保存时命名，零重编码）
                        let markedName = ProcessedMark.markedName(for: items[idx].title)
                        let savedID = try await PhotoLibraryService.shared.saveVideo(at: outputURL,
                                                                                     originalFilename: markedName)
                        AppLog.photo("Save succeeded：\(items[idx].title) → \(savedID)")
                        var final = result
                        final.savedPhotoLocalIdentifier = savedID
                        temp.remove(outputURL)
                        tasks[idx].status = .success(final)
                        self.writeHistory(final.historyEntry(savedID: savedID, outcome: "saved"))

                        // ---- 保存成功 → 原视频进入待删除队列（统一批量删除，绝不逐个删）----
                        if let orig = items[idx].localIdentifier, !orig.isEmpty {
                            pendingDeleteIDs.append(orig)
                        }
                    } catch {
                        AppLog.photo("Save failed（原视频保留）：\(error.localizedDescription)")
                        temp.remove(outputURL)
                        tasks[idx].status = .failure((error as? AppError) ?? .saveToPhotoFailed(error.localizedDescription))
                        self.writeHistory(Self.failedEntry(for: items[idx], profile: profile))
                    }
                } catch is CancellationError {
                    tasks[idx].status = .cancelled
                } catch let e as AppError {
                    if e.isCancellation {
                        tasks[idx].status = .cancelled
                    } else {
                        AppLog.compress("Task failed：\(e.errorDescription) - \(e.recoverySuggestion)")
                        tasks[idx].status = .failure(e)
                        self.writeHistory(Self.failedEntry(for: items[idx], profile: profile))
                    }
                } catch {
                    AppLog.compress("Task failed（未知）：\(error.localizedDescription)")
                    tasks[idx].status = .failure(.unknown(error.localizedDescription))
                    self.writeHistory(Self.failedEntry(for: items[idx], profile: profile))
                }
            }

            overallProgress = 1.0
            // 自动删除模式：批次结束后一次性批量删除（只含保存成功的原视频）
            if settings.deleteOriginalAfterSave, !pendingDeleteIDs.isEmpty {
                await deletePendingOriginals()
            }

            // ---- 记录压缩状态（__VC__ 标记验证，真实进度逐个确认）----
            // 标记本身在保存时已写入成品文件名（originalFilename），这里逐个重读验证。
            if groupIndex != nil {
                phase = .recording
                let successes = tasks.compactMap { t -> CompressionResult? in
                    if case .success(let r) = t.status { return r } else { return nil }
                }
                var done = 0
                var failedMarks: [String] = []
                markProgress = MarkProgress(done: 0, total: successes.count)
                for r in successes {
                    let ok = await Self.verifyMark(savedID: r.savedPhotoLocalIdentifier)
                    done += 1
                    if !ok { failedMarks.append(r.item.title) }
                    markProgress = MarkProgress(done: done, total: successes.count)
                }
                markFailedTitles = failedMarks
                AppLog.mark("标记验证完成：\(successes.count - failedMarks.count)/\(successes.count)")

                // 写入组记录（失败/跳过不打标已由流程保证；跳过数由调用方传入）
                let snapshots: [GroupItemSnapshot] = tasks.compactMap { t in
                    guard let pid = t.item.phAssetID ?? t.item.localIdentifier else { return nil }
                    switch t.status {
                    case .success(let r):
                        return GroupItemSnapshot(assetID: pid, filename: t.item.title,
                                                 originalBytes: t.item.fileSizeBytes,
                                                 compressedBytes: r.outputSizeBytes,
                                                 outcome: "saved", removed: false,
                                                 savedAssetID: r.savedPhotoLocalIdentifier)
                    case .failure:
                        return GroupItemSnapshot(assetID: pid, filename: t.item.title,
                                                 originalBytes: t.item.fileSizeBytes,
                                                 compressedBytes: nil,
                                                 outcome: "failed", removed: false, savedAssetID: nil)
                    default: return nil
                    }
                }
                GroupStore.shared.recordCompleted(index: groupIndex!, totalCount: items.count + skippedCount,
                                                  succeeded: successes.count, failed: failureCount,
                                                  skipped: skippedCount, markFailedCount: failedMarks.count,
                                                  items: snapshots)
            }

            phase = service.isCancelledFlag ? .cancelled : .completed
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            AppLog.compress("Run finished：成功 \(successCount) / noGain \(noGainCount) / 失败 \(failureCount)，节省 \(Formatters.bytes(savedBytesSoFar))")
        }
    }

    /// 一次性批量删除待删除原视频（只允许删除「已确认保存到 Photos」的原视频）。
    /// 删除失败的原视频保留在 pendingDeleteIDs 中，用户可再次点击重试。
    func deletePendingOriginals() async {
        guard !pendingDeleteIDs.isEmpty, !isRunning else { return }
        AppLog.delete("Delete started：批量删除 \(pendingDeleteIDs.count) 个原视频")
        let result = await PhotoLibraryService.shared.deleteOriginals(localIdentifiers: pendingDeleteIDs)
        if !result.deleted.isEmpty {
            deletedOriginalIDs.append(contentsOf: result.deleted)
            pendingDeleteIDs.removeAll { result.deleted.contains($0) }
        }
        if !result.failed.isEmpty {
            AppLog.delete("Delete failed：\(result.failed.count) 个原视频未删除（保留待重试）")
            self.error = .deleteOriginalFailed("\(result.failed.count) 个原视频删除失败，已保留，可重试")
        }
    }

    // MARK: - 私有

    /// 验证成品 __VC__ 标记：重新读取 PHAsset 的 originalFilename 确认包含标记。
    private static func verifyMark(savedID: String?) async -> Bool {
        guard let id = savedID else { return false }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return false }
        let name = PHAssetResource.assetResources(for: asset).first { $0.type == .video }?.originalFilename
            ?? (asset.value(forKey: "filename") as? String) ?? ""
        let ok = ProcessedMark.isProcessed(filename: name)
        if !ok { AppLog.mark("[ERROR] 标记验证失败：成品文件名为 \(name)") }
        return ok
    }


    /// 历史写入（统一入口，带日志，真实结果）。
    private func writeHistory(_ entry: HistoryEntry) {
        AppLog.history("Write started：\(entry.name)，outcome=\(entry.outcome)")
        history.add(entry)
        AppLog.history("Write succeeded：\(entry.name)")
    }

    /// 失败条目：未产生输出，compressedBytes 记为 originalBytes（不假装节省）。
    private static func failedEntry(for item: VideoItem, profile: CompressionProfile) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            name: item.title,
            originalBytes: item.fileSizeBytes,
            compressedBytes: item.fileSizeBytes,
            savedBytes: 0,
            date: Date(),
            mode: profile.modeDisplayName,
            sourceResolution: "\(item.width)×\(item.height)",
            outputResolution: "\(item.width)×\(item.height)",
            sourceCodec: item.codecDescription,
            outputCodec: item.codecDescription,
            durationSeconds: item.durationSeconds,
            savedAssetLocalIdentifier: nil,
            outcome: "failed",
            originalAssetIdentifier: item.localIdentifier
        )
    }

    func cancel() {
        AppLog.compress("用户取消任务")
        service.cancel()
        runTask?.cancel()
    }
}
