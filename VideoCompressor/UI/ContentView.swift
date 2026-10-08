import SwiftUI

/// 应用根视图：三个页面 + 悬浮玻璃胶囊导航（模拟 Liquid Glass，iOS 18.3 兼容）。
/// 导航悬浮于内容之上，页面滚动时保持悬浮；注意安全区，不遮挡内容。
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
        case .compress: return "arrow.down.circle"
        case .history:  return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var tab: AppTab = .compress

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .compress: HomeView()
                case .history:  HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingTabBar(tab: $tab)
                .padding(.horizontal, 40)
                .padding(.bottom, 6)
        }
    }
}

/// 底部悬浮玻璃导航胶囊。
struct FloatingTabBar: View {
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon)
                            .font(.system(size: 18, weight: .medium))
                        Text(t.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glassPanel(cornerRadius: 24)
    }
}
