import Foundation
import CoreGraphics

/// 视频几何辅助：处理旋转导致的显示尺寸变化，以及 FourCC 编解码器识别。
enum VideoGeometry {
    /// 根据视频轨道的 preferredTransform 计算实际显示宽高（考虑横竖屏旋转）。
    static func displaySize(after transform: CGAffineTransform, natural size: CGSize) -> CGSize {
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        if abs(angle) == 90 || abs(angle) == 270 {
            return CGSize(width: size.height, height: size.width)
        }
        return size
    }

    /// 将 FourCharCode 转为可读字符串（如 "avc1"）。
    static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = withUnsafeBytes(of: code.bigEndian) { Data($0) }
        return String(data: bytes, encoding: .ascii) ?? "未知"
    }
}
