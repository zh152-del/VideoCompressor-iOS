import Foundation
import Combine
import Photos

/// 压缩历史（本地 JSON 存储，不上传、无云端）。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent("compression_history.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.date > $1.date }
    }

    /// 新增一条记录。
    /// 注意：必须「重新赋值 entries」而非原地 insert —— `@Published` 仅在属性被赋新值时才发布变更，
    /// 原地 `entries.insert(...)` 不会触发 SwiftUI 刷新，导致同一会话内历史列表不更新（只有重开 App 才看到）。
    func add(_ entry: HistoryEntry) {
        entries = [entry] + entries
        save()
    }

    func remove(_ id: UUID) {
        entries = entries.filter { $0.id != id }
        save()
    }

    // MARK: - 原视频删除管理（只删 originalAssetIdentifier，绝不碰压缩成品）

    /// 具备删除资格的记录：压缩成功 + 已保存 Photos + 有可靠原视频标识 + 未删除。
    var deletableEntries: [HistoryEntry] {
        entries.filter { $0.canDeleteOriginal }
    }

    /// 进入历史页时同步 Photos 真实状态：
    /// 只检查记录中引用的 Asset ID（不扫全库）。已在系统照片 App 被删除的 → 标记 deleted。
    func syncOriginalsWithPhotos() {
        let ids = entries.filter { $0.originalDeleteStatus == "notDeleted" }
            .compactMap { $0.originalAssetIdentifier }
        guard !ids.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let found = Set((0..<fetch.count).compactMap { fetch.object(at: $0).localIdentifier })
        var changed = false
        let updated = entries.map { entry in
            guard let oid = entry.originalAssetIdentifier,
                  entry.originalDeleteStatus == "notDeleted",
                  !found.contains(oid) else { return entry }
            changed = true
            var e = entry
            e.originalDeleteStatus = "deleted"
            return e
        }
        if changed {
            entries = updated
            save()
            AppLog.history("同步 Photos：\(updated.filter { $0.originalDeleteStatus == "deleted" }.count) 条原视频已在外部删除")
        }
    }

    /// 删除指定记录的原视频（单条）。只处理 canDeleteOriginal 的记录。
    func deleteOriginal(entryID: UUID) async {
        guard let entry = entries.first(where: { $0.id == entryID }), entry.canDeleteOriginal,
              let oid = entry.originalAssetIdentifier else { return }
        let result = await PhotoLibraryService.shared.deleteOriginals(localIdentifiers: [oid])
        markDeleted(originalIDs: result.deleted)
    }

    /// 一键删除全部符合条件的原视频（一次 performChanges，系统只弹一次确认）。
    /// - Returns: 实际删除的数量。
    @discardableResult
    /// 删除压缩成品（Photos 中已保存的输出视频）。
    /// 只按 compressedAssetID 精确定位，绝不触碰原视频；历史记录保留（标记成品已删除）。
    func deleteCompressed(entryID: UUID) async throws {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        guard let cid = entry.savedAssetLocalIdentifier, !cid.isEmpty else {
            throw AppError.deleteOriginalFailed("该记录没有压缩成品标识")
        }
        AppLog.delete("Delete compressed started：\(entry.name)")
        let result = await PhotoLibraryService.shared.deleteOriginals(localIdentifiers: [cid])
        guard !result.deleted.isEmpty else {
            throw AppError.deleteOriginalFailed("删除压缩成品未获确认，成品已保留")
        }
        if let idx = entries.firstIndex(where: { $0.id == entryID }) {
            entries[idx].savedAssetLocalIdentifier = nil
            entries[idx].compressedFilename = nil
        }
        save()
        AppLog.delete("Delete compressed succeeded：\(entry.name)")
    }

    /// 压缩成品是否仍存在于 Photos（结果页如实显示，不伪造预览）。
    func compressedAssetExists(_ entry: HistoryEntry) -> Bool {
        guard let cid = entry.savedAssetLocalIdentifier, !cid.isEmpty else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [cid], options: nil).count > 0
    }

    /// 原视频是否仍存在于 Photos。
    func originalAssetExists(_ entry: HistoryEntry) -> Bool {
        guard let oid = entry.originalAssetIdentifier, !oid.isEmpty else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [oid], options: nil).count > 0
    }

    func deleteAllOriginalVideos() async -> Int {
        let ids = deletableEntries.compactMap { $0.originalAssetIdentifier }
        guard !ids.isEmpty else { return 0 }
        AppLog.history("一键删除原视频：\(ids.count) 个")
        let result = await PhotoLibraryService.shared.deleteOriginals(localIdentifiers: ids)
        markDeleted(originalIDs: result.deleted)
        return result.deleted.count
    }

    /// 删除完成后更新对应记录状态（删除失败的保留 notDeleted，可重试），并持久化。
    private func markDeleted(originalIDs: [String]) {
        guard !originalIDs.isEmpty else { return }
        let set = Set(originalIDs)
        let updated = entries.map { entry in
            guard let oid = entry.originalAssetIdentifier, set.contains(oid) else { return entry }
            var e = entry
            e.originalDeleteStatus = "deleted"
            return e
        }
        entries = updated
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// 原子写：先写临时文件，再 replace 覆盖，避免写一半被打断导致 JSON 损坏、
    /// 下次启动 load 失败而清空全部历史。
    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent("compression_history.json.tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItem(at: fileURL, withItemAt: tmp,
                                                    backupItemName: nil, options: [], resultingItemURL: nil)
        } catch {
            // 兜底：直接写（极端情况下 replace 失败时仍尽量落盘）
            try? data.write(to: fileURL)
        }
    }
}
