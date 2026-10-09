import Foundation
import AVFoundation
import UIKit

/// 压缩编排服务：协调读取、转码、进度上报、取消、临时文件与后台任务。
///
/// 压缩策略（修复「反向压缩」）：
/// 1. 所有模式统一走 TranscodeEngine（AVAssetReader + AVAssetWriter，硬件编码），
///    不再使用 AVAssetExportSession 固定预设——预设码率与源码率无关，
///    低码率源重编码后会变大。
/// 2. 目标码率由 BitrateCalculator 依据【源文件实际码率】推导。
/// 3. 压缩完成后必须校验：输出文件存在、大小 > 0、且严格小于源文件。
///    校验失败（或仍然更大）→ 删除输出，标记 noGain，绝不把更大的文件当「压缩成功」。
/// 4. noGain 前置判定：估算已无法有效缩小的视频直接跳过编码，节省时间与电量。
/// 设计为普通类（跨线程安全），所有 UI 更新通过主线程派发。
final class CompressionService {
    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    /// 新任务开始前重置取消标志。
    func resetCancellation() {
        isCancelled = false
    }

    /// 供会话层查询取消状态。
    var isCancelledFlag: Bool { isCancelled }

    // MARK: - 单个压缩（含校验与一次重试）
    // 后台任务（UIBackgroundTask）包裹已上移到 CompressionSession（MainActor 上 begin/end），
    // 避免 compress 在非主线程调用 UIApplication.shared 造成的线程安全隐患。

    /// 压缩单个视频。回调在调用方线程（服务内部仅 100ms 节流上报）。
    /// - Returns: CompressionResult。`noGain == true` 表示未能有效压缩
    ///            （输出文件已被删除，原视频应保留，不得保存/删除原片）。
    func compress(item: VideoItem, profile: CompressionProfile,
                  preferredCodec: VideoCodec = .hevc,
                  progress: ((Double) -> Void)? = nil) async throws -> CompressionResult {
        let cancelled: () -> Bool = { [weak self] in self?.isCancelled ?? true }
        let tTaskStart = DispatchTime.now().uptimeNanoseconds
        AppLog.perf("输入：\(Formatters.bytes(item.fileSizeBytes))，\(item.width)×\(item.height)，\(String(format: "%.1f", item.durationSeconds))s，\(item.codecDescription)")

        // ---- 前置判定：估算已无法有效压缩 → 跳过编码，直接 noGain ----
        let estimate = BitrateCalculator.estimateOutputBytes(
            fileSizeBytes: item.fileSizeBytes,
            durationSeconds: item.durationSeconds,
            height: item.height, fps: item.fps,
            mode: profile.mode, custom: profile.custom)
        if item.fileSizeBytes > 0, let est = estimate,
           Double(est) >= Double(item.fileSizeBytes) * 0.92 {
            return Self.noGainResult(item: item, profile: profile, attemptedBytes: item.fileSizeBytes)
        }

        // ---- 首次编码 ----
        var (outputURL, outMeta, outSize) = try await encode(item: item, profile: profile,
                                                             preferredCodec: preferredCodec,
                                                             progress: progress, cancelled: cancelled)

        // ---- 校验：必须严格小于源文件，否则按规范重试一次更激进的参数 ----
        if outSize >= item.fileSizeBytes && !cancelled() {
            TempFileManager.shared.remove(outputURL)
            // 仅在非「高压缩」模式重试一次（高压缩已是最低参数，重试无意义）
            if profile.mode != .high {
                let retryProfile = CompressionProfile(mode: .high, custom: profile.custom)
                (outputURL, outMeta, outSize) = try await encode(item: item, profile: retryProfile,
                                                                 preferredCodec: preferredCodec,
                                                                 progress: nil, cancelled: cancelled)
            }
        }

        // ---- 最终校验 ----
        if outSize >= item.fileSizeBytes {
            TempFileManager.shared.remove(outputURL)
            return Self.noGainResult(item: item, profile: profile, attemptedBytes: outSize)
        }

        return CompressionResult(
            item: item,
            outputURL: outputURL,
            outputSizeBytes: outSize,
            outputWidth: outMeta?.width ?? item.width,
            outputHeight: outMeta?.height ?? item.height,
            outputCodec: outMeta?.codecDescription ?? "未知",
            durationSeconds: item.durationSeconds,
            profile: profile,
            savedPhotoLocalIdentifier: nil,
            noGain: false
        )
    }

