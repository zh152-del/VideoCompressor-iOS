import Foundation
import SwiftUI
import Combine

/// 用户设置（UserDefaults 持久化）。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var deleteOriginalAfterSave: Bool {
        didSet { UserDefaults.standard.set(deleteOriginalAfterSave, forKey: "vc_deleteOriginalAfterSave") }
    }
    @Published var defaultMode: CompressionMode {
        didSet { UserDefaults.standard.set(defaultMode.rawValue, forKey: "vc_defaultMode") }
    }
    @Published var preferredCodec: VideoCodec {
        didSet { UserDefaults.standard.set(preferredCodec.rawValue, forKey: "vc_preferredCodec") }
    }
    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "vc_appearance") }
    }
    /// 一键压缩时是否自动跳过小视频。
    @Published var skipSmallVideosEnabled: Bool {
        didSet { UserDefaults.standard.set(skipSmallVideosEnabled, forKey: "vc_skipSmallEnabled") }
    }
    /// 小视频阈值（MB）：严格小于该值的视频在一键压缩任务中被跳过。
    @Published var skipSmallVideosThresholdMB: Double {
        didSet { UserDefaults.standard.set(skipSmallVideosThresholdMB, forKey: "vc_skipSmallMB") }
    }
    init() {
        let d = UserDefaults.standard
        self.deleteOriginalAfterSave = d.bool(forKey: "vc_deleteOriginalAfterSave")
        self.defaultMode = CompressionMode(rawValue: d.string(forKey: "vc_defaultMode") ?? "") ?? .balanced
        self.preferredCodec = VideoCodec(rawValue: d.string(forKey: "vc_preferredCodec") ?? "") ?? .hevc
        self.appearance = Appearance(rawValue: d.string(forKey: "vc_appearance") ?? "") ?? .system
        if d.object(forKey: "vc_skipSmallEnabled") != nil {
            self.skipSmallVideosEnabled = d.bool(forKey: "vc_skipSmallEnabled")
        } else {
            self.skipSmallVideosEnabled = false
        }
        self.skipSmallVideosThresholdMB = d.object(forKey: "vc_skipSmallMB") != nil
            ? d.double(forKey: "vc_skipSmallMB") : 50
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// 外观模式。
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
}

