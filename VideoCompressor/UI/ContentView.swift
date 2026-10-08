import SwiftUI

/// 应用根视图。
///
/// 状态保持关键设计：三个页面【常驻】ZStack 中，用 opacity + allowsHitTesting 切换，
/// 绝不使用 `switch tab { case ... }` 条件渲染（那会销毁页面、丢失已选视频等状态）。
/// 底部导航为实底浮层（无实时 blur），当前 Tab 有明确的背景胶囊选区。
enum AppTab: String, CaseIterable {
    case compress, history, settings

    var title: String {
        switch self {
        case .compress: return "压缩"
        case .history:  return "历史"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .compress: return "arrow.down.circle.fill"
        case .history:  return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var tab: AppTab = .compress

    var body: some View {
        ZStack(alignment: .bottom) {
            // 页面层：常驻不销毁，仅切换可见性与点击
            ZStack {
                page(HomeView(), tab: .compress)
                page(HistoryView(), tab: .history)
                page(SettingsView(), tab: .settings)
            }

            FloatingTabBar(tab: $tab)
                .padding(.horizontal, 40)
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func page(_ view: some View, tab t: AppTab) -> some View {
        let active = (tab == t)
        view
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

/// 底部导航：实底浮层 + 当前 Tab 背景胶囊选区（不只靠颜色区分）。
struct FloatingTabBar: View {
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { t in
                let selected = (tab == t)
                Button {
                    guard tab != t else { return }
                    AppLog.ui("切换 Tab → \(t.title)")
                    withAnimation(.easeOut(duration: 0.15)) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon)
                            .font(.system(size: 17, weight: .medium))
                        Text(t.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(5)
        .floatSurface(cornerRadius: 24)
    }
}
