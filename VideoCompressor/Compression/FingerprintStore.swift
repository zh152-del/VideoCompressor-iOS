import Foundation
import SwiftUI
import Photos
import UniformTypeIdentifiers

/// 一条压缩指纹记录。
struct CompressionRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let originalAssetID: String?      // 原视频 PHAsset.localIdentifier（重装后可能失效，仅作快速通道）
    let originalFingerprint: VideoFingerprint
    let compressedAssetID: String?    // 压缩成品 PHAsset.localIdentifier
    let compressedFingerprint: VideoFingerprint?
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let date: Date
    var status: String                // completed / markFailed / savedOnly
    var originalFileName: String?
}

/// 已压缩识别状态。
enum KnownStatus: Equatable {
    case known             // localIdentifier 直接命中（快速通道）
    case fingerprintMatch  // 指纹命中（可能已处理，可触发加采确认）
    case unknown
}

/// 指纹库：压缩记录持久化（沙盒 JSON + 用户授权文件夹中的日志文件跨重装恢复）。
@MainActor
final class FingerprintStore: ObservableObject {
    static let shared = FingerprintStore()
    static let logFileName = "axo_compression_log.json"

    @Published private(set) var records: [CompressionRecord] = []
    /// 用户文件夹授权状态（bookmark 是否有效）。
    @Published private(set) var hasFolderAccess = false

    private let fileURL: URL
    private let folderBookmarkKey = "vc_fingerprint_folder_bookmark"
    private var folderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: folderBookmarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: folderBookmarkKey) }
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent("compression_fingerprint_records.json")
        load()
        refreshFolderAccess()
    }

    // MARK: - 持久化（沙盒）

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CompressionRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let tmp = fileURL.deletingLastPathComponent().appendingPathComponent("compression_fingerprint_records.json.tmp")
        if (try? data.write(to: tmp)) != nil {
            _ = try? FileManager.default.replaceItem(at: fileURL, withItemAt: tmp,
                                                     backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - 查询

    /// 快速通道：原视频 localIdentifier 直接命中。
    func knownByID(_ assetID: String?) -> Bool {
        guard let id = assetID, !id.isEmpty else { return false }
        return records.contains { $0.originalAssetID == id }
    }

    /// 指纹粗匹配：与库内记录比较（时长+比例+5 帧感知哈希）。
    func matchByFingerprint(_ fp: VideoFingerprint) -> CompressionRecord? {
        records.first { FingerprintEngine.coarseMatch(a: $0.originalFingerprint, b: fp) }
    }

    /// 综合识别：先 ID，再指纹。
    func identify(assetID: String?, fingerprint: VideoFingerprint?) -> KnownStatus {
        if knownByID(assetID) { return .known }
        if let fp = fingerprint, matchByFingerprint(fp) != nil { return .fingerprintMatch }
        return .unknown
    }

    // MARK: - 写入

    /// 压缩确认成功后写入记录，并同步到用户文件夹日志（若已授权）。
    func add(record: CompressionRecord) {
        records.append(record)
        save()
        AppLog.mark("指纹记录已写入：\(record.originalFileName ?? "未知")，共 \(records.count) 条")
        writeLogToFolder()
    }

    /// 尝试把原视频指纹补录到已有记录（localIdentifier 快速命中后补充指纹，增强重装后识别）。
    func enrichOriginalFingerprint(assetID: String, fingerprint: VideoFingerprint) {
        guard let idx = records.firstIndex(where: { $0.originalAssetID == assetID }) else { return }
        records[idx] = CompressionRecord(id: records[idx].id,
                                         originalAssetID: records[idx].originalAssetID,
                                         originalFingerprint: fingerprint,
                                         compressedAssetID: records[idx].compressedAssetID,
                                         compressedFingerprint: records[idx].compressedFingerprint,
                                         originalSizeBytes: records[idx].originalSizeBytes,
                                         compressedSizeBytes: records[idx].compressedSizeBytes,
                                         date: records[idx].date,
                                         status: records[idx].status,
                                         originalFileName: records[idx].originalFileName)
        save()
        writeLogToFolder()
    }

    // MARK: - 用户文件夹（security-scoped bookmark）

    /// 用户通过系统目录选择器授权的文件夹（resolve 后需 security scope）。
    func resolveFolder() -> URL? {
        guard let data = folderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            hasFolderAccess = false
            return nil
        }
        if stale { refreshFolderAccess() }
        return url
    }

    private func refreshFolderAccess() {
        hasFolderAccess = resolveFolder() != nil
    }

    /// 保存用户选择的文件夹（bookmarked），并读取其中已有的日志文件合并记录。
    func setFolder(from pickedURL: URL) {
        let didAccess = pickedURL.startAccessingSecurityScopedResource()
        defer { if didAccess { pickedURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? pickedURL.bookmarkData() else {
            AppLog.mark("[ERROR] 文件夹 bookmark 创建失败")
            return
        }
        folderBookmark = data
        hasFolderAccess = true
        AppLog.mark("指纹文件夹已授权：\(pickedURL.lastPathComponent)")

        // 读取文件夹中已有日志，合并到本地库（按 originalFingerprint + 日期去重）
        let logURL = pickedURL.appendingPathComponent(Self.logFileName)
        if let data = try? Data(contentsOf: logURL),
           let imported = try? JSONDecoder().decode([CompressionRecord].self, from: data) {
            var merged = records
            var added = 0
            for r in imported {
                let exists = merged.contains { $0.originalAssetID == r.originalAssetID && $0.date == r.date }
                if !exists { merged.append(r); added += 1 }
            }
            if added > 0 {
                records = merged
                save()
                AppLog.mark("从日志文件合并 \(added) 条历史指纹记录")
            }
        }
        writeLogToFolder()
    }

    /// 把当前全部记录写入用户文件夹日志（覆盖式，内容为权威快照）。
    private func writeLogToFolder() {
        guard let folder = resolveFolder() else { return }
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        let logURL = folder.appendingPathComponent(Self.logFileName)
        if let data = try? JSONEncoder().encode(records) {
            do { try data.write(to: logURL, options: .atomic) }
            catch { AppLog.mark("[ERROR] 日志写入失败：\(error.localizedDescription)") }
        }
    }
}

/// 系统目录选择器（用户主动授权文件夹位置）。
struct FolderPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentDirectories: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker
        init(_ parent: FolderPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onPicked(url)
            }
            parent.dismiss()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
