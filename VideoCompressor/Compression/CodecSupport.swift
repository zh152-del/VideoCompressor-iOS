import Foundation
import AVFoundation
import VideoToolbox

/// 设备编码能力探测。
enum CodecSupport {
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
