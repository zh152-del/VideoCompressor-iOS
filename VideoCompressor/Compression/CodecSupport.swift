import Foundation
import AVFoundation
import VideoToolbox

/// 设备编码能力探测。
enum CodecSupport {
    /// 设备是否支持该编码格式的硬件编码（VideoToolbox 能力探测）。
    /// 注意：这反映"设备/系统具备硬件编码能力"，不保证每个 AVAssetWriter 会话都走硬件路径
    /// （分辨率/码率过低时系统可能自动选择软件编码）。
    static func hardwareEncodeSupported(_ codec: VideoCodec) -> Bool {
        let type: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        return VTIsHardwareEncodeSupported(type)
    }

    /// HEVC 编码是否可用（部分老设备不支持）。通过创建一次 HEVC 压缩会话轻量探测。
    static func isHEVCEncodingSupported() -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 1280,
            height: 720,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let s = session { VTCompressionSessionInvalidate(s) }
        return status == noErr
    }
}
