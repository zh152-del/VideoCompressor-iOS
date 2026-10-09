import Foundation
import Photos

/// 首页扫描排除依据（数据层执行，不只是隐藏 UI）。
enum ProcessedExclusion {
    /// 读取持久化历史中"压缩成功且成品 Asset 仍存在"的原视频 ID。
    /// 任一条件不满足（取消/失败/无Gain/成品已删除）都不排除。
    static func successfullyCompressedIDs(historyFileName: String = "compression_history.json") -> Set<String> {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let url = docs.appendingPathComponent(historyFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        // 不依赖 HistoryEntry 的具体结构：用 JSON 解析出需要的字段，避免循环依赖
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var result = Set<String>()
        for e in arr {
            let outcome = e["outcome"] as? String ?? "saved"
            guard outcome == "saved" else { continue }
            let cid = e["savedAssetLocalIdentifier"] as? String
            let oid = e["originalAssetIdentifier"] as? String
            guard let cid, !cid.isEmpty, let oid, !oid.isEmpty else { continue }
            // 成品必须仍然存在（用户删掉成品后允许重新处理）
            if PHAsset.fetchAssets(withLocalIdentifiers: [cid], options: nil).count > 0 {
                result.insert(oid)
            }
        }
        return result
    }
}

/// 供扫描器读取"超时跳过"名单（避免 PhotoScanner 依赖 CompressionSession）。
enum FingerprintStoreLike {
    private static let key = "vc_timed_out_skips"

    /// 已被判定超时跳过的 PHAsset.localIdentifier 集合。
    static func timedOutSkipIDs() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([SkippedVideo].self, from: data) else {
            return []
        }
        return Set(arr.map(\.assetID))
    }
}
