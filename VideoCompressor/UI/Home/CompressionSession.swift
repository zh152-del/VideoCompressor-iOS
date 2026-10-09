import Foundation
import SwiftUI
import UIKit
import Combine

/// 被判定"无法压缩"而自动跳过的视频（不再出现在首页，只在设置页可查、可清空）。
struct SkippedVideo: Codable, Identifiable, Equatable {
    var id: String { assetID }
    let assetID: String
    let name: String
    let date: Date
    let sizeBytes: Int64
}

/// 压缩过程实时日志条目（等宽字体展示；只保留最近 300 条）。
struct LiveLogEntry: Identifiable {
    let id = UUID()
    let time: String
    let taskIndex: Int      // 1-based；0 表示批次级事件
    let taskTotal: Int
    let stage: String
    let text: String
}

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
        case completed   // 全部结束（含部分失败）
        case cancelled   // 用户取消
    }

    @Published var tasks: [CompressionTaskModel] = []
    @Published var phase: Phase = .idle
    @Published var overallProgress: Double = 0
    @Published var error: AppError?
    /// 正在取消（UI 立即禁用取消按钮，防重复点击与重复清理）
    @Published private(set) var isCancelling = false
    /// 当前任务 ID：隔离"取消后旧任务回调污染新任务"的竞态
    private(set) var currentRunID = UUID()
    /// 压缩过程实时日志（真实事件驱动，最多 300 条）
    @Published private(set) var liveLog: [LiveLogEntry] = []
    /// 当前任务的输出文件大小（实际可获取时）
    @Published private(set) var currentOutputSize: Int64? = nil
    /// 无法压缩而自动跳过的视频（首页不再显示；设置页可查看与清空）
    @Published private(set) var timedOutSkips: [SkippedVideo] = []
    /// 批次开始时间 / 每任务开始时间（用于耗时展示）
    @Published private(set) var batchStartedAt: Date? = nil
    @Published private(set) var taskStartedAt: [Int: Date] = [:]

    private static let skipsKey = "vc_timed_out_skips"

    /// 跳过视频 ID 集合（扫描时过滤）
    var timedOutSkipIDs: Set<String> { Set(timedOutSkips.map(\.assetID)) }

    /// 记录一次"无法压缩自动跳过"（持久化，重启后仍然从首页排除）。
    func markUncompressibleSkip(assetID: String, name: String, sizeBytes: Int64) {
        guard !assetID.isEmpty else { return }
        if !timedOutSkips.contains(where: { $0.assetID == assetID }) {
            timedOutSkips.insert(SkippedVideo(assetID: assetID, name: name, date: Date(), sizeBytes: sizeBytes),
                                 at: 0)
            if timedOutSkips.count > 500 { timedOutSkips.removeLast(timedOutSkips.count - 500) }
            saveTimedOutSkips()
        }
        log("跳过", "该视频可能无法压缩，已自动跳过，首页不再显示（可在设置页查看）", taskIndex: nil)
    }

    /// 清空跳过记录（这些视频会重新出现在首页）。
    func clearTimedOutSkips() {
        timedOutSkips = []
        saveTimedOutSkips()
        AppLog.compress("已清空超时跳过记录，视频重新参与扫描")
    }

    private func saveTimedOutSkips() {
        if let data = try? JSONEncoder().encode(timedOutSkips) {
            UserDefaults.standard.set(data, forKey: Self.skipsKey)
        }
    }
    private func loadTimedOutSkips() {
        if let data = UserDefaults.standard.data(forKey: Self.skipsKey),
           let arr = try? JSONDecoder().decode([SkippedVideo].self, from: data) {
            timedOutSkips = arr
        }
    }


    // MARK: - 耗时（UI 只读）

    var batchElapsed: TimeInterval {
        guard let batchStartedAt else { return 0 }
        return Date().timeIntervalSince(batchStartedAt)
    }
    var currentTaskElapsed: TimeInterval {
        guard let t = session_currentTaskIndex(), let s = taskStartedAt[t] else { return 0 }
        return Date().timeIntervalSince(s)
    }
    private func session_currentTaskIndex() -> Int? {
        guard let idx = currentIndex else { return nil }
        return tasks.isEmpty ? nil : idx + 1
    }

    /// 追加一条真实事件日志（超过上限丢弃最旧）。
    func log(_ stage: String, _ text: String, taskIndex: Int? = nil) {
        let idx = taskIndex ?? session_currentTaskIndex() ?? 0
        let entry = LiveLogEntry(time: Self.timeString(Date()),
                                taskIndex: idx, taskTotal: tasks.count,
                                stage: stage, text: text)
        liveLog.append(entry)
        if liveLog.count > 300 { liveLog.removeFirst(liveLog.count - 300) }
        AppLog.compress("[Task \(currentRunID.uuidString.prefix(8))] [\(stage)] \(text)")
    }
    private static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
    /// 待删除原视频（仅包含「压缩成功且已确认保存到 Photos」的原视频标识）。
    /// 手动模式：用户在完成页一键删除；自动模式：批次结束后统一删除。
    @Published private(set) var pendingDeleteIDs: [String] = []
    /// 已成功删除的原视频标识。
    @Published private(set) var deletedOriginalIDs: [String] = []

    /// 兼容读取：是否正在执行任务。
    var isRunning: Bool { phase == .preparing || phase == .running }
    var cancelled: Bool { phase == .cancelled }

    private let service = CompressionService()
    private var runTask: Task<Void, Never>?
    private let temp = TempFileManager.shared
    private let history = HistoryStore.shared

    // MARK: - 统计（从任务状态实时推导）

    var successCount: Int { tasks.filter { if case .success = $0.status { return true } else { return false } }.count }
    var noGainCount: Int { tasks.filter { if case .noGain = $0.status { return true } else { return false } }.count }
    var failureCount: Int { tasks.filter { if case .failure = $0.status { return true } else { return false } }.count }
    /// 规则跳过数量（不启动编码器）。
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

    /// 启动批量压缩。单个与批量共用同一核心流程（items.count == 1 时 UI 展示不同而已）。
    /// 启动被拒（无视频 / 正在运行 / 源文件已失效）时通过 `onStartError` 回调报告，绝不静默。
    /// - Parameter ruleSkipped: 因规则（如小于阈值）跳过的视频：不启动编码器、不产出、不删原视频。
    func run(items: [VideoItem], profile: CompressionProfile,
             settings: SettingsStore,
             ruleSkipped: [VideoItem] = [],
             onStartError: ((AppError) -> Void)? = nil) {
        // 注意：items 为空但存在规则跳过项时仍需启动（否则进度页会停在空汇总，看起来"卡死"）
        guard !items.isEmpty || !ruleSkipped.isEmpty else {
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
        isCancelling = false
        let runID = UUID()
        currentRunID = runID
        liveLog = []
        currentOutputSize = nil
        taskStartedAt = [:]
        batchStartedAt = Date()
        log("准备", "开始本批任务：压缩 \(items.count) 个，规则跳过 \(ruleSkipped.count) 个", taskIndex: 0)
        pendingDeleteIDs = []
        deletedOriginalIDs = []
        // 规则跳过项排在前面并直接置为 .skipped（不进入编码循环）
        let skippedModels: [CompressionTaskModel] = ruleSkipped.map { item in
            var m = CompressionTaskModel(item: item, profile: profile)
            m.status = .skipped
            return m
        }
        tasks = skippedModels + items.map { CompressionTaskModel(item: $0, profile: profile) }
        for m in skippedModels {
            AppLog.compress("规则跳过（不编码、不删原视频）：\(m.item.title)")
        }
        service.resetCancellation()
        let runStart = DispatchTime.now()
        AppLog.compress("[Task \(runID.uuidString.prefix(8))] 开始：压缩\(items.count) 个，规则跳过\(ruleSkipped.count) 个")
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
            let offset = ruleSkipped.count   // 前 offset 个任务是规则跳过项
            for rawIdx in items.indices {
                let idx = rawIdx + offset
                if service.isCancelledFlag { break }   // 协作式取消（不再强制取消 Task）
                // 旧任务（超时被跳过 / 已被新任务取代）立即停止后续副作用
                if currentRunID != runID { break }
                tasks[idx].status = .compressing(progress: 0)
                overallProgress = Double(rawIdx) / Double(items.count)   // 起点：已完成任务占比
                let taskNo = idx + 1
                taskStartedAt[taskNo] = Date()
                currentOutputSize = nil
                log("准备", "任务 \(taskNo)/\(tasks.count) 开始：\(Formatters.bytes(items[rawIdx].fileSizeBytes))", taskIndex: taskNo)
                let itemStart = DispatchTime.now()
                AppLog.compress("[Task \(runID.uuidString.prefix(8))] 任务\(idx + 1)/\(tasks.count) 开始：\(items[rawIdx].title)，\(Formatters.bytes(items[rawIdx].fileSizeBytes))")

                do {
                    let result = try await service.compress(item: items[rawIdx], profile: profile,
                                                            preferredCodec: settings.preferredCodec,
                                                            progress: { [weak self] p in
                        Task { @MainActor in
                            guard let self, idx < self.tasks.count, self.currentRunID == runID else { return }
                            if self.isCancelling { return }
                            if p < 0 {
                                self.tasks[idx].status = .finalizing
                                self.log("结束编码", "任务\(taskNo) 样本写完，等待写入器完成", taskIndex: taskNo)
                            } else {
                                self.tasks[idx].status = .compressing(progress: p)
                                let total = max(self.tasks.count, 1)
                                self.overallProgress = min(1.0, (Double(idx) + p) / Double(total))
                            }
                        }
                    },
                                                            signal: nil)

                    if result.noGain {
                        AppLog.compress("No gain：\(items[rawIdx].title)（\(Formatters.bytes(result.outputSizeBytes)) ≥ 原 \(Formatters.bytes(items[rawIdx].fileSizeBytes))），保留原视频")
                        tasks[idx].status = .noGain(result)
                        log("跳过", "任务\(taskNo) 未节省空间（原视频保留）", taskIndex: taskNo)
                        self.writeHistory(result.historyEntry(savedID: nil, outcome: "noGain"))
                        continue
                    }

                    // ---- 保存到照片图库（成功后才允许删除原视频）----
                    guard let outputURL = result.outputURL else {
                        tasks[idx].status = .failure(.outputFileMissing)
                        self.writeHistory(Self.failedEntry(for: items[rawIdx], profile: profile))
                        continue
                    }
                    do {
                        AppLog.compress("[Task \(runID.uuidString.prefix(8))] 编码结束→写入完成，开始验证输出（\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - itemStart.uptimeNanoseconds) / 1e9))s）")
                        tasks[idx].status = .validating
                        log("验证", "任务\(taskNo) 正在检查输出文件", taskIndex: taskNo)
                        try? await Task.sleep(nanoseconds: 1)   // 让 UI 观察到验证阶段
                        guard !service.isCancelledFlag else {
                            tasks[idx].status = .cancelled
                            temp.remove(outputURL)
                            continue
                        }
                        tasks[idx].status = .saving
                        currentOutputSize = result.outputSizeBytes
                        log("保存", "任务\(taskNo) 输出 \(Formatters.bytes(result.outputSizeBytes))，开始保存到照片", taskIndex: taskNo)
                        AppLog.compress("[Task \(runID.uuidString.prefix(8))] 验证通过，开始保存 Photos")
                        AppLog.photo("Save started：\(items[rawIdx].title)")
                        let savedID = try await PhotoLibraryService.shared.saveVideo(at: outputURL)
                        AppLog.photo("Save succeeded：\(items[rawIdx].title) → \(savedID)")
                        var final = result
                        final.savedPhotoLocalIdentifier = savedID
                        temp.remove(outputURL)
                        tasks[idx].status = .success(final)
                        self.writeHistory(final.historyEntry(savedID: savedID, outcome: "saved"))
                        self.log("完成", "任务\(taskNo) 已保存到照片图库", taskIndex: taskNo)

                        // ---- 保存成功 → 原视频进入待删除队列（统一批量删除，绝不逐个删）----
                        if let orig = items[rawIdx].localIdentifier, !orig.isEmpty {
                            pendingDeleteIDs.append(orig)
                        }
                    } catch {
                        AppLog.photo("Save failed（原视频保留）：\(error.localizedDescription)")
                        temp.remove(outputURL)
                        tasks[idx].status = .failure((error as? AppError) ?? .saveToPhotoFailed(error.localizedDescription))
                        self.writeHistory(Self.failedEntry(for: items[rawIdx], profile: profile))
                    }
                } catch is CancellationError {
                    tasks[idx].status = .cancelled
                } catch let e as AppError {
                    if e.isCancellation {
                        tasks[idx].status = .cancelled
                    } else {
                        AppLog.compress("Task failed：\(e.errorDescription) - \(e.recoverySuggestion)")
                        tasks[idx].status = .failure(e)
                        self.writeHistory(Self.failedEntry(for: items[rawIdx], profile: profile))
                    }
                } catch {
                    AppLog.compress("Task failed（未知）：\(error.localizedDescription)")
                    tasks[idx].status = .failure(.unknown(error.localizedDescription))
                    self.writeHistory(Self.failedEntry(for: items[rawIdx], profile: profile))
                }
            }

            log("批次", "全部任务结束：成功\(successCount) 跳过\(skippedCount) 失败\(failureCount)", taskIndex: 0)
            overallProgress = 1.0
            AppLog.compress("[Task \(runID.uuidString.prefix(8))] 全部结束：成功\(successCount) 跳过\(skippedCount) 失败\(failureCount)，总耗时\(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - runStart.uptimeNanoseconds) / 1e9))s")
            // 自动删除模式：批次结束后一次性批量删除（只含保存成功的原视频）
            if settings.deleteOriginalAfterSave, !pendingDeleteIDs.isEmpty {
                await deletePendingOriginals()
            }
            phase = service.isCancelledFlag ? .cancelled : .completed
            isCancelling = false   // 终态后复位，避免 UI 永久显示"正在取消"
            if service.isCancelledFlag {
                AppLog.compress("[Task \(runID.uuidString.prefix(8))] 取消已生效：临时输出已清理，原视频未触碰")
            }
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
            AppLog.compress("Run finished：成功 \(successCount) / noGain \(noGainCount) / 跳过 \(skippedCount) / 失败 \(failureCount)，节省 \(Formatters.bytes(savedBytesSoFar))")
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


    /// 取消任务。【稳定性】幂等 + 协作式取消：
    /// - 只置取消标志，由编码泵自然退出后走统一收尾（删除本次临时输出）。
    /// - 不使用 runTask?.cancel()：那会强制中断 Task，与"泵内仍在写文件"并发，
    ///   导致取消后访问已释放对象 / 删错文件（历史闪退根因）。
    /// - 已处于终态或正在取消时直接忽略，保证只有一个终态生效。
    func cancel() {
        let inTerminal = (phase == .completed || phase == .cancelled || phase == .idle)
        guard !inTerminal, !isCancelling else {
            AppLog.compress("取消请求被忽略（已终态或正在取消）：phase=\(String(describing: phase))")
            return
        }
        isCancelling = true
        AppLog.compress("[Task \(currentRunID.uuidString.prefix(8))] 收到取消请求：协作式等待编码泵退出，不强制中断 Task")
        service.cancel()
        log("取消", "收到取消请求，等待引擎安全停止", taskIndex: nil)
        // 正在等待 Photos 保存的任务不再强行中断：保存成功即保留成品，取消只影响未完成部分
    }
}
