import Foundation

/// 压缩历史记录（仅保存本地元数据，不上传）。
struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let originalBytes: Int64
    let compressedBytes: Int64
    let savedBytes: Int64
    let date: Date
    let mode: String
    let sourceResolution: String
    let outputResolution: String
    let sourceCodec: String
    let outputCodec: String
    let durationSeconds: Double
    let savedAssetLocalIdentifier: String?

    var compressionRatio: Double {
        guard originalBytes > 0 else { return 0 }
        return 1.0 - Double(compressedBytes) / Double(originalBytes)
    }
}
