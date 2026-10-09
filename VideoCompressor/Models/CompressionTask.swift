import Foundation

/// 批量压缩中单个任务的状态。
/// 阶段粒度：pending → compressing → saving → success/noGain/failure/cancelled。
enum TaskStatus {
    case pending
    case compressing(progress: Double)
    /// 编码帧已写完，正在结束编码与写入文件（progress 到达 100% 之后的真实阶段）。
    case finalizing
    /// 正在验证输出文件（存在性、大小、可读取、比例）。
    case validating
    /// 编码完成，正在保存到照片图库（用户可见的中间阶段，防止"卡死"错觉）。
    case saving
    case success(CompressionResult)
    /// 未节省空间：压缩后体积不小于原体积，输出已删除、原视频保留。
    case noGain(CompressionResult)
    /// 按规则跳过（如小于设置阈值）：不启动编码器、不产出、不删原视频。
    case skipped
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

    /// 编码结束后的收尾阶段（写盘 / 验证 / 保存）。
    var isFinalizing: Bool {
        switch self {
        case .finalizing, .validating, .saving: return true
        default: return false
        }
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    /// 是否为终态（不再变化）。
    var isFinished: Bool {
        switch self {
        case .success, .noGain, .failure, .cancelled, .skipped: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .pending:           return "等待中"
        case .compressing:       return "压缩中"
        case .finalizing:        return "正在完成编码与写入…"
        case .validating:        return "正在验证输出…"
        case .saving:            return "保存到照片…"
        case .success:           return "已完成"
        case .noGain:            return "未节省空间"
        case .skipped:           return "已跳过"
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
