import SwiftUI

@main
struct VideoCompressorApp: App {
    @StateObject private var history = HistoryStore.shared
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var temp = TempFileManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(history)
                .environmentObject(settings)
                .environmentObject(temp)
                .preferredColorScheme(settings.colorScheme)
        }
    }
}
