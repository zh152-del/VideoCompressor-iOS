import Foundation

/// 目标分辨率预设。`.original` 表示保持源分辨率，引擎绝不放大视频。
enum PresetResolution: String, CaseIterable, Codable, Identifiable {
    case original
    case p4k
    case p1080
    case p720
    case p480

    var id: String { rawValue }

    /// 简体中文显示名
    var displayName: String {
        switch self {
        case .original: return "原始分辨率"
        case .p4k:      return "4K"
        case .p1080:    return "1080p"
        case .p720:     return "720p"
        case .p480:     return "480p"
        }
    }

    /// 目标高度（像素）。`.original` 返回 nil 表示沿用源尺寸。
    var targetHeight: Int? {
        switch self {
        case .original: return nil
        case .p4k:      return 2160
        case .p1080:    return 1080
        case .p720:     return 720
        case .p480:     return 480
        }
    }
}
