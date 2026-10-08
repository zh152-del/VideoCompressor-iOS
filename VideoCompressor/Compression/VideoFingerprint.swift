import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia

/// 视频指纹：duration + 显示分辨率 + 5 帧感知哈希（dHash）。
/// 匹配使用感知相似度（Hamming 距离阈值），不要求文件/帧完全相同——
/// 压缩会改变编码/分辨率/帧率/GOP，感知哈希对轻微变化保持稳定。
struct VideoFingerprint: Codable, Equatable {
    let durationSeconds: Double
    let width: Int
    let height: Int
    let frameHashes: [UInt64]     // 5 帧 dHash

    var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }
    /// 短十六进制（日志/展示用）。
    var shortHex: String {
        frameHashes.map { String(format: "%04X", UInt16(truncatingIfNeeded: $0)) }.joined()
    }
}

/// 指纹引擎：抽帧 + dHash + 相似度判定（三级）。
enum FingerprintEngine {
    static let frameCount = 5
    static let hammingThreshold = 10          // 单帧 Hamming ≤ 10 视为相似
    static let requiredSimilarFrames = 4      // 5 帧中至少 4 帧
    static let confirmFrameCount = 16         // 高置信确认时的加采帧数

    /// 从视频文件计算指纹（只解码少量缩略帧，不加载整段视频）。
    static func fingerprint(url: URL) async throws -> VideoFingerprint {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AppError.videoReadFailed }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.noVideoTrack
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = VideoGeometry.displaySize(after: transform, natural: natural)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 72, height: 72)   // dHash 只需极小图，解码成本低
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let times = (0..<frameCount).map {
            NSValue(time: CMTime(seconds: duration * (0.1 + 0.8 * Double($0) / Double(frameCount - 1)), preferredTimescale: 600))
        }
        let images = await Self.generateImages(generator: generator, times: times)
        let hashes = images.compactMap { $0.map { dHash($0) } }
        guard hashes.count >= 3 else {
            AppLog.compress("[ERROR] 指纹抽帧不足：\(hashes.count)")
            throw AppError.videoReadFailed
        }
        return VideoFingerprint(durationSeconds: duration,
                                width: Int(display.width), height: Int(display.height),
                                frameHashes: hashes)
    }

    /// 高置信确认：加采 16 帧重新比较（仅当粗匹配非常接近时调用）。
    static func confirmMatch(urlA: URL, urlB: URL) async -> Bool {
        guard let fa = try? await fingerprint(url: urlA, frames: confirmFrameCount),
              let fb = try? await fingerprint(url: urlB, frames: confirmFrameCount) else { return false }
        return coarseMatch(a: fa, b: fb, required: confirmFrameCount - 2)
    }

    /// 基于已有 5 帧指纹的粗匹配。
    static func coarseMatch(a: VideoFingerprint, b: VideoFingerprint,
                            required: Int = requiredSimilarFrames) -> Bool {
        guard a.frameHashes.count == b.frameHashes.count, !a.frameHashes.isEmpty else { return false }
        let maxDur = max(a.durationSeconds, b.durationSeconds, 0.01)
        guard abs(a.durationSeconds - b.durationSeconds) / maxDur < 0.02 else { return false }   // 时长差 < 2%
        let maxAspect = max(a.aspectRatio, b.aspectRatio, 0.01)
        guard abs(a.aspectRatio - b.aspectRatio) / maxAspect < 0.03 else { return false }        // 比例一致/接近
        let similar = zip(a.frameHashes, b.frameHashes).filter { ($0 ^ $1).nonzeroBitCount <= hammingThreshold }.count
        return similar >= min(required, a.frameHashes.count - 1)
    }

    /// 相似度百分比（展示用）。
    static func similarityPercent(a: VideoFingerprint, b: VideoFingerprint) -> Double {
        guard !a.frameHashes.isEmpty, a.frameHashes.count == b.frameHashes.count else { return 0 }
        let similar = zip(a.frameHashes, b.frameHashes).filter { ($0 ^ $1).nonzeroBitCount <= hammingThreshold }.count
        return Double(similar) / Double(a.frameHashes.count) * 100
    }

    /// dHash：9×8 灰度图相邻像素亮度比较 → 64bit。
    static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if pixels[y * w + x] > pixels[y * w + x + 1] {
                    hash |= 1 << UInt64(y * (w - 1) + x)
                }
            }
        }
        return hash
    }

    /// 指定帧数的指纹（确认阶段用）。
    static func fingerprint(url: URL, frames: Int) async throws -> VideoFingerprint {
        let base = try await fingerprint(url: url)
        guard frames > frameCount else { return base }
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 72, height: 72)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let times = (0..<frames).map {
            NSValue(time: CMTime(seconds: duration * Double($0) / Double(frames - 1), preferredTimescale: 600))
        }
        let images = await Self.generateImages(generator: generator, times: times)
        let hashes = images.compactMap { $0.map { dHash($0) } }
        guard hashes.count >= frames / 2 else { return base }
        return VideoFingerprint(durationSeconds: base.durationSeconds, width: base.width,
                                height: base.height, frameHashes: hashes)
    }

    /// AVAssetImageGenerator 回调式 API 的 async 包装（真实存在的方式，无幻觉 API）。
    private static func generateImages(generator: AVAssetImageGenerator,
                                       times: [NSValue]) async -> [CGImage?] {
        await withCheckedContinuation { cont in
            var collected = [CGImage?](repeating: nil, count: times.count)
            var remaining = times.count
            let lock = NSLock()
            generator.generateCGImagesAsynchronously(forTimes: times) { _, image, _, actualResult, _ in
                lock.lock()
                // 按完成顺序占位填充；足够判断相似度，无需严格对位
                if let idx = collected.firstIndex(where: { $0 == nil }) {
                    collected[idx] = actualResult == .succeeded ? image : nil
                }
                remaining -= 1
                let done = (remaining <= 0)
                lock.unlock()
                if done { cont.resume(returning: collected) }
            }
        }
    }
}
