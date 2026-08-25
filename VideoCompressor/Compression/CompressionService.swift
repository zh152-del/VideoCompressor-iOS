import Foundation
import AVFoundation
import UIKit

/// 压缩编排服务：协调读取、导出/转码、进度上报、取消、临时文件与后台任务。
/// 设计为普通类（跨线程安全），所有 UI 更新通过主线程派发。
final class CompressionService {
    private var isCancelled = false
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    func cancel() {
        isCancelled = true
        endBackgroundTask()
    }

    // MARK: - 后台任务（App 切到后台时尽量不被系统杀死）

    private func beginBackgroundTask() {
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoCompression") { [weak self] in
            self?.cancel()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }

    // MARK: - 批量压缩

    /// 批量压缩。回调均在主线程派发。
    /// - Parameters:
    ///   - perVideo: (视频下标, 该视频进度 0..1)
    ///   - progress: 整体进度 0..1
    ///   - onTaskComplete: (视频下标, 结果)
    func compressBatch(items: [VideoItem], profile: CompressionProfile,
                       perVideo: ((Int, Double) -> Void)? = nil,
                       progress: ((Double) -> Void)? = nil,
                       onTaskComplete: ((Int, CompressionResult) -> Void)? = nil) async throws -> [CompressionResult] {
        isCancelled = false
        beginBackgroundTask()
        defer { endBackgroundTask() }

        var results: [CompressionResult] = []
        let total = Double(items.count)
        for (index, item) in items.enumerated() {
            if isCancelled { throw AppError.userCancelled }
            let result = try await compressOne(item: item, profile: profile, index: index,
                                               perVideo: { p in DispatchQueue.main.async { perVideo?(index, p) } })
            results.append(result)
            DispatchQueue.main.async { onTaskComplete?(index, result) }
            DispatchQueue.main.async { progress?(Double(index + 1) / total) }
        }
        return results
    }

    // MARK: - 单个压缩

    private func compressOne(item: VideoItem, profile: CompressionProfile, index: Int,
                             perVideo: ((Double) -> Void)?) async throws -> CompressionResult {
        let asset = AVAsset(url: item.sourceURL)
        let outputURL = TempFileManager.shared.newOutputURL()
        let cancelled: () -> Bool = { [weak self] in self?.isCancelled ?? true }

        do {
            switch profile.mode {
            case .quick, .balanced, .high:
                let preset = ExportPresetEngine.preset(for: profile.mode, sourceHeight: item.height)
                try await ExportPresetEngine.export(asset: asset, outputURL: outputURL, preset: preset,
                                                    progress: perVideo, isCancelled: cancelled)
            case .custom:
                let wantHEVC = profile.custom.codec == .hevc
                let useHEVC = wantHEVC && CodecSupport.isHEVCEncodingSupported()
                let opts = TranscodeOptions(
                    maxHeight: profile.custom.resolution.targetHeight,
                    fps: profile.custom.fps > 0 ? profile.custom.fps : nil,
                    quality: profile.custom.quality,
                    codec: useHEVC ? .hevc : .h264,
                    targetSizeBytes: profile.custom.targetSizeMB.map { Int64($0 * 1_000_000) }
                )
                try await TranscodeEngine.transcode(asset: asset, outputURL: outputURL, options: opts,
                                                    progress: perVideo, isCancelled: cancelled)
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

        // 读取输出信息
        let outMeta = try? await VideoInfoReader.readInfo(at: outputURL)
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return CompressionResult(
            item: item,
            outputURL: outputURL,
            outputSizeBytes: outSize,
            outputWidth: outMeta?.width ?? item.width,
            outputHeight: outMeta?.height ?? item.height,
            outputCodec: outMeta?.codecDescription ?? "未知",
            durationSeconds: item.durationSeconds,
            profile: profile,
            savedPhotoLocalIdentifier: nil
        )
    }
}
