import Foundation
import Photos

/// 首页扫描排除依据（数据层执行，不只是隐藏 UI）。
/// 说明：曾用于"超时跳过"的独立名单（SkippedVideo / timedOutSkips / saveTimedOutSkips）
/// 已按要求彻底删除——预判跳过的视频只写入压缩历史，可在历史/已压中查看原因，不再有永久排除名单。
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
