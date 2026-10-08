import Foundation

/// 码率与文件大小估算。
///
/// 核心原则：压缩目标码率必须依据【源文件实际码率】推导，而不是固定经验值。
/// 否则低码率源（如 31MB 的长视频）被以固定 1080p 高码率重编码后会「反向压缩」变大。
enum BitrateCalculator {
    /// 参考码率（bps）：基于目标高度的经验值（代表「该分辨率下的良好画质」水平，
    /// 同时也是重编码码率的上限——超过它毫无意义）。
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
        guard durationSeconds > 0 else { return 2_000_000 }
        // 音频按 AAC 128kbps 预留（与转码引擎的音频设置一致）
        let audioBytes = Int64(Double(128_000) / 8.0 * durationSeconds)
        let videoBytes = max(targetBytes - audioBytes, 50_000)
        let bps = Int64(Double(videoBytes * 8) / durationSeconds)
        return min(max(bps, 200_000), 50_000_000)
    }

    // MARK: - 基于源码率的目标码率推导

    /// 各模式的压缩系数：目标视频码率 = 源视频码率 × 系数。
    /// quick 尽量保画质、high 尽量压体积。custom 不使用该系数。
    static func factor(for mode: CompressionMode) -> Double {
        switch mode {
        case .quick:    return 0.75
        case .balanced: return 0.55
        case .high:     return 0.35
        case .custom:   return 0.55
        }
    }

    /// 根据源文件大小 / 时长 / 分辨率 / FPS / 音频，计算目标视频码率(bps)。
    /// - Returns: nil 表示「按此系数已无法有效压缩」（源码率本身已很低），
    ///            调用方应跳过重编码，避免产出更大的文件。
    static func targetVideoBitrate(sourceBytes: Int64,
                                   durationSeconds: Double,
                                   height: Int,
                                   fps: Double,
                                   hasAudio: Bool = true,
                                   factor: Double) -> Int64? {
        guard sourceBytes > 0, durationSeconds > 0.3 else { return nil }
        // 源总码率，扣除音频后得到源视频码率
        let audioBps: Int64 = hasAudio ? 128_000 : 0
        let sourceTotalBps = Double(sourceBytes) * 8.0 / durationSeconds
        let sourceVideoBps = max(sourceTotalBps - Double(audioBps), 100_000)

        // 目标 = 源视频码率 × 系数；上限为该分辨率的参考码率（重编码到更高毫无意义）
        let ceiling = Double(referenceBitrate(height: max(1, height)))
        var target = min(sourceVideoBps * max(factor, 0.05), ceiling)

        // 下限：低于该分辨率良好画质 30% 的码率会严重劣化，宁可不压也不产马赛克
        let floor = Double(referenceBitrate(height: max(1, height))) * 0.30
        target = max(target, floor)

        // 预估输出大小 = (视频 + 音频) 码率 × 时长 / 8 × 容器开销(2%)
        let estimateBytes = (target + Double(audioBps)) * durationSeconds / 8.0 * 1.02
        // 预估都无法降到源的 92% 以下 → 放弃，返回 nil（避免无意义的重编码）
        if estimateBytes >= Double(sourceBytes) * 0.92 { return nil }
        return Int64(target)
    }

    /// 预估压缩后的输出文件大小（字节）。nil 表示预计无法有效压缩。
    static func estimateOutputBytes(fileSizeBytes: Int64,
                                    durationSeconds: Double,
                                    height: Int,
                                    fps: Double,
                                    mode: CompressionMode,
                                    custom: CustomSettings = CustomSettings(),
                                    hasAudio: Bool = true) -> Int64? {
        // 自定义模式：指定目标大小时直接使用
        if mode == .custom {
            if let mb = custom.targetSizeMB {
                return Int64(mb * 1_000_000)
            }
            // 自定义分辨率/画质：仍按源码率推导（系数取画质）
            guard let bps = targetVideoBitrate(sourceBytes: fileSizeBytes,
                                               durationSeconds: durationSeconds,
                                               height: custom.resolution.targetHeight ?? height,
                                               fps: custom.fps > 0 ? custom.fps : fps,
                                               hasAudio: hasAudio,
                                               factor: max(custom.quality, 0.2)) else { return nil }
            let audioBps: Int64 = hasAudio ? 128_000 : 0
            return Int64((Double(bps) + Double(audioBps)) * durationSeconds / 8.0 * 1.02)
        }

        let maxHeight = Self.modeMaxHeight(for: mode, sourceHeight: height)
        guard let bps = targetVideoBitrate(sourceBytes: fileSizeBytes,
                                           durationSeconds: durationSeconds,
                                           height: maxHeight ?? height,
                                           fps: fps,
                                           hasAudio: hasAudio,
                                           factor: factor(for: mode)) else { return nil }
        let audioBps: Int64 = hasAudio ? 128_000 : 0
        return Int64((Double(bps) + Double(audioBps)) * durationSeconds / 8.0 * 1.02)
    }

    /// 各模式的目标高度上限（不放大源分辨率）。
    static func modeMaxHeight(for mode: CompressionMode, sourceHeight: Int) -> Int? {
        switch mode {
        case .quick:    return sourceHeight        // 保持源分辨率
        case .balanced: return min(1080, sourceHeight)
        case .high:     return min(720, sourceHeight)
        case .custom:   return CustomSettings().resolution.targetHeight
        }
    }
}
