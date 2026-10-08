import Foundation
import Combine

/// 组内单个视频的处理快照。
struct GroupItemSnapshot: Codable, Identifiable {
    var id: String { assetID }
    let assetID: String          // PHAsset.localIdentifier
    let filename: String
    let originalBytes: Int64
    var compressedBytes: Int64?  // nil = 未产出（失败/跳过）
    let outcome: String          // saved / failed / skipped
    var removed: Bool            // 已被用户移出本组（非删除！__VC__ 文件名保持不动）
    var savedAssetID: String?    // 压缩成品 PHAsset 标识

    var effectiveOutcome: String { removed ? "removed" : outcome }
}

/// 一个已完成处理组。
struct GroupRecord: Codable, Identifiable {
    var id: Int { index }
    let index: Int               // 第几组（0-based 显示时 +1）
    let totalCount: Int
    var succeeded: Int
    var failed: Int
    var skipped: Int
    var markFailedCount: Int     // __VC__ 验证失败数量
    let date: Date
    var items: [GroupItemSnapshot]

    /// 未被移出的条目。
    var activeItems: [GroupItemSnapshot] { items.filter { !$0.removed } }
}

/// 组状态存储（App 沙盒 JSON；重装丢失组状态是允许的——__VC__ 在相册文件名里，不受影响）。
@MainActor
final class GroupStore: ObservableObject {
    static let shared = GroupStore()

    @Published private(set) var records: [GroupRecord] = []
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent("compression_groups.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([GroupRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded.sorted { $0.index < $1.index }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let tmp = fileURL.deletingLastPathComponent().appendingPathComponent("compression_groups.json.tmp")
        if (try? data.write(to: tmp)) != nil {
            _ = try? FileManager.default.replaceItem(at: fileURL, withItemAt: tmp,
                                                     backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// 记录一个已完成组（覆盖同号旧记录）。
    func recordCompleted(index: Int, totalCount: Int, succeeded: Int, failed: Int,
                         skipped: Int, markFailedCount: Int, items: [GroupItemSnapshot]) {
        let record = GroupRecord(index: index, totalCount: totalCount, succeeded: succeeded,
                                 failed: failed, skipped: skipped, markFailedCount: markFailedCount,
                                 date: Date(), items: items)
        records.removeAll { $0.index == index }
        records.append(record)
        records.sort { $0.index < $1.index }
        save()
        AppLog.history("组记录：第\(index + 1)组 完成（成功\(succeeded) 失败\(failed) 跳过\(skipped) 标记失败\(markFailedCount)）")
    }

    /// 移出：仅修改 App 内部归属状态（removed=true）。
    /// 绝不删除视频、绝不触碰 __VC__ 文件名标记。
    @discardableResult
    func removeItems(groupIndex: Int, assetIDs: Set<String>) -> Int {
        guard let idx = records.firstIndex(where: { $0.index == groupIndex }) else { return 0 }
        var changed = 0
        for i in records[idx].items.indices where assetIDs.contains(records[idx].items[i].assetID) {
            if !records[idx].items[i].removed {
                records[idx].items[i].removed = true
                changed += 1
            }
        }
        if changed > 0 { save() }
        AppLog.history("移出完成组：第\(groupIndex + 1)组移出 \(changed) 个（不删除视频、不清除 __VC__）")
        return changed
    }

    /// 指定组是否已有完成记录。
    func isCompleted(_ index: Int) -> Bool { records.contains { $0.index == index } }
}
