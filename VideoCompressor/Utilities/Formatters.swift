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

    /// 节省比例（0..1）的展示，如「约 36.3%」。
    /// 负值（体积变大）不再钳制为 0%——必须如实显示「体积增加 x%」。
    static func savedPercent(_ ratio: Double) -> String {
        if ratio < 0 {
            return String(format: "体积增加 %.1f%%", -ratio * 100)
        }
        return String(format: "约 %.1f%%", ratio * 100)
    }

    /// 依据真实文件大小生成变化描述：
    /// - 有效压缩 → 「节省 252 MB · 58.9%」
    /// - 体积变大 → 「体积增加 99.4%」
    /// - 基本没变（±1%）→ 「未节省空间」
    static func sizeChangeText(original: Int64, compressed: Int64) -> String {
        guard original > 0 else { return "未节省空间" }
        if compressed >= original {
            let inc = Double(compressed - original) / Double(original) * 100
            if inc < 1.0 { return "未节省空间" }
            return String(format: "体积增加 %.1f%%", inc)
        }
        let saved = original - compressed
        let pct = Double(saved) / Double(original) * 100
        if pct < 1.0 { return "未节省空间" }
        return "节省 \(bytes(Int64(saved))) · \(String(format: "%.1f%%", pct))"
    }
}
