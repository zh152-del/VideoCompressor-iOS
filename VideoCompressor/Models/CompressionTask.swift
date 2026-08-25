import Foundation

/// 批量压缩中单个任务的状态。
enum TaskStatus {
    case pending
    case compressing(progress: Double)
    case success(CompressionResult)
    case failure(AppError)
    case cancelled

    var isCompressing: Bool {
        if case .compressing = self { return true }
        return false
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .pending:           return "等待中"
        case .compressing:       return "压缩中"
        case .success:           return "已完成"
        case .failure:           return "失败"
        case .cancelled:         return "已取消"
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
