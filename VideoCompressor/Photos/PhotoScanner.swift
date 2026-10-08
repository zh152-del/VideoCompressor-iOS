import Foundation
import Photos

/// 标记常量：压缩成功的视频文件名会包含该字符串。
/// 只存在于【压缩成品】的 PHAsset originalFilename 中（保存时命名，零重编码）。
enum ProcessedMark {
    static let marker = "__VC__"
    /// 文件名是否已压缩。
    static func isProcessed(filename: String) -> Bool { filename.contains(marker) }
    /// 压缩成品保存名：原名去扩展 + __VC__ + 扩展名。重复压缩不会叠加标记。
    static func markedName(for title: String) -> String {
        let ns = title as NSString
        let base = ns.deletingPathExtension.replacingOccurrences(of: marker, with: "")
        let ext = ns.pathExtension.isEmpty ? "mp4" : ns.pathExtension
        return "\(base)\(marker).\(ext)"
    }
}

/// 首页扫描到的视频。
struct ScannedVideo: Identifiable {
    let id: String              // PHAsset.localIdentifier
    let asset: PHAsset
    let filename: String
    /// 资源字节大小；PHAssetResource.dataSize 不可用时为 nil（显示「大小暂不可用」，绝不伪装 0 KB）。
    let fileSizeBytes: Int64?
    let duration: Double
    let pixelWidth: Int
    let pixelHeight: Int
    /// PHAsset.pixelWidth/Height 已经按方向给出真实显示尺寸（竖屏视频=1080×1920 而非 1920×1080）。
    var resolutionText: String { "\(pixelWidth) × \(pixelHeight)" }
    var aspectText: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "未知" }
        func simplify(_ a: Int, _ b: Int) -> String {
            func gcd(_ x: Int, _ y: Int) -> Int { y == 0 ? x : gcd(y, x % y) }
            let g = gcd(a, b)
            let ra = a / g, rb = b / g
            if rb == 1 { return "\(ra):1" }
            if ra <= 32, rb <= 32 { return "\(ra):\(rb)" }
            return String(format: "%.2f:1", Double(a) / Double(b))
        }
        return simplify(pixelWidth, pixelHeight)
    }
    /// 已压缩识别：文件名包含 __VC__ 标记。
    var isProcessed: Bool { ProcessedMark.isProcessed(filename: filename) }
}

/// 相册视频扫描器：启动后按需扫描，只读元数据（文件名/大小/时长/尺寸），
/// 绝不读取视频内容、不做 hash、不生成批量封面（封面由 AssetThumbnail 懒加载）。
@MainActor
final class PhotoScanner: ObservableObject {
    enum ScanStatus: Equatable {
        case idle
        case denied
        case limited
        case scanning
        case done(count: Int)
    }

    @Published var videos: [ScannedVideo] = []
    @Published var status: ScanStatus = .idle

    /// 扫描用户允许访问的全部视频（authorized/limited 均只返回授权范围）。
    func scan() {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch auth {
        case .denied, .restricted:
            status = .denied
            AppLog.videoScan("权限被拒，无法扫描")
            return
        case .notDetermined:
            status = .idle
            return   // 由 UI 触发请求授权后再扫描
        default:
            break
        }
        status = .scanning
        AppLog.videoScan("START")

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let fetch = PHAsset.fetchAssets(with: .video, options: options)
        var items: [ScannedVideo] = []
        items.reserveCapacity(fetch.count)
        for i in 0..<fetch.count {
            let asset = fetch.object(at: i)
            let resources = PHAssetResource.assetResources(for: asset)
            let videoResource = resources.first { $0.type == .video } ?? resources.first
            // 文件大小：iOS SDK 未公开 PHAssetResource 的字节大小（且禁止 KVC 强读），
            // 扫描阶段诚实返回 nil（UI 显示「大小暂不可用」）；真实大小在压缩时由导出文件获得并写入历史。
            let size: Int64? = nil
            let filename = videoResource?.originalFilename ?? asset.value(forKey: "filename") as? String ?? "VIDEO_\(i)"
            items.append(ScannedVideo(
                id: asset.localIdentifier,
                asset: asset,
                filename: filename,
                fileSizeBytes: size,
                duration: asset.duration,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
        }
        videos = items
        let processed = items.filter { $0.isProcessed }.count
        status = items.isEmpty ? .done(count: 0) : (auth == .limited ? .limited : .done(count: items.count))
        AppLog.videoScan("Asset Count=\(items.count)，含 __VC__ 标记 \(processed) 个")
    }

    /// 全部带 __VC__ 标记的 PHAsset（设置页"清除标记"用）。
    static func fetchProcessedAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let fetch = PHAsset.fetchAssets(with: .video, options: options)
        var result: [PHAsset] = []
        for i in 0..<fetch.count {
            let asset = fetch.object(at: i)
            let resources = PHAssetResource.assetResources(for: asset)
            if let name = (resources.first { $0.type == .video } ?? resources.first)?.originalFilename,
               ProcessedMark.isProcessed(filename: name) {
                result.append(asset)
            }
        }
        return result
    }
}
