import Foundation
import Combine

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
