import SwiftUI

/// 应用根视图。
///
/// 页面容器策略（第二版定稿）：**只渲染当前 Tab**（switch 条件渲染）。
/// 之所以现在可以安全使用 switch：所有跨页面状态（已选视频 / 压缩模式 / 压缩会话 /
/// 进度页开关）都保存在共享 AppState（App 根部唯一实例），页面本身只承载
/// 瞬态 UI 状态，切换销毁不会丢失任何用户数据，也避免三页常驻带来的
/// 额外 View 更新与布局开销。
///
/// 底部 FloatingTabBar 由 ContentView 独立负责；HomeView 不承担全局导航职责。
enum AppTab: String, CaseIterable {
    case compress, processed, history, settings

    var title: String {
        switch self {
        case .compress:  return "压缩"
        case .processed: return "已压"
        case .history:   return "历史"
        case .settings:  return "设置"
        }
    }

    var icon: String {
        switch self {
        case .compress:  return "arrow.down.circle.fill"
        case .processed: return "checkmark.seal.fill"
        case .history:   return "clock.arrow.circlepath"
        case .settings:  return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var tab: AppTab = .compress

    var body: some View {
        ZStack(alignment: .bottom) {
            // 只渲染当前页面；压缩任务在 AppState.session 中继续，不受页面切换影响
            switch tab {
            case .compress:  HomeView()
            case .processed: ProcessedView()
            case .history:   HistoryView()
            case .settings:  SettingsView()
            }

            FloatingTabBar(tab: $tab)
                .padding(.horizontal, 40)
                .padding(.bottom, 6)
        }
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
                    AppLog.ui("Tab changed → \(t.title)")
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { tab = t }
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
