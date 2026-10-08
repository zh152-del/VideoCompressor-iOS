import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// 自定义转码选项。
struct TranscodeOptions {
    var maxHeight: Int?      // nil = 保持源分辨率（绝不放大）
    var fps: Double?         // nil = 保持源帧率
    var quality: Double = 0.7
    var codec: VideoCodec = .hevc
    var targetSizeBytes: Int64? = nil
    /// 显式视频码率(bps)。设置后优先于 quality / targetSizeBytes 计算。
    var explicitBitrate: Int64? = nil
}

/// 自定义转码引擎：AVAssetReader + AVAssetWriter（走 VideoToolbox 硬件编码）。
///
/// 稳定性设计（Stability Debug Mode）：
/// 1. 【关键修复】音频链路：reader 输出必须解压为 Linear PCM，
///    writer input 再编码为 AAC。此前 reader 以 outputSettings:nil 直通**压缩音频**，
///    喂给要重新编码的 input 会造成 CMFormatDescription 不匹配 →
///    AudioToolbox 抛 Swift 无法捕获的 ObjC 异常 → 点击开始压缩后立即闪退。
/// 2. 背压正确处理：input 未 ready 时等待重试**同一个**样本，绝不丢样本、绝不紧循环。
/// 3. 样本合法性校验：PTS 无效/为负/倒退的样本直接跳过，不进编码器。
/// 4. 每阶段日志（AppLog），任何失败路径都有明确出口并清理产物。
struct TranscodeEngine {

    static func transcode(asset: AVAsset, outputURL: URL, options: TranscodeOptions,
                          progress: ((Double) -> Void)? = nil,
                          isCancelled: (() -> Bool)? = nil) async throws {
        AppLog.compress("Encoding start → \(outputURL.lastPathComponent)")
        try? FileManager.default.removeItem(at: outputURL)
        // 确保输出父目录存在，否则 AVAssetWriter 初始化会失败
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            AppLog.compress("[ERROR] create output dir failed: \(error.localizedDescription)")
            throw AppError.exportFailed
        }

        // MARK: - Reader

