import Foundation
import Combine

/// 临时文件生命周期管理。压缩产物位于应用临时目录，支持按任务清理、取消清理、启动清理。
/// 作为单例供服务与界面共享同一临时目录。
final class TempFileManager: ObservableObject {
    static let shared = TempFileManager()

    let directory: URL
    @Published private(set) var occupiedBytes: Int64 = 0

    init() {
        let base = FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent("VideoCompressor", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        cleanupStale()
    }

    func newOutputURL(ext: String = "mp4") -> URL {
        directory.appendingPathComponent("compress-\(UUID().uuidString).\(ext)")
    }

    func newThumbnailURL() -> URL {
        directory.appendingPathComponent("thumb-\(UUID().uuidString).jpg")
    }

    /// 删除单个文件（忽略错误）。
    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshOccupied()
    }

    func cleanup(_ urls: [URL]) {
        urls.forEach(remove)
    }

    /// 启动或异常退出后清理所有遗留文件。
    func cleanupStale() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        contents.forEach { try? FileManager.default.removeItem(at: $0) }
        refreshOccupied()
    }

    /// 设置页「清理临时文件」。
    func cleanupAll() { cleanupStale() }

    func refreshOccupied() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = contents.reduce(0) { sum, url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 + sum
        }
        DispatchQueue.main.async { [weak self] in self?.occupiedBytes = total }
    }
}
