import SwiftUI

@main
struct VideoCompressorApp: App {
    @StateObject private var history = HistoryStore.shared
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var temp = TempFileManager.shared
    // AppState 是共享单例（静态持有），App 根部只做观察，不声明所有权
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(history)
                .environmentObject(settings)
                .environmentObject(temp)
                .environmentObject(appState)
                .preferredColorScheme(settings.colorScheme)
        }
    }
}
