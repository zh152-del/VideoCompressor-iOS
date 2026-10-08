import SwiftUI

// MARK: - Liquid Glass 视觉组件（iOS 18.3 兼容实现）
//
// 本项目最低支持 iOS 18.3，不能使用 iOS 26 的原生 Liquid Glass API。
// 这里用系统既有能力模拟 Liquid Glass 的核心视觉特征：
//   - translucency：ultraThinMaterial / 低透明度
//   - blur：系统材质自带背景模糊
//   - specular highlight：顶部亮、底部暗的细描边渐变
//   - depth / floating：极轻的阴影
// 原则：玻璃只用于浮动控件（底部导航、操作区、按钮、任务状态），
// 内容本身保持干净，不做「到处玻璃卡片」的网页式设计。
// 若未来最低版本提升到 iOS 26，可在这些入口统一替换为系统 API。

/// 悬浮玻璃面板修饰：低透明度 + 高模糊 + 极轻边缘高光 + 极轻阴影。
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

extension View {
    /// 应用 Liquid Glass 风格面板（iOS 18.3 兼容模拟）。
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

/// 玻璃胶囊主按钮（如「+ 选择视频」）：轻微透明、背景模糊、细微高光、蓝色仅用于强调。
struct GlassCapsuleButton: View {
    let title: String
    let systemImage: String
    var isProminent: Bool = false   // true = 主操作（蓝色填充），false = 玻璃材质
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .modifier(CapsuleStyle(isProminent: isProminent))
    }
}

private struct CapsuleStyle: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content
                .foregroundStyle(.white)
                .background(Capsule().fill(Color.accentColor))
                .shadow(color: Color.accentColor.opacity(0.25), radius: 8, y: 2)
        } else {
            content
                .foregroundStyle(Color.accentColor)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

// MARK: - 日期分组辅助（历史页）

enum DateGrouper {
    /// 将日期归组为「今天 / 昨天 / 10月7日 / 2025年12月31日」。
    static func label(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "今天" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "昨天" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            df.setLocalizedDateFormatFromTemplate("Md")
        } else {
            df.setLocalizedDateFormatFromTemplate("yMd")
        }
        return df.string(from: date)
    }

    /// 分组排序键（同一天归为一组）。
    static func dayKey(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}
