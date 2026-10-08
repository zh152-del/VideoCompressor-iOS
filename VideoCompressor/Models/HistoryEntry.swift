import Foundation

/// 压缩历史记录（仅保存本地元数据，不上传）。
/// outcome 记录真实结果：saved=有效压缩已保存 / noGain=未节省空间 / failed=失败。
/// 旧版本 JSON 无该字段时默认按 saved 解码（历史上只记录过压缩完成的条目）。
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
    var outcome: String

    init(id: UUID, name: String, originalBytes: Int64, compressedBytes: Int64, savedBytes: Int64,
         date: Date, mode: String, sourceResolution: String, outputResolution: String,
         sourceCodec: String, outputCodec: String, durationSeconds: Double,
         savedAssetLocalIdentifier: String?, outcome: String = "saved") {
        self.id = id
        self.name = name
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
        self.savedBytes = savedBytes
        self.date = date
        self.mode = mode
        self.sourceResolution = sourceResolution
        self.outputResolution = outputResolution
        self.sourceCodec = sourceCodec
        self.outputCodec = outputCodec
        self.durationSeconds = durationSeconds
        self.savedAssetLocalIdentifier = savedAssetLocalIdentifier
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey {
        case id, name, originalBytes, compressedBytes, savedBytes, date, mode
        case sourceResolution, outputResolution, sourceCodec, outputCodec
        case durationSeconds, savedAssetLocalIdentifier, outcome
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        originalBytes = try c.decode(Int64.self, forKey: .originalBytes)
        compressedBytes = try c.decode(Int64.self, forKey: .compressedBytes)
        savedBytes = try c.decode(Int64.self, forKey: .savedBytes)
        date = try c.decode(Date.self, forKey: .date)
        mode = try c.decode(String.self, forKey: .mode)
        sourceResolution = try c.decode(String.self, forKey: .sourceResolution)
        outputResolution = try c.decode(String.self, forKey: .outputResolution)
        sourceCodec = try c.decode(String.self, forKey: .sourceCodec)
        outputCodec = try c.decode(String.self, forKey: .outputCodec)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        savedAssetLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .savedAssetLocalIdentifier)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? "saved"
    }

    var compressionRatio: Double {
        guard originalBytes > 0 else { return 0 }
        return 1.0 - Double(compressedBytes) / Double(originalBytes)
    }

    /// 是否有效压缩（真实文件大小比较）。
    var isEffective: Bool { outcome == "saved" && compressedBytes < originalBytes }
}
