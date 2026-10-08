import Foundation

/// 批量压缩中单个任务的状态。
/// 阶段粒度：pending → compressing → saving → success/noGain/failure/cancelled。
enum TaskStatus {
    case pending
    case compressing(progress: Double)
    /// 编码完成，正在保存到照片图库（用户可见的中间阶段，防止"卡死"错觉）。
    case saving
    case success(CompressionResult)
    /// 未节省空间：压缩后体积不小于原体积，输出已删除、原视频保留。
    case noGain(CompressionResult)
    case failure(AppError)
    case cancelled

    var isCompressing: Bool {
        if case .compressing = self { return true }
        return false
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    /// 是否为终态（不再变化）。
    var isFinished: Bool {
        switch self {
        case .success, .noGain, .failure, .cancelled: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .pending:           return "等待中"
        case .compressing:       return "压缩中"
        case .saving:            return "保存到照片…"
        case .success:           return "已完成"
        case .noGain:            return "未节省空间"
        case .failure:           return "失败"
        case .cancelled:         return "已取消"
        }
    }

    /// 关联的结果（终态且存在结果时）。
    var result: CompressionResult? {
        switch self {
        case .success(let r), .noGain(let r): return r
        default: return nil
        }
    }
}

/// 批量压缩任务模型（用于进度界面展示）。
struct CompressionTaskModel: Identifiable {
    let id = UUID()
    let item: VideoItem
    let profile: CompressionProfile
    var status: TaskStatus = .pending

    var progressValue: Double {
        if case .compressing(let p) = status { return p }
        return 0
    }
}
