import Foundation
import AVFoundation

/// 使用系统 AVAssetExportSession 进行快速预设压缩（硬件加速、稳定）。
/// 适用于「快速 / 平衡 / 高压缩」三种模式。
struct ExportPresetEngine {
    /// 根据模式与源高度选择不超过源分辨率的导出预设，避免放大。
    static func preset(for mode: CompressionMode, sourceHeight: Int) -> String {
        let choose: ([(Int, String)]) -> String = { candidates in
            let valid = candidates.filter { $0.0 <= sourceHeight }
            if let lowest = valid.last { return lowest.1 }  // 在有效候选里取较低者
            return candidates.last!.1                       // 全部超限则取最低预设
        }
        switch mode {
        case .quick:
            return choose([(2160, AVAssetExportPreset3840x2160),
                           (1080, AVAssetExportPreset1920x1080),
                           (720,  AVAssetExportPreset1280x720),
                           (540,  AVAssetExportPreset960x540)])
        case .balanced:
            return choose([(1080, AVAssetExportPreset1920x1080),
                           (720,  AVAssetExportPreset1280x720),
                           (540,  AVAssetExportPreset960x540),
                           (480,  AVAssetExportPreset640x480)])
        case .high:
            return choose([(720,  AVAssetExportPreset1280x720),
                           (540,  AVAssetExportPreset960x540),
                           (480,  AVAssetExportPreset640x480)])
        case .custom:
            return AVAssetExportPreset1920x1080
        }
    }

    static func export(asset: AVAsset, outputURL: URL, preset: String,
                       progress: ((Double) -> Void)? = nil,
                       isCancelled: (() -> Bool)? = nil) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError.compressionFailed("无法创建导出会话")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4

        let monitor = Task {
            while !Task.isCancelled {
                if isCancelled?() == true { session.cancelExport(); break }
                progress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await withCheckedContinuation { cont in
            session.exportAsynchronously { cont.resume() }
        }
        monitor.cancel()

        if isCancelled?() == true || session.status == .cancelled {
            throw AppError.userCancelled
        }
        switch session.status {
        case .completed:
            progress?(1.0)
        case .failed:
            throw AppError.compressionFailed(session.error?.localizedDescription ?? "未知错误")
        default:
            throw AppError.compressionFailed("导出状态异常: \(session.status.rawValue)")
        }
    }
}
