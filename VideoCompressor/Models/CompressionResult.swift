import Foundation

/// 单个视频的压缩结果。
/// `noGain == true` 表示未能有效压缩（输出体积 ≥ 原体积或预估无法缩小）：
/// 此时 `outputURL` 为 nil、输出文件已被删除、原视频必须保留。
struct CompressionResult: Identifiable {
    let id = UUID()
    let item: VideoItem
    /// 压缩产物文件（位于临时目录）。noGain 时为 nil。
    let outputURL: URL?
    let outputSizeBytes: Int64
    let outputWidth: Int
    let outputHeight: Int
    let outputCodec: String
    let durationSeconds: Double
    let profile: CompressionProfile
    /// 保存到图库成功后记录的资源标识。
    var savedPhotoLocalIdentifier: String?
    /// 是否「未节省空间」（压缩后体积不小于原体积，或预估无压缩空间）。
    var noGain: Bool = false
    /// 源文件真实大小兜底（相册来源视频扫描阶段可能拿不到大小，导出后获得）。
    var originalBytesOverride: Int64? = nil

    /// 源文件真实大小（优先 override）。
    var effectiveOriginalBytes: Int64 { originalBytesOverride ?? item.fileSizeBytes }

    /// 是否为有效压缩（输出严格小于原始文件）。
    var isEffective: Bool { !noGain && outputSizeBytes < effectiveOriginalBytes }

    /// 实际节省的字节数（可能为负，表示体积增加）。
    var savedBytes: Int64 { effectiveOriginalBytes - outputSizeBytes }

    /// 生成本次压缩对应的历史记录条目。outcome: "saved" / "noGain" / "failed"
    func historyEntry(savedID: String?, outcome: String = "saved") -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            name: item.title,
            originalBytes: item.fileSizeBytes,
            compressedBytes: outputSizeBytes,
            savedBytes: savedBytes,
            date: Date(),
            mode: profile.modeDisplayName,
            sourceResolution: "\(item.width)×\(item.height)",
            outputResolution: "\(outputWidth)×\(outputHeight)",
            sourceCodec: item.codecDescription,
            outputCodec: outputCodec,
            durationSeconds: durationSeconds,
            savedAssetLocalIdentifier: savedID,
            outcome: outcome,
            originalAssetIdentifier: item.localIdentifier   // 原视频 PHAsset 标识，供历史页安全删除
        )
    }
}
