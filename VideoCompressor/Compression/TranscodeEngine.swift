import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// 引擎状态上报（供上层做超时恢复判断，不猜测）。
enum TranscodeState {
    case encoding        // 正在读取/写入样本
    case finishing       // 样本写完，正在 finishWriting（写盘收尾）
    case finished        // 编码与写入均正常结束（输出有效，尚未验证）
    case failed(String)  // 明确失败
    case cancelled       // 已取消，临时输出已清理
}

/// 跨线程安全取消信号：超时恢复与用户取消都通过它请求"安全终止"。
final class TranscodeCancelSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested
    }
    /// 幂等：重复请求安全终止不会产生副作用。
    func requestCancel() {
        lock.lock(); requested = true; lock.unlock()
    }
}

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
                          isCancelled: (() -> Bool)? = nil,
                          onState: ((TranscodeState) -> Void)? = nil) async throws {
        onState?(.encoding)
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

        // MARK: - 目标尺寸（保比例、绝不放大、奇数向上取偶）
        //
        // 【关键概念】编码尺寸必须匹配【像素数据排列】(naturalSize)，而不是显示尺寸：
        // 竖屏 iPhone 视频 naturalSize=1920×1080（像素横向），preferredTransform=90° → 显示 1080×1920。
        // 正确流程：按【显示尺寸】算出目标显示宽高（保持比例），若 transform 为 90°/270°（宽高互换），
        // 则编码宽高 = 目标显示宽高【互换】回像素排列；再用 videoInput.transform 让播放器旋转显示。
        // 此前直接用显示尺寸做 AVVideoWidth/Height → 编码器把横向像素流按竖向尺寸编码 → 画面压扁。

        let naturalW = max(1, Int(naturalSize.width))
        let naturalH = max(1, Int(naturalSize.height))
        let srcH = max(1, Int(display.height))
        let srcW = max(1, Int(display.width))
        guard srcH > 0, srcW > 0, display.width.isFinite, display.height.isFinite,
              naturalW > 0, naturalH > 0, naturalSize.width.isFinite, naturalSize.height.isFinite else {
            AppLog.compress("[ERROR] 视频尺寸无效：display=\(display) natural=\(naturalSize)")
            throw AppError.videoReadFailed
        }
        // 显示方向是否与像素排列互换（90°/270° 旋转）
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        let isRotated = abs(abs(angle) - 90) < 0.5

        // 目标【显示】高度（按模式上限，不放大）
        let targetDisplayH = options.maxHeight.map { min($0, srcH) } ?? srcH
        let targetDisplayW = max(2, Int((Double(srcW) * Double(targetDisplayH) / Double(srcH)).rounded()))

        // 编码尺寸 = 像素排列方向；rotated 时与显示宽高互换
        let encW = isRotated ? targetDisplayH : targetDisplayW
        let encH = isRotated ? targetDisplayW : targetDisplayH
        let outW = Self.makeEven(max(2, encW))
        let outH = Self.makeEven(max(2, encH))
        AppLog.compress("尺寸：natural=\(naturalW)×\(naturalH)，display=\(srcW)×\(srcH)，rotated=\(isRotated)，编码=\(outW)×\(outH)")

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
            // 【卡死修复】音画时长严重不匹配的视频，音轨数据会让写入器在 finishWriting 阶段
            // 长时间阻塞（日志实证：任务卡在"等待写入器完成"）。这类视频直接跳过音轨，只压画面。
            let audioDuration = (try? await audioTrack.load(.timeRange))?.duration.seconds ?? 0
            let durationMismatch = audioDuration > 0 && duration > 0
                && (audioDuration > duration * 1.5 || audioDuration < duration * 0.2)
            if durationMismatch {
                AppLog.compress("[警告] 音画时长不匹配（音频 \(String(format: "%.2f", audioDuration))s / 视频 \(String(format: "%.2f", duration))s），跳过音轨以避免写入器结束阶段卡死")
                AppLog.failure("音频", "音频轨道", "音画时长不匹配，已跳过音轨（画面照常压缩）")
            } else {
                let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
                if reader.canAdd(ao) {
                    // 【兼容】使用源音频真实采样率/声道（AAC 编码器要求合法值），避免硬编码 44100/2 导致编码器异常
                    var srcRate = 44100.0
                    var srcChannels = 2
                    if let fd = try? await audioTrack.load(.formatDescriptions).first,
                       let descPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                        let desc = descPtr.pointee
                        if desc.mSampleRate > 0 { srcRate = desc.mSampleRate }
                        if desc.mChannelsPerFrame > 0 { srcChannels = Int(desc.mChannelsPerFrame) }
                    }
                    let legal: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
                    let targetRate = legal.min(by: { abs($0 - srcRate) < abs($1 - srcRate) }) ?? 44100
                    let targetChannels = min(max(srcChannels, 1), 2)
                    let audioSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: targetRate,
                        AVNumberOfChannelsKey: targetChannels,
                        AVEncoderBitRateKey: 128000
                    ]
                    let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    ai.expectsMediaDataInRealTime = false
                    if writer.canAdd(ai) {
                        writer.add(ai)
                        audioInput = ai
                        reader.add(ao)
                        audioOutput = ao
                        AppLog.compress("音频链路：PCM 解压 → AAC 编码（\(Int(targetRate))Hz / \(targetChannels)ch，源 \(Int(srcRate))Hz / \(srcChannels)ch）")
                    } else {
                        AppLog.compress("[警告] writer 拒绝音频输入，仅压缩画面")
                    }
                } else {
                    AppLog.compress("[警告] reader 拒绝音频输出，仅压缩画面")
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
        /// 等待写入器可接收下一个样本。
        /// 【移除超时机制】原先存在"等待超过 30 秒即中止"的基于时间的终止逻辑，已删除：
        /// 现在只在用户主动取消（isCancelled）时中断，否则一直等待写入器就绪，
        /// 避免把"耗时较长的正常编码"误判为异常而中断。
        func waitForInput(_ input: AVAssetWriterInput) async -> Bool {
            var waitedSeconds = 0
            while !input.isReadyForMoreMediaData {
                if isCancelled?() == true { return false }
                try? await Task.sleep(nanoseconds: 10_000_000)
                waitedSeconds += 1
                if waitedSeconds % 60 == 0 {   // 仅诊断日志，不是终止条件
                    AppLog.compress("[等待] 写入器已等待 \(waitedSeconds) 秒，仍在编码中…")
                }
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

        // 【稳定性-卡死/取消闪退根因】原为 Task {}：从 @MainActor 调用链继承 MainActor，
        // 逐帧解码/append + 每帧一次主线程进度回调把主线程打满 → UI 看似卡死、
        // 取消时大量回调与 UI 重建竞争出现 EXC_BAD_ACCESS。改为后台执行器（不继承 actor）。
        let videoPump = Task.detached {
            var lastEmitted: CMTime = .invalid
            var emitted = 0
            var lastReportedFrac: Double = 0
            var lastReportUptime: UInt64 = DispatchTime.now().uptimeNanoseconds
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
                    // 【稳定性】进度节流：原为逐帧回调（60s 视频约 1800 次主线程任务），
                    // 改为最多每 100ms / 每 1% 上报一次，避免主线程任务风暴。
                    let frac = duration > 0 ? min(max(CMTimeGetSeconds(pts) / duration, 0), 1) : 0
                    let nowUptime = DispatchTime.now().uptimeNanoseconds
                    if frac - lastReportedFrac >= 0.01 || nowUptime - lastReportUptime >= 100_000_000 {
                        lastReportedFrac = frac
                        lastReportUptime = nowUptime
                        progress?(frac)
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

        let audioPump = Task.detached {
            // 【卡死修复】即使没有音频输出，也必须让 writer 的音频输入进入"结束"状态，
            // 否则 finishWriting 会永远等待音频输入而卡住（此前的真实卡死原因之一）。
            guard let audioInput = audioInput else { return }
            defer { audioInput.markAsFinished() }
            guard let audioOutput = audioOutput else {
                AppLog.compress("[警告] 无音频输出，音频输入直接标记结束")
                return
            }
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
            AppLog.compress("音频泵结束：已写入 \(appended) 帧")
        }

        await videoPump.value
        await audioPump.value

        // 【稳定性】编码阶段结束、开始写盘收尾：给 UI 一个明确的阶段信号，
        // 避免"进度 100% 但长时间不动"的卡死观感。
        onState?(.finishing)
        progress?(-1)

        // MARK: - 收尾（严格顺序：markAsFinished 已由泵执行 → finishWriting → 校验状态）

        // 收尾前诊断：把写入器/输入状态落盘，便于定位"卡在结束阶段"的真实原因
        AppLog.stage("写入", "开始结束写入：writer.status=\(writer.status.rawValue)，video ready=\(videoInput.isReadyForMoreMediaData)，audio ready=\(audioInput.map { $0.isReadyForMoreMediaData } ?? true)（writer.status=\(writer.status.rawValue)）")
        if isCancelled?() == true && writer.status == .writing {
            AppLog.stage("取消", "用户取消：取消写入器（不删除原视频）")
            writer.cancelWriting()
        }
        await writer.finishWriting()
        AppLog.stage("写入", "写入器已结束：status=\(writer.status.rawValue)，error=\(writer.error?.localizedDescription ?? "无")")

        if isCancelled?() == true {
            // 取消收尾：只删除本次任务的临时输出，绝不触碰原视频或已保存成品
            try? FileManager.default.removeItem(at: outputURL)
            AppLog.compress("[Cancel] 编码已取消：临时输出已清理（\(outputURL.lastPathComponent)）")
            onState?(.cancelled)
            throw AppError.userCancelled
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            let detail = encodingError.map { ($0 as? AppError)?.errorDescription } ?? writer.error?.localizedDescription
            AppLog.compress("[ERROR] 编码失败（writer.status=\(writer.status.rawValue)）：\(detail ?? "未知")")
            onState?(.failed(detail ?? "写入失败"))
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
        guard let outTrack = (try? await outAsset.loadTracks(withMediaType: .video))?.first else {
            try? FileManager.default.removeItem(at: outputURL)
            AppLog.compress("[ERROR] 输出文件无法读取视频轨道（损坏）")
            throw AppError.outputFileEmpty
        }

        // 【比例验证】输出显示比例必须与源显示比例一致（浮点误差 <2%），否则判定失败、不保存
        do {
            let outNatural = try await outTrack.load(.naturalSize)
            let outTransform = try await outTrack.load(.preferredTransform)
            let outDisplay = VideoGeometry.displaySize(after: outTransform, natural: outNatural)
            let inRatio = Double(srcW) / Double(srcH)
            let outRatio = outDisplay.width / max(1, outDisplay.height)
            let deviation = abs(outRatio - inRatio) / inRatio
            AppLog.compress("比例验证：输入=\(srcW)×\(srcH)(\(String(format: "%.3f", inRatio)))，输出=\(Int(outDisplay.width))×\(Int(outDisplay.height))(\(String(format: "%.3f", outRatio)))，偏差=\(String(format: "%.2f%%", deviation * 100))")
            if deviation > 0.02 {
                try? FileManager.default.removeItem(at: outputURL)
                AppLog.compress("[ERROR] 输出比例严重偏差，判定失败")
                throw AppError.compressionFailed("输出画面比例与原始视频不一致，已放弃保存")
            }
        } catch let e as AppError {
            throw e
        } catch {
            // 比例读取失败不阻断（个别容器元数据缺失），仅记录
            AppLog.compress("输出比例读取失败（不阻断）：\(error.localizedDescription)")
        }
        onState?(.finished)
        AppLog.compress("Encoding complete：输出 \(Formatters.bytes(outSize))")
    }

    /// 将尺寸向上取整为偶数，满足 H.264/HEVC 编码器对宽高的对齐要求。
    private static func makeEven(_ v: Int) -> Int {
        return v % 2 == 0 ? v : v + 1
    }
}
