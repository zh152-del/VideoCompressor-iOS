import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import UIKit

/// 读取视频元信息（时长、尺寸、帧率、编码、文件大小），并生成缩略图。
struct VideoInfoReader {
    /// 读取文件元信息（不解码整段视频，速度快）。
    static func readInfo(at url: URL) async throws -> VideoMeta {
        let asset = AVAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw AppError.videoReadFailed }

        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { throw AppError.noVideoTrack }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let display = VideoGeometry.displaySize(after: transform, natural: naturalSize)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let codec = await codecDescription(of: videoTrack)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let creation = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate

        return VideoMeta(durationSeconds: duration,
                         width: Int(display.width),
                         height: Int(display.height),
                         fps: Double(fps),
                         codecDescription: codec,
                         fileSizeBytes: fileSize,
                         creationDate: creation)
    }

    /// 生成首帧缩略图并写入指定 URL（JPEG）。
    static func generateThumbnail(from url: URL, to destination: URL, maxEdge: CGFloat = 360) async throws {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        let cgImage = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, error in
                if let image = image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: error ?? AppError.videoReadFailed)
                }
            }
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8) else {
            throw AppError.unknown("缩略图编码失败")
        }
        try data.write(to: destination)
    }

    // MARK: - 私有辅助

    private static func codecDescription(of track: AVAssetTrack) async -> String {
        guard let desc = (try? await track.load(.formatDescriptions))?.first else { return "未知" }
        let codecType = CMFormatDescriptionGetMediaSubType(desc)
        let fourcc = VideoGeometry.fourCCString(codecType)
        switch fourcc {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v":         return "MPEG-4"
        default:             return fourcc
        }
    }
}

/// 视频元信息快照。
struct VideoMeta {
    let durationSeconds: Double
    let width: Int
    let height: Int
    let fps: Double
    let codecDescription: String
    let fileSizeBytes: Int64
    let creationDate: Date?
}
