import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("压缩", systemImage: "arrow.down.circle.fill") }
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
