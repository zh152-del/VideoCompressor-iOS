import Foundation

/// 用户选择的一个视频。
/// `localIdentifier` 为照片图库资源标识（删除原片/封面/绑定都需要它，仅当视频来自图库时存在）。
/// `phAssetID` 非空时：sourceURL 为占位，压缩开始前才从图库流式导出本地文件（避免预导出占用大量磁盘）。
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
    /// 来自相册扫描的 PHAsset 标识；非 nil 时按需懒导出。
    let phAssetID: String?

    init(localIdentifier: String?, sourceURL: URL, title: String, durationSeconds: Double,
         fileSizeBytes: Int64, width: Int, height: Int, fps: Double, codecDescription: String,
         thumbnailURL: URL?, creationDate: Date?, phAssetID: String? = nil) {
        self.localIdentifier = localIdentifier
        self.sourceURL = sourceURL
        self.title = title
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
        self.width = width
        self.height = height
        self.fps = fps
        self.codecDescription = codecDescription
        self.thumbnailURL = thumbnailURL
        self.creationDate = creationDate
        self.phAssetID = phAssetID
    }

    /// 是否需要在压缩前从图库导出本地文件。
    var needsLibraryExport: Bool {
        guard phAssetID != nil else { return false }
        return !FileManager.default.fileExists(atPath: sourceURL.path)
    }
}
