import Foundation
import AVFoundation

/// 压缩模式。
enum CompressionMode: String, CaseIterable, Codable, Identifiable {
    case quick
    case balanced
    case high
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick:    return "快速压缩"
        case .balanced: return "平衡压缩"
        case .high:     return "高压缩"
        case .custom:   return "自定义"
        }
    }

    var hint: String {
        switch self {
        case .quick:    return "适合普通用户，速度快、画质好"
        case .balanced: return "在画质与体积之间取得平衡"
        case .high:     return "尽可能降低文件体积"
        case .custom:   return "自定义分辨率、帧率、质量与编码"
        }
    }
}

/// 视频编码格式。
enum VideoCodec: String, CaseIterable, Codable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    /// AVAssetWriter 使用的编码标识符（FourCC 字符串）。
    var avCodecType: String {
        switch self {
        case .h264: return AVVideoCodecType.h264.rawValue
        case .hevc: return AVVideoCodecType.hevc.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC / H.265"
        }
    }
}

/// 自定义压缩参数。
struct CustomSettings: Codable, Equatable {
    var resolution: PresetResolution = .p1080
    var fps: Double = 0            // 0 表示沿用源帧率
    var quality: Double = 0.7      // 0..1，影响码率
    var codec: VideoCodec = .hevc
    var targetSizeMB: Double? = nil  // 可选：目标文件大小（MB）
}

/// 一次压缩的完整配置。
struct CompressionProfile: Identifiable, Equatable {
    var id = UUID()
    var mode: CompressionMode = .balanced
    var custom: CustomSettings = CustomSettings()

    /// 用于历史记录的模式显示名。
    var modeDisplayName: String { mode.displayName }
}
