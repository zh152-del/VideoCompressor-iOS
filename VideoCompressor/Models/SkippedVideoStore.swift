import Foundation

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
