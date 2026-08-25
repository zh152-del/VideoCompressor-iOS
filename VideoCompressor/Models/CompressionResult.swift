import Foundation

/// 单个视频的压缩结果（输出文件位于临时目录，待用户保存到图库）。
struct CompressionResult: Identifiable {
    let id = UUID()
    let item: VideoItem
    let outputURL: URL
    let outputSizeBytes: Int64
    let outputWidth: Int
    let outputHeight: Int
    let outputCodec: String
    let durationSeconds: Double
    let profile: CompressionProfile
    /// 保存到图库成功后记录的资源标识。
    var savedPhotoLocalIdentifier: String?

    /// 生成本次压缩对应的历史记录条目。
    func historyEntry(savedID: String?) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            name: item.title,
            originalBytes: item.fileSizeBytes,
            compressedBytes: outputSizeBytes,
            savedBytes: item.fileSizeBytes - outputSizeBytes,
            date: Date(),
            mode: profile.modeDisplayName,
            sourceResolution: "\(item.width)×\(item.height)",
            outputResolution: "\(outputWidth)×\(outputHeight)",
            sourceCodec: item.codecDescription,
            outputCodec: outputCodec,
            durationSeconds: durationSeconds,
            savedAssetLocalIdentifier: savedID
        )
    }
}