        guard let reader = try? AVAssetReader(asset: asset) else {
            let reason = (try? AVAssetReader(asset: asset)) == nil ? "创建失败" : "未知"
            AppLog.compress("[ERROR] AVAssetReader 创建失败：\(reason)")
            throw AppError.videoReadFailed
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            AppLog.compress("[ERROR] 视频轨道不存在")
            throw AppError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let display = VideoGeometry.displaySize(after: transform, natural: naturalSize)
        let sourceFps = try await videoTrack.load(.nominalFrameRate)
        let videoFormatDescs = try await videoTrack.load(.formatDescriptions)
        let duration = try await asset.load(.duration).seconds

        // 时长合法性：invalid / indefinite / 非正数一律拒绝
        guard duration.isFinite, duration > 0 else {
            AppLog.compress("[ERROR] 视频时长无效：\(duration)")
            throw AppError.videoReadFailed
        }

        // MARK: - 目标尺寸（绝不放大；奇数尺寸向上取偶）

        let srcH = max(1, Int(display.height))
        let srcW = max(1, Int(display.width))
        guard srcH > 0, srcW > 0, display.width.isFinite, display.height.isFinite else {
            AppLog.compress("[ERROR] 视频尺寸无效：\(display)")
            throw AppError.videoReadFailed
        }
        let targetH = options.maxHeight.map { min($0, srcH) } ?? srcH
        let scale = Double(targetH) / Double(srcH)
        let targetW = options.maxHeight == nil ? srcW : max(2, Int(Double(srcW) * scale))
        let outW = Self.makeEven(max(2, targetW))
        let outH = Self.makeEven(max(2, targetH))

        // MARK: - 码率（下限保护，禁止 0/负数进入编码器）

        let bitrate: Int64 = {
            let raw: Int64
            if let explicit = options.explicitBitrate, explicit > 0 {
                raw = explicit
            } else if let t = options.targetSizeBytes, t > 0 {
                raw = BitrateCalculator.bitrate(targetBytes: t, durationSeconds: duration)
            } else {
                raw = BitrateCalculator.bitrate(quality: max(options.quality, 0.1), height: outH)
            }
            return min(max(raw, 300_000), 60_000_000)
        }()

        // 帧率：源帧率无效时用安全默认值，绝不除零
        let safeSourceFps = sourceFps > 0 ? Double(sourceFps) : 30.0
        let fps = max(1.0, min(options.fps ?? safeSourceFps, safeSourceFps))
        let fpsInterval = 1.0 / Double(fps)
        AppLog.compress("参数：\(outW)×\(outH)，\(String(format: "%.1f", fps))fps，bitrate=\(bitrate)bps，时长=\(String(format: "%.1f", duration))s")

        // MARK: - Writer

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            AppLog.compress("[ERROR] AVAssetWriter 创建失败（可能磁盘空间不足/路径非法）")
            throw AppError.exportFailed
        }

        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: max(2, Int(fps) * 2)
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodecType,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings,
            sourceFormatHint: videoFormatDescs.first
        )
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            AppLog.compress("[ERROR] writer 不能添加视频 input")
            throw AppError.exportFailed
        }
        writer.add(videoInput)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        guard reader.canAdd(videoOutput) else {
            AppLog.compress("[ERROR] reader 不能添加视频 output")
            throw AppError.exportFailed
        }
        reader.add(videoOutput)

        // MARK: - 音频【关键修复】：reader 解压为 PCM，writer 编码为 AAC
        // 此前 reader outputSettings:nil（直通压缩音频）+ writer 要编码 AAC = 格式不匹配 → ObjC 异常闪退。

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            if reader.canAdd(ao) {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ]
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                ai.expectsMediaDataInRealTime = false
                if writer.canAdd(ai) {
                    writer.add(ai)
                    audioInput = ai
                    reader.add(ao)
                    audioOutput = ao
                    AppLog.compress("音频链路：PCM 解压 → AAC 编码")
                }
            }
        }

        // MARK: - 启动

        guard reader.startReading() else {
            AppLog.compress("[ERROR] reader.startReading 失败：\(reader.error?.localizedDescription ?? "未知")")
            throw AppError.videoReadFailed
        }
        guard writer.startWriting() else {
            AppLog.compress("[ERROR] writer.startWriting 失败：\(writer.error?.localizedDescription ?? "未知")")
            throw AppError.exportFailed
        }
        writer.startSession(atSourceTime: .zero)
        AppLog.compress("startWriting/startReading 成功，进入编码")

        // MARK: - 采样泵（背压正确处理：等待重试同一样本，绝不丢失）

        /// 等待 input ready（10ms 轮询，随时响应取消）。
        func waitForInput(_ input: AVAssetWriterInput) async -> Bool {
            var spins = 0
            while !input.isReadyForMoreMediaData {
                if isCancelled?() == true { return false }
                spins += 1
                if spins > 3000 {   // ~30s 仍未 ready：编码器异常，避免死循环
                    AppLog.compress("[ERROR] input 超过 30s 未 ready，终止")
                    return false
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return true
        }

        /// 校验 PTS：invalid / 负值 / NaN 一律拒收。
        func validPTS(_ sample: CMSampleBuffer) -> Bool {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let secs = CMTimeGetSeconds(pts)
            return pts.isNumeric && secs.isFinite && secs >= 0
        }

        var encodingError: Error?

        let videoPump = Task {
            var lastEmitted: CMTime = .invalid
            var emitted = 0
            while true {
                if isCancelled?() == true { break }
                guard let sample = videoOutput.copyNextSampleBuffer() else { break }  // 正常结束
                guard validPTS(sample) else { continue }

                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                // 抽帧：过密帧跳过（保持原始时间戳以维持音画同步）
                if lastEmitted.isValid {
                    let delta = CMTimeSubtract(pts, lastEmitted).seconds
                    if delta < fpsInterval * 0.9 { continue }
                }

                guard await waitForInput(videoInput) else { break }
                if videoInput.append(sample) {
                    lastEmitted = pts
                    emitted += 1
                    if duration > 0 {
                        progress?(min(max(CMTimeGetSeconds(pts) / duration, 0), 1))
                    }
                } else {
                    AppLog.compress("[ERROR] video append 失败（writer 状态：\(writer.status.rawValue)）：\(writer.error?.localizedDescription ?? "无")")
                    encodingError = AppError.compressionFailed(writer.error?.localizedDescription ?? "视频帧写入失败")
                    break
                }
            }
            videoInput.markAsFinished()
            AppLog.compress("视频泵结束：已写入 \(emitted) 帧")
        }

        let audioPump = Task {
            guard let audioInput = audioInput, let audioOutput = audioOutput else { return }
            var appended = 0
            while true {
                if isCancelled?() == true { break }
                guard let sample = audioOutput.copyNextSampleBuffer() else { break }
                guard validPTS(sample) else { continue }
                guard await waitForInput(audioInput) else { break }
                if audioInput.append(sample) {
                    appended += 1
                } else {
                    AppLog.compress("[ERROR] audio append 失败：\(writer.error?.localizedDescription ?? "无")")
                    break
                }
            }
            audioInput.markAsFinished()
            AppLog.compress("音频泵结束：已写入 \(appended) 帧")
        }

        await videoPump.value
        await audioPump.value

        // MARK: - 收尾（严格顺序：markAsFinished 已由泵执行 → finishWriting → 校验状态）

        if isCancelled?() == true && writer.status == .writing {
            writer.cancelWriting()
        }
        await writer.finishWriting()

        if isCancelled?() == true {
            try? FileManager.default.removeItem(at: outputURL)
            AppLog.compress("编码已取消，临时产物已清理")
            throw AppError.userCancelled
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            let detail = encodingError.map { ($0 as? AppError)?.errorDescription } ?? writer.error?.localizedDescription
            AppLog.compress("[ERROR] 编码失败（writer.status=\(writer.status.rawValue)）：\(detail ?? "未知")")
            throw AppError.compressionFailed(detail ?? "写入失败")
        }

        // MARK: - 输出校验：存在 / 大小 > 0 / 可被 AVAsset 读取

        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        guard outSize > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            AppLog.compress("[ERROR] 输出文件为空")
            throw AppError.outputFileEmpty
        }
        let outAsset = AVAsset(url: outputURL)
        guard (try? await outAsset.loadTracks(withMediaType: .video))?.first != nil else {
            try? FileManager.default.removeItem(at: outputURL)
            AppLog.compress("[ERROR] 输出文件无法读取视频轨道（损坏）")
            throw AppError.outputFileEmpty
        }
        AppLog.compress("Encoding complete：输出 \(Formatters.bytes(outSize))")
    }

    /// 将尺寸向上取整为偶数，满足 H.264/HEVC 编码器对宽高的对齐要求。
    private static func makeEven(_ v: Int) -> Int {
        return v % 2 == 0 ? v : v + 1
    }
}