    // MARK: - 私有：按 profile 执行一次编码

    /// - Returns: (输出URL, 输出元信息, 输出大小)
    private func encode(item: VideoItem, profile: CompressionProfile,
                        preferredCodec: VideoCodec,
                        progress: ((Double) -> Void)?,
                        cancelled: @escaping () -> Bool) async throws -> (URL, VideoMeta?, Int64) {
        let asset = AVAsset(url: item.sourceURL)
        let outputURL = TempFileManager.shared.newOutputURL()

        do {
            switch profile.mode {
            case .quick, .balanced, .high:
                let maxHeight = BitrateCalculator.modeMaxHeight(for: profile.mode, sourceHeight: item.height)
                let bitrate = BitrateCalculator.targetVideoBitrate(
                    sourceBytes: item.fileSizeBytes,
                    durationSeconds: item.durationSeconds,
                    height: maxHeight ?? item.height,
                    fps: item.fps,
                    factor: BitrateCalculator.factor(for: profile.mode))
                    ?? max(300_000, BitrateCalculator.bitrate(quality: 0.5, height: maxHeight ?? item.height))
                let opts = TranscodeOptions(
                    maxHeight: maxHeight,
                    fps: nil,                       // 保持源帧率
                    quality: 0,                     // 码率已显式指定，quality 不参与
                    codec: preferredCodec,
                    targetSizeBytes: nil,
                    explicitBitrate: bitrate)
                try await TranscodeEngine.transcode(asset: asset, outputURL: outputURL, options: opts,
                                                    progress: progress, isCancelled: cancelled)
            case .custom:
                let wantHEVC = profile.custom.codec == .hevc
                let useHEVC = wantHEVC && CodecSupport.isHEVCEncodingSupported()
                let opts = TranscodeOptions(
                    maxHeight: profile.custom.resolution.targetHeight,
                    fps: profile.custom.fps > 0 ? profile.custom.fps : nil,
                    quality: profile.custom.quality,
                    codec: useHEVC ? .hevc : .h264,
                    targetSizeBytes: profile.custom.targetSizeMB.map { Int64($0 * 1_000_000) })
                try await TranscodeEngine.transcode(asset: asset, outputURL: outputURL, options: opts,
                                                    progress: progress, isCancelled: cancelled)
            }
        } catch {
            TempFileManager.shared.remove(outputURL)
            if let appErr = error as? AppError { throw appErr }
            let nsErr = error as NSError
            if nsErr.domain == NSCocoaErrorDomain, nsErr.code == NSUserCancelledError {
                throw AppError.userCancelled
            }
            throw AppError.compressionFailed(error.localizedDescription)
        }

        let outMeta = try? await VideoInfoReader.readInfo(at: outputURL)
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return (outputURL, outMeta, outSize)
    }

    /// 构造 noGain 结果（outputURL 为 nil：不产出任何文件）。
    private static func noGainResult(item: VideoItem, profile: CompressionProfile,
                                     attemptedBytes: Int64) -> CompressionResult {
        CompressionResult(
            item: item,
            outputURL: nil,
            outputSizeBytes: attemptedBytes,
            outputWidth: item.width,
            outputHeight: item.height,
            outputCodec: item.codecDescription,
            durationSeconds: item.durationSeconds,
            profile: profile,
            savedPhotoLocalIdentifier: nil,
            noGain: true
        )
    }
}
