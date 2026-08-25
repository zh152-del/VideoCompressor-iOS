import Foundation

/// 用户选择的一个视频。
/// `localIdentifier` 为照片图库资源标识，删除原片时需要它（仅当视频来自图库时存在）。
struct VideoItem: Identifiable, Equatable {
    let id = UUID()
    let localIdentifier: String?
    let sourceURL: URL
    let title: String
    let durationSeconds: Double
    let fileSizeBytes: Int64
    let width: Int
    let height: Int
    let fps: Double
    let codecDescription: String
    let thumbnailURL: URL?
    let creationDate: Date?
}
