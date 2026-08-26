import Foundation

/// 应用内统一错误类型。所有描述均为用户可理解的中文说明，并附带处理建议。
/// 设计原则：任何错误都只能「返回错误 → UI 显示 → 用户关闭」，绝不 fatalError / force unwrap / try!。
enum AppError: Error {
    case photoPermissionDenied
    case photoPermissionRestricted
    case videoReadFailed
    case videoCorrupted
    case noVideoTrack
    case unsupportedOutputFormat(String)
    case outputFileMissing
    case outputFileEmpty
    case insufficientStorage(needed: Int64, free: Int64)
    case compressionFailed(String)
    case exportFailed
    case saveToPhotoFailed(String)
    case deleteOriginalFailed(String)
    case userCancelled
    case unknown(String)

    var errorDescription: String {
        switch self {
        case .photoPermissionDenied:      return "无法访问照片图库"
        case .photoPermissionRestricted:  return "照片访问受限"
        case .videoReadFailed:            return "视频读取失败"
        case .videoCorrupted:             return "视频文件可能已损坏"
        case .noVideoTrack:               return "视频文件中没有可压缩的视频轨道"
        case .unsupportedOutputFormat(let f): return "不支持的输出格式：\(f)"
        case .outputFileMissing:          return "压缩结果文件缺失"
        case .outputFileEmpty:            return "压缩结果文件为空"
        case .insufficientStorage:         return "设备存储空间不足"
        case .compressionFailed:          return "视频压缩失败"
        case .exportFailed:               return "无法初始化视频导出"
        case .saveToPhotoFailed:          return "保存到照片图库失败"
        case .deleteOriginalFailed:       return "删除原视频失败"
        case .userCancelled:              return "已取消操作"
        case .unknown:                    return "发生未知错误"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .photoPermissionDenied:
            return "请在系统「设置 › 照片」中允许本应用访问（若需删除原视频，请选择「全部照片」或开启「完全访问」），然后重试。"
        case .photoPermissionRestricted:
            return "系统限制了本应用对照片的访问（如家长控制或设备管理策略）。无法继续，请解除限制后重试。"
        case .videoReadFailed:
            return "请确认视频文件未被占用或删除，然后重新选择。"
        case .videoCorrupted:
            return "请重新从图库导出该视频，或选择其他文件。"
        case .noVideoTrack:
            return "请选择一个包含视频内容的文件。"
        case .unsupportedOutputFormat(let f):
            return "系统不支持输出格式「\(f)」。请使用 MP4/MOV 等系统支持的容器。"
        case .outputFileMissing:
            return "压缩已完成，但结果文件未能生成或已被移除。请重试压缩。"
        case .outputFileEmpty:
            return "压缩结果文件大小为 0，可能写入中断。请重试压缩。"
        case .insufficientStorage(let needed, let free):
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
            return "压缩视频已保存，但删除原视频失败：\(detail)。原视频仍保留在图库中，你可稍后在「照片」中手动删除，或在「设置 › 照片」开启完全访问后重试。"
        case .userCancelled:
            return "你可以重新选择视频进行压缩。"
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
