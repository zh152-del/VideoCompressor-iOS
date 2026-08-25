import Foundation

/// 通用格式化工具（字节、时长、百分比）。
enum Formatters {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 KB" }
        return byteFormatter.string(fromByteCount: value)
    }

    /// 将秒数格式化为 mm:ss 或 hh:mm:ss。
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 1) * 100
        return String(format: "%.0f%%", clamped)
    }

    /// 节省比例（0..1）的中文展示，如 69.6%。
    static func savedPercent(_ ratio: Double) -> String {
        let clamped = min(max(ratio, 0), 1) * 100
        return String(format: "约 %.1f%%", clamped)
    }
}
