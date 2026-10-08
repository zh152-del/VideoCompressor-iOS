import Foundation
import SwiftUI
import UIKit
import Photos
import Combine

/// 压缩会话：唯一任务管理器（应用级持有，不随页面销毁）。
///
/// 统一状态机：idle → preparing → running → completed / cancelled
/// 单个任务阶段：pending → compressing → saving → success / noGain / skipped / failure。
///
/// 每个视频流水线（顺序严格，不可颠倒）：
///   懒导出(PHAsset来源) → 指纹识别(已压缩判定) → 压缩 → 校验输出 → 保存 Photos
///   → 确认保存成功 → 记录指纹 → （可选）原视频进入待删除队列 → 清理临时文件
@MainActor
final class CompressionSession: ObservableObject {

    /// 会话级统一状态。
    enum Phase: Equatable {
        case idle, preparing, running, completed, cancelled
    }

    @Published var tasks: [CompressionTaskModel] = []
    @Published var phase: Phase = .idle
    @Published var overallProgress: Double = 0
    @Published var error: AppError?
    /// 当前压缩的组号（0-based；非分组压缩为 nil）。
    @Published private(set) var currentGroupIndex: Int? = nil
    /// 待删除原视频（仅含「压缩成功且已确认保存到 Photos」的原视频标识）。
    @Published private(set) var pendingDeleteIDs: [String] = []
    /// 已成功删除的原视频标识。
    @Published private(set) var deletedOriginalIDs: [String] = []

    var isRunning: Bool { phase == .preparing || phase == .running }
    var cancelled: Bool { phase == .cancelled }

    private let service = CompressionService()
    private var runTask: Task<Void, Never>?
    private let temp = TempFileManager.shared
    private let history = HistoryStore.shared
    private let fingerprintStore = FingerprintStore.shared

    // MARK: - 统计

    var successCount: Int { tasks.filter { if case .success = $0.status { return true } else { return false } }.count }
    var noGainCount: Int { tasks.filter { if case .noGain = $0.status { return true } else { return false } }.count }
    var failureCount: Int { tasks.filter { if case .failure = $0.status { return true } else { return false } }.count }
    var skippedCount: Int { tasks.filter { if case .skipped = $0.status { return true } else { return false } }.count }
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

