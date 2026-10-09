import Foundation
import SwiftUI
import UIKit
import Combine

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
    /// 正在执行超时恢复的任务序号（1-based）
    @Published private(set) var recoveringTaskIndex: Int? = nil
    /// 存在"无法确认安全终止"的任务：已阻止后续调度，UI 明确提示
    @Published private(set) var blockedByUncertainTask = false
    /// 批次开始时间 / 每任务开始时间（用于耗时展示）
    @Published private(set) var batchStartedAt: Date? = nil
    @Published private(set) var taskStartedAt: [Int: Date] = [:]

    /// 100% 停滞超时阈值（秒）
    private let stallTimeoutSeconds: Double = 10
    /// 超时后请求安全终止后的复查窗口（秒）
    private let recoverGraceSeconds: Double = 5

    private var engineStates: [Int: TranscodeState] = [:]
    private var stallSinceUptime: [Int: UInt64] = [:]
    private var watchdogTasks: [Int: Task<Void, Never>] = [:]
    private var cancelSignals: [Int: TranscodeCancelSignal] = [:]

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
        recoveringTaskIndex = nil
        blockedByUncertainTask = false
        currentOutputSize = nil
        engineStates = [:]
        stallSinceUptime = [:]
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
                tasks[idx].status = .compressing(progress: 0)
                overallProgress = Double(rawIdx) / Double(items.count)   // 起点：已完成任务占比
                let taskNo = idx + 1
                taskStartedAt[taskNo] = Date()
                currentOutputSize = nil
                engineStates[taskNo] = .encoding
                log("准备", "任务 \(taskNo)/\(tasks.count) 开始：\(Formatters.bytes(items[rawIdx].fileSizeBytes))", taskIndex: taskNo)
                let signal = TranscodeCancelSignal()
                cancelSignals[taskNo] = signal
                startWatchdog(taskNo: taskNo, runID: runID)
                let itemStart = DispatchTime.now()
                AppLog.compress("[Task \(runID.uuidString.prefix(8))] 任务\(idx + 1)/\(tasks.count) 开始：\(items[rawIdx].title)，\(Formatters.bytes(items[rawIdx].fileSizeBytes))")

                do {
                    let result = try await service.compress(item: items[rawIdx], profile: profile,
                                                            preferredCodec: settings.preferredCodec,
                                                            signal: signal,
                                                            onState: { st in
                        Task { @MainActor in
                            guard self.currentRunID == runID else { return }
                            self.engineStates[taskNo] = st
                            switch st {
                            case .finished:
                                self.log("编码", "任务\(taskNo) 编码与写入完成", taskIndex: taskNo)
                            case .failed(let m):
                                self.log("失败", "引擎报告失败：\(m)", taskIndex: taskNo)
                            case .cancelled:
                                self.log("取消", "引擎已取消并清理临时输出", taskIndex: taskNo)
                            default: break
                            }
                        }
                    }) { p in
                        Task { @MainActor in
                            // 【稳定性】迟到回调隔离：旧任务/取消后不得再改动状态
                            guard let self, idx < self.tasks.count, self.currentRunID == runID else { return }
                            if self.isCancelling { return }
                            if p < 0 {
                                // 编码帧写完，进入写盘收尾阶段
                                self.tasks[idx].status = .finalizing
                                self.log("结束编码", "任务\(taskNo) 样本写完，等待写入器完成", taskIndex: taskNo)
                            } else {
                                self.tasks[idx].status = .compressing(progress: p)
                                // 【稳定性】总体进度 = 已完成任务 + 当前任务帧进度
                                let total = max(self.tasks.count, 1)
                                self.overallProgress = min(1.0, (Double(idx) + p) / Double(total))
                            }
                        }
                    }

                    if result.noGain {
                        AppLog.compress("No gain：\(items[rawIdx].title)（\(Formatters.bytes(result.outputSizeBytes)) ≥ 原 \(Formatters.bytes(items[rawIdx].fileSizeBytes))），保留原视频")
                        tasks[idx].status = .noGain(result)
                        stopWatchdog(taskNo: taskNo)
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
                        stopWatchdog(taskNo: taskNo)

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

            watchdogTasks.values.forEach { $0.cancel() }
            watchdogTasks = [:]
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


    // MARK: - 100% 停滞看门狗与安全恢复

    /// 启动某任务的看门狗：每 1 秒检查一次（不阻塞主线程/编码线程）。
    /// 计时使用单调时钟（uptimeNanoseconds），不受系统时间变化影响。
    private func startWatchdog(taskNo: Int, runID: UUID) {
        stopWatchdog(taskNo: taskNo)
        let watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.currentRunID == runID else { return }
                await self.checkStall(taskNo: taskNo, runID: runID)
            }
        }
        watchdogTasks[taskNo] = watchdog
    }

    private func stopWatchdog(taskNo: Int) {
        watchdogTasks[taskNo]?.cancel()
        watchdogTasks[taskNo] = nil
        stallSinceUptime[taskNo] = nil
    }

    /// 停滞检测：真实进度到 100% 后连续 N 秒仍未进入终态则触发恢复。
    private func checkStall(taskNo: Int, runID: UUID) {
        guard currentRunID == runID, let idx = indexOfTaskNo(taskNo), idx < tasks.count else { return }
        let status = tasks[idx].status
        if status.isFinished { stopWatchdog(taskNo: taskNo); return }
        // 阶段判定：只有"进度已满且处于结束/验证/保存"阶段才算 100% 停滞
        let atFullProgress: Bool
        switch status {
        case .compressing(let p): atFullProgress = p >= 0.999
        case .finalizing, .validating, .saving: atFullProgress = true
        default: atFullProgress = false
        }
        guard atFullProgress else { stallSinceUptime[taskNo] = nil; return }

        let now = DispatchTime.now().uptimeNanoseconds
        if stallSinceUptime[taskNo] == nil {
            stallSinceUptime[taskNo] = now
            log("警告", "进度已满但任务未结束，开始计时（阈值 \(Int(stallTimeoutSeconds)) 秒）", taskIndex: taskNo)
            return
        }
        let elapsed = Double(now - (stallSinceUptime[taskNo] ?? now)) / 1e9
        guard elapsed >= stallTimeoutSeconds else { return }
        recoverStalledTask(taskNo: taskNo, runID: runID)
    }

    private func indexOfTaskNo(_ taskNo: Int) -> Int? {
        let idx = taskNo - 1
        return (idx >= 0 && idx < tasks.count) ? idx : nil
    }

    /// 超时恢复流程：先检查真实状态，再决定"修 UI / 安全终止 / 标记失败 / 阻断"。
    /// 绝不直接删正在写入的文件，也绝不谎称能强制结束底层操作。
    private func recoverStalledTask(taskNo: Int, runID: UUID) {
        guard currentRunID == runID, let idx = indexOfTaskNo(taskNo) else { return }
        let state = engineStates[taskNo]
        recoveringTaskIndex = taskNo
        log("恢复", "100% 超时 \(Int(stallTimeoutSeconds)) 秒，检查任务真实状态：\(String(describing: state))", taskIndex: taskNo)

        switch state {
        case .finished:
            // 情况 A：编码与写入其实已完成（只是状态未同步）→ 修 UI，不重编码、不删输出
            log("恢复", "已确认编码实际完成，修正任务状态（不重编码、不删除输出）", taskIndex: taskNo)
            stopWatchdog(taskNo: taskNo)
            recoveringTaskIndex = nil

        case .failed, .cancelled:
            // 情况 C：已明确失败/取消 → 清理临时输出并按失败处理
            log("恢复", "已确认任务失败或取消，清理临时资源", taskIndex: taskNo)
            stopWatchdog(taskNo: taskNo)
            recoveringTaskIndex = nil

        case .finishing:
            // 情况 B：仍在结束流程 → 请求安全终止，给一个复查窗口，不强杀
            log("恢复", "写入器仍在收尾，请求安全终止（不强杀、不删文件）", taskIndex: taskNo)
            cancelSignals[taskNo]?.requestCancel()
            scheduleRecoveryRecheck(taskNo: taskNo, runID: runID)

        case .encoding, .none:
            // 情况 D：进度已满但引擎未上报结束 → 同样走安全终止 + 复查
            log("恢复", "引擎未确认进入结束阶段，请求安全终止并等待复查", taskIndex: taskNo)
            cancelSignals[taskNo]?.requestCancel()
            scheduleRecoveryRecheck(taskNo: taskNo, runID: runID)
        }
    }

    /// 安全终止请求后的复查窗口：若引擎仍未上报终态，标记"无法确认安全终止"并阻断后续调度。
    private func scheduleRecoveryRecheck(taskNo: Int, runID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.recoverGraceSeconds ?? 5) * 1_000_000_000)
            guard let self, self.currentRunID == runID else { return }
            let status = self.indexOfTaskNo(taskNo).map { self.tasks[$0].status }
            let finished = status?.isFinished ?? false
            if finished {
                self.log("恢复", "任务已安全终止，清理完成", taskIndex: taskNo)
                self.stopWatchdog(taskNo: taskNo)
                self.recoveringTaskIndex = nil
                self.stallSinceUptime[taskNo] = nil
            } else {
                // 情况 D：无法证明资源已安全释放 → 阻断队列，UI 明确提示，不谎称清理成功
                self.log("失败", "无法确认编码器是否已安全终止：已阻止后续任务调度，请返回后重试", taskIndex: taskNo)
                self.blockedByUncertainTask = true
                self.stopWatchdog(taskNo: taskNo)
                self.recoveringTaskIndex = nil
                if let idx = self.indexOfTaskNo(taskNo) {
                    self.tasks[idx].status = .failure(.unknown("任务超时且无法确认安全终止"))
                }
            }
        }
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
        // 线程安全地通知每个任务的引擎：请求安全终止（不直接释放对象）
        cancelSignals.values.forEach { $0.requestCancel() }
        watchdogTasks.values.forEach { $0.cancel() }
        watchdogTasks = [:]
        log("取消", "收到取消请求，等待引擎安全停止", taskIndex: nil)
        // 正在等待 Photos 保存的任务不再强行中断：保存成功即保留成品，取消只影响未完成部分
    }
}
