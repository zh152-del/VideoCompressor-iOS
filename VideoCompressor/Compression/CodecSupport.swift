import Foundation
import AVFoundation
import VideoToolbox

/// 设备编码能力探测。
enum CodecSupport {
    /// 说明：iOS 未向 App 公开"当前设备是否支持某编码格式的硬件编码"的查询 API
    /// （VTIsHardwareEncodeSupported 为 macOS 专用，iOS 不可用），
    /// 因此这里不做任何"硬件一定可用"的断言。实际策略是：
    /// 在压缩属性中声明 EnableHardwareAcceleratedVideoEncoder = true（优先硬件），
    /// 由系统在条件不满足时自动回落软件编码，并通过 [Perf] 日志如实记录请求内容。

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
