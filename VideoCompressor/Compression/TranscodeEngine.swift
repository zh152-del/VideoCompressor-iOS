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
}

/// 自定义转码引擎：AVAssetReader + AVAssetWriter（走 VideoToolbox 硬件编码）。
/// 支持指定分辨率(不放大)、帧率(抽帧)、画质/码率、编码(H264/HEVC)、目标文件大小。
struct TranscodeEngine {
    static func transcode(asset: AVAsset, outputURL: URL, options: TranscodeOptions,
                          progress: ((Double) -> Void)? = nil,
                          isCancelled: (() -> Bool)? = nil) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        // 确保输出父目录存在（自定义输出路径场景下），否则 AVAssetWriter 初始化会失败
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        guard let reader = try? AVAssetReader(asset: asset) else { throw AppError.videoReadFailed }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let display = VideoGeometry.displaySize(after: transform, natural: naturalSize)
        let sourceFps = try await videoTrack.load(.nominalFrameRate)
        let videoFormatDescs = try await videoTrack.load(.formatDescriptions)
        let duration = try await asset.load(.duration).seconds

        // 计算目标尺寸：绝不放大低分辨率视频
        let targetH = options.maxHeight.map { min($0, Int(display.height)) } ?? Int(display.height)
        let scale = display.height > 0 ? Double(targetH) / Double(display.height) : 1.0
        let targetW = options.maxHeight == nil ? Int(display.width) : max(2, Int(Double(display.width) * scale))
        let outW = max(2, targetW)
        let outH = max(2, targetH)

        // 计算码率：目标文件大小优先，否则按画质系数
        let bitrate: Int64 = {
            if let t = options.targetSizeBytes {
                return BitrateCalculator.bitrate(targetBytes: t, durationSeconds: duration)
            }
            return BitrateCalculator.bitrate(quality: options.quality, height: outH)
        }()

        let fps = max(1.0, options.fps.map { min($0, Double(sourceFps) > 0 ? Double(sourceFps) : 30.0) } ?? (Double(sourceFps) > 0 ? Double(sourceFps) : 30.0))
        let fpsInterval = 1.0 / Double(fps)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw AppError.exportFailed
        }

        let profileLevel: String = options.codec == .hevc ? "HEVC_Main_AutoLevel" : "H264_High_AutoLevel"
        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            AVVideoProfileLevelKey: profileLevel
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
        videoInput.transform = transform   // 保持原始旋转信息
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw AppError.exportFailed }
        writer.add(videoInput)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        guard reader.canAdd(videoOutput) else { throw AppError.exportFailed }
        reader.add(videoOutput)

        // 音频（若存在）：原样透传并在写入端重新编码为 AAC
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
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
            }
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(ao) {
                reader.add(ao)
                audioOutput = ao
            }
        }

        guard reader.startReading() else { throw AppError.videoReadFailed }
        guard writer.startWriting() else { throw AppError.exportFailed }
        writer.startSession(atSourceTime: .zero)

        let monitor = Task {
            while !Task.isCancelled {
                if isCancelled?() == true {
                    writer.cancelWriting()
                    reader.cancelReading()
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // 视频泵：按目标帧率抽帧，保持原始时间戳以维持音画同步
        let videoPump = Task {
            var lastEmitted: CMTime = .invalid
            while let sample = videoOutput.copyNextSampleBuffer() {
                if isCancelled?() == true { break }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if lastEmitted.isValid {
                    let delta = CMTimeSubtract(pts, lastEmitted).seconds
                    if delta < fpsInterval * 0.9 { continue }   // 抽掉过密帧
                }
                lastEmitted = pts
                if videoInput.isReadyForMoreMediaData, videoInput.append(sample) {
                    if duration > 0 {
                        progress?(min(max(CMTimeGetSeconds(pts) / duration, 0), 1))
                    }
                } else {
                    break
                }
            }
            videoInput.markAsFinished()
        }

        // 音频泵
        let audioPump = Task {
            guard let audioInput = audioInput, let audioOutput = audioOutput else { return }
            while let sample = audioOutput.copyNextSampleBuffer() {
                if isCancelled?() == true { break }
                if audioInput.isReadyForMoreMediaData {
                    audioInput.append(sample)
                }
            }
            audioInput.markAsFinished()
        }

        await videoPump.value
        await audioPump.value
        monitor.cancel()

        if isCancelled?() == true {
            try? FileManager.default.removeItem(at: outputURL)
            throw AppError.userCancelled
        }

        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outputURL)
            throw AppError.compressionFailed(writer.error?.localizedDescription ?? "写入失败")
        }
        // 校验产物：必须存在且大小 > 0，避免输出空文件被误认为成功
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        guard outSize > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AppError.outputFileEmpty
        }
    }
}
