import SwiftUI

// MARK: - 轻量视觉组件
//
// 性能优先原则（本次重构）：
// - 移除所有【常驻】实时模糊材质（ultraThinMaterial 等）——双浮层常驻 blur 会造成
//   GPU 持续合成、待机发热。玻璃感改用「实底色 + 低透明度 + 细边框 + 轻阴影」模拟。
// - 阴影只用于浮层，不用于列表内容。
// 若未来确认 GPU 余量充足，可再在浮层局部恢复 Material。

/// 浮层背景：实底色 + 细边框 + 轻阴影（替代常驻 blur，零 GPU 常驻开销）。
struct FloatSurface: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
    }
}

extension View {
    func floatSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(FloatSurface(cornerRadius: cornerRadius))
    }
}

/// 按压反馈按钮样式：按下轻微缩放 + 降不透明度，释放恢复（所有按钮统一使用）。
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 胶囊主按钮（如「+ 选择视频」）：适中尺寸，蓝色仅用于强调。
struct GlassCapsuleButton: View {
    let title: String
    let systemImage: String
    var isProminent: Bool = false   // true = 主操作（蓝色填充）
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .buttonStyle(PressableButtonStyle())
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
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
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
