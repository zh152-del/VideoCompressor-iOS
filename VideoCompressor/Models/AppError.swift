import Foundation

/// 应用内统一错误类型。所有描述均为用户可理解的中文说明，并附带处理建议。
enum AppError: Error {
    case photoPermissionDenied
    case videoReadFailed
    case noVideoTrack
    case formatNotSupported(String)
    case diskSpaceInsufficient(needed: Int64, free: Int64)
    case compressionFailed(String)
    case exportFailed
    case saveToPhotoFailed(String)
    case deleteOriginalFailed(String)
    case userCancelled
    case appResigned
    case videoTooLarge(Int64)
    case videoCorrupted
    case unknown(String)

    var errorDescription: String {
        switch self {
        case .photoPermissionDenied:      return "无法访问照片图库"
        case .videoReadFailed:            return "视频读取失败"
        case .noVideoTrack:               return "视频文件中没有可压缩的视频轨道"
        case .formatNotSupported(let f):  return "不支持的视频格式：\(f)"
        case .diskSpaceInsufficient:      return "设备存储空间不足"
        case .compressionFailed:          return "视频压缩失败"
        case .exportFailed:               return "无法初始化视频导出"
        case .saveToPhotoFailed:          return "保存到照片图库失败"
        case .deleteOriginalFailed:       return "删除原视频失败"
        case .userCancelled:              return "已取消操作"
        case .appResigned:                return "应用回到前台"
        case .videoTooLarge:              return "视频文件过大"
        case .videoCorrupted:             return "视频文件可能已损坏"
        case .unknown:                   return "发生未知错误"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .photoPermissionDenied:
            return "请在系统「设置 › 照片」中允许本应用访问，然后重试。"
        case .videoReadFailed:
            return "请确认视频文件未被占用或删除，然后重新选择。"
        case .noVideoTrack:
            return "请选择一个包含视频内容的文件。"
        case .formatNotSupported:
            return "请选择 iPhone 支持的视频（如 MP4、MOV、H.264、HEVC）。"
        case .diskSpaceInsufficient(let needed, let free):
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            return "需要约 \(fmt.string(fromByteCount: needed))，但仅剩余 \(fmt.string(fromByteCount: free))。请清理空间后重试。"
        case .compressionFailed(let detail):
            return "压缩过程中出错：\(detail)。可点击重试。"
        case .exportFailed:
            return "无法初始化视频导出，请重试或换用其他压缩模式。"
        case .saveToPhotoFailed(let detail):
            return "无法写入照片图库：\(detail)。原视频已保留，可稍后重试保存。"
        case .deleteOriginalFailed(let detail):
            return "压缩视频已保存，但删除原视频失败：\(detail)。原视频仍保留在图库中。"
        case .userCancelled:
            return "你可以重新选择视频进行压缩。"
        case .appResigned:
            return "任务已安全恢复，无需操作。"
        case .videoTooLarge:
            return "请尝试「高压缩」或「自定义」模式降低文件大小。"
        case .videoCorrupted:
            return "请重新从图库导出该视频，或选择其他文件。"
        case .unknown(let detail):
            return "错误详情：\(detail)。请重试或联系支持。"
        }
    }

    /// 是否为用户主动取消（UI 以中性提示呈现，而非报错）。
    var isCancellation: Bool {
        if case .userCancelled = self { return true }
        return false
    }
}
