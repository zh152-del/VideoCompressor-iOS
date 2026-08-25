import Foundation

/// 码率与文件大小估算。
enum BitrateCalculator {
    /// 参考码率（bps）：基于目标高度的经验值。
    private static func referenceBitrate(height: Int) -> Int64 {
        switch height {
        case ..<480:  return 1_500_000
        case ..<720:  return 3_000_000
        case ..<1080: return 5_000_000
        case ..<1440: return 8_000_000
        case ..<2160: return 12_000_000
        default:      return 18_000_000
        }
    }

    /// 根据画质系数(0..1)与目标高度计算视频平均码率(bps)。
    static func bitrate(quality: Double, height: Int) -> Int64 {
        let q = min(max(quality, 0.1), 1.2)
        let base = Double(referenceBitrate(height: height))
        return Int64(base * q)
    }

    /// 根据目标文件大小(字节)与时长反推视频码率(bps)，为音频预留空间。
    static func bitrate(targetBytes: Int64, durationSeconds: Double) -> Int64 {
        let audioBytes = 200_000 * 8 // 约 200KB 音频
        guard durationSeconds > 0 else { return 2_000_000 }
        let videoBytes = max(targetBytes - audioBytes, 50_000)
        let bps = Int64(Double(videoBytes * 8) / durationSeconds)
        return min(max(bps, 200_000), 50_000_000)
    }
}