    func run(items: [VideoItem], profile: CompressionProfile,
             settings: SettingsStore,
             groupIndex: Int? = nil, priorSkippedCount: Int = 0,
             onStartError: ((AppError) -> Void)? = nil) {
        guard !items.isEmpty else {
            onStartError?(.unknown("尚未选择视频"))
            return
        }
        guard phase == .idle || phase == .completed || phase == .cancelled else {
            onStartError?(.unknown("已有压缩任务在进行中"))
            return
        }
        // 源文件预检：本地文件来源必须存在（PHAsset 来源在压缩前懒导出）
        for item in items where item.phAssetID == nil {
            guard FileManager.default.fileExists(atPath: item.sourceURL.path) else {
                AppLog.compress("启动拒绝：源文件不存在 \(item.title)")
                onStartError?(.videoReadFailed)
                return
            }
        }

        phase = .preparing
        overallProgress = 0
        error = nil
        pendingDeleteIDs = []
        deletedOriginalIDs = []
        currentGroupIndex = groupIndex
        tasks = items.map { CompressionTaskModel(item: $0, profile: profile) }
        service.resetCancellation()
        AppLog.compress("Run started：\(items.count) 个视频，模式：\(profile.mode.displayName)，组：\(groupIndex.map { "第\($0 + 1)组" } ?? "无")")

        // 后台任务包裹（MainActor 上调用 UIApplication；begin/end 严格成对）
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoCompression") {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }

        runTask = Task {
            self.phase = .running
            for idx in items.indices {
                if Task.isCancelled || service.isCancelledFlag { break }
                tasks[idx].status = .compressing(progress: 0)
                overallProgress = Double(idx) / Double(items.count)
                AppLog.compress("Task started [\(idx + 1)/\(items.count)]：\(items[idx].title)")

                do {
                    // ---- 懒导出 + 指纹识别（仅相册来源视频）----
                    var runItem = items[idx]
                    var originalFP: VideoFingerprint? = nil
                    if runItem.needsLibraryExport, let pid = runItem.phAssetID {
                        guard let libAsset = PHAsset.fetchAssets(withLocalIdentifiers: [pid], options: nil).firstObject else {
                            throw AppError.videoReadFailed
                        }
                        let url = try await PhotoLibraryService.shared.exportVideo(from: libAsset)
                        originalFP = try? await FingerprintEngine.fingerprint(url: url)

                        // 已压缩识别：localIdentifier 快速命中 或 指纹命中 → 按策略处理
                        let known = fingerprintStore.knownByID(pid)
                        let fpHit = originalFP.flatMap { fingerprintStore.matchByFingerprint($0) } != nil
                        if known || fpHit {
                            switch settings.processedPolicy {
                            case .recompress:
                                AppLog.compress("识别为已压缩（策略=重新压缩），继续压缩：\(runItem.title)")
                            default:
                                // skip / ask（ask 无法中途交互，导入时按跳过并如实记录）
                                AppLog.compress("识别为已压缩（策略=\(settings.processedPolicy.displayName)），跳过：\(runItem.title)")
                                tasks[idx].status = .skipped
                                continue
                            }
                        }
                        // 用导出文件的真实大小替换（扫描阶段可能拿不到）
                        let realSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? runItem.fileSizeBytes
                        runItem = VideoItem(
                            localIdentifier: pid, sourceURL: url, title: runItem.title,
                            durationSeconds: runItem.durationSeconds, fileSizeBytes: realSize,
                            width: runItem.width, height: runItem.height, fps: runItem.fps,
                            codecDescription: runItem.codecDescription, thumbnailURL: nil,
                            creationDate: nil, phAssetID: pid
                        )
                    }

                    let result = try await service.compress(item: runItem, profile: profile,
                                                            preferredCodec: settings.preferredCodec) { [weak self] p in
                        Task { @MainActor in
                            guard let self, idx < self.tasks.count else { return }
                            self.tasks[idx].status = .compressing(progress: p)
                        }
                    }

                    if result.noGain {
                        AppLog.compress("No gain：\(runItem.title)（\(Formatters.bytes(result.outputSizeBytes)) ≥ 原 \(Formatters.bytes(result.effectiveOriginalBytes))），保留原视频")
                        tasks[idx].status = .noGain(result)
                        history.add(result.historyEntry(savedID: nil, outcome: "noGain"))
                        continue
                    }

                    // ---- 保存到照片图库（成功后才允许删除原视频）----
                    guard let outputURL = result.outputURL else {
                        tasks[idx].status = .failure(.outputFileMissing)
                        history.add(Self.failedEntry(for: runItem, profile: profile))
                        continue
                    }
                    do {
                        tasks[idx].status = .saving
                        AppLog.photo("Save started：\(runItem.title)")
                        let savedID = try await PhotoLibraryService.shared.saveVideo(at: outputURL)
                        AppLog.photo("Save succeeded：\(runItem.title) → \(savedID)")

                        // ---- 指纹记录（压缩前后各一份，写入沙盒库 + 用户文件夹日志）----
                        var compressedFP: VideoFingerprint? = nil
                        if let fp = try? await FingerprintEngine.fingerprint(url: outputURL) {
                            compressedFP = fp
                        }
                        if originalFP == nil {
                            originalFP = try? await FingerprintEngine.fingerprint(url: runItem.sourceURL)
                        }
                        if let ofp = originalFP {
                            fingerprintStore.add(record: CompressionRecord(
                                originalAssetID: runItem.phAssetID ?? runItem.localIdentifier,
                                originalFingerprint: ofp,
                                compressedAssetID: savedID,
                                compressedFingerprint: compressedFP,
                                originalSizeBytes: result.effectiveOriginalBytes,
                                compressedSizeBytes: result.outputSizeBytes,
                                date: Date(), status: "completed",
                                originalFileName: runItem.title))
                        }

                        var final = result
                        final.savedPhotoLocalIdentifier = savedID
                        temp.remove(outputURL)
                        tasks[idx].status = .success(final)
                        history.add(final.historyEntry(savedID: savedID, outcome: "saved"))
                        AppLog.history("写入历史：\(runItem.title)，节省 \(Formatters.bytes(final.savedBytes))")

                        // ---- 保存成功后原视频进入待删除队列（统一批量删除）----
                        if let orig = runItem.localIdentifier, !orig.isEmpty {
                            pendingDeleteIDs.append(orig)
                        }
                    } catch {
                        AppLog.photo("Save failed（原视频保留）：\(error.localizedDescription)")
                        temp.remove(outputURL)
                        tasks[idx].status = .failure((error as? AppError) ?? .saveToPhotoFailed(error.localizedDescription))
                        history.add(Self.failedEntry(for: runItem, profile: profile))
                    }
                } catch is CancellationError {
                    tasks[idx].status = .cancelled
                } catch let e as AppError {
                    if e.isCancellation {
                        tasks[idx].status = .cancelled
                    } else {
                        AppLog.compress("Task failed：\(e.errorDescription) - \(e.recoverySuggestion)")
                        tasks[idx].status = .failure(e)
                        history.add(Self.failedEntry(for: items[idx], profile: profile))
                    }
                } catch {
                    AppLog.compress("Task failed（未知）：\(error.localizedDescription)")
                    tasks[idx].status = .failure(.unknown(error.localizedDescription))
                    history.add(Self.failedEntry(for: items[idx], profile: profile))
                }
            }

            overallProgress = 1.0
            // 自动删除模式：批次结束后一次性批量删除（只含保存成功的原视频）
            if settings.deleteOriginalAfterSave, !pendingDeleteIDs.isEmpty {
                await deletePendingOriginals()
            }

            // ---- 组记录快照（成功/失败/跳过逐个记录，供"已完成组"页面）----
            if let gi = currentGroupIndex {
                let snaps: [GroupItemSnapshot] = tasks.compactMap { t -> GroupItemSnapshot? in
                    guard let pid = t.item.phAssetID ?? t.item.localIdentifier else { return nil }
                    switch t.status {
                    case .success(let r):
                        return GroupItemSnapshot(assetID: pid, filename: t.item.title,
                                                 originalBytes: r.effectiveOriginalBytes,
                                                 compressedBytes: r.outputSizeBytes,
                                                 outcome: "saved", removed: false,
                                                 savedAssetID: r.savedPhotoLocalIdentifier)
                    case .failure:
                        return GroupItemSnapshot(assetID: pid, filename: t.item.title,
                                                 originalBytes: t.item.fileSizeBytes,
                                                 compressedBytes: nil, outcome: "failed", removed: false,
                                                 savedAssetID: nil)
                    case .skipped:
                        return GroupItemSnapshot(assetID: pid, filename: t.item.title,
                                                 originalBytes: t.item.fileSizeBytes,
                                                 compressedBytes: nil, outcome: "skipped", removed: false,
                                                 savedAssetID: nil, fingerprintHex: nil)
                    default: return nil
                    }
                }
                GroupStore.shared.recordCompleted(index: gi, totalCount: items.count + priorSkippedCount,
                                                  succeeded: successCount, failed: failureCount,
                                                  skipped: skippedCount, markFailedCount: 0,
                                                  items: snaps)
            }

            phase = service.isCancelledFlag ? .cancelled : .completed
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            AppLog.compress("Run finished：成功 \(successCount) / noGain \(noGainCount) / 跳过 \(skippedCount) / 失败 \(failureCount)，节省 \(Formatters.bytes(savedBytesSoFar))")
        }
    }

    /// 一次性批量删除待删除原视频（只允许删除「已确认保存到 Photos」的原视频）。
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

    /// 失败条目：未产生输出，compressedBytes 记为 originalBytes（不假装节省）。
    private static func failedEntry(for item: VideoItem, profile: CompressionProfile) -> HistoryEntry {
        HistoryEntry(
            id: UUID(), name: item.title,
            originalBytes: item.fileSizeBytes, compressedBytes: item.fileSizeBytes, savedBytes: 0,
            date: Date(), mode: profile.modeDisplayName,
            sourceResolution: "\(item.width)×\(item.height)",
            outputResolution: "\(item.width)×\(item.height)",
            sourceCodec: item.codecDescription, outputCodec: item.codecDescription,
            durationSeconds: item.durationSeconds,
            savedAssetLocalIdentifier: nil, outcome: "failed",
            originalAssetIdentifier: item.phAssetID ?? item.localIdentifier
        )
    }

    func cancel() {
        AppLog.compress("用户取消任务")
        service.cancel()
        runTask?.cancel()
    }
}
