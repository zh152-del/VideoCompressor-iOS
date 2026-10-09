import Foundation
import Photos

/// 首页扫描到的视频。
struct ScannedVideo: Identifiable {
    let id: String              // PHAsset.localIdentifier
    let asset: PHAsset
    let filename: String
    let fileSizeBytes: Int64
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

    /// 扫描用户允许访问的全部视频。
    /// 首次启动（未决定权限）时自动申请授权，授权完成后自动继续扫描。
    func scan() {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch auth {
        case .denied, .restricted:
            status = .denied
            AppLog.videoScan("权限被拒，无法扫描")
            return
        case .notDetermined:
            // 【修复】App 启动时自动申请相册权限；用户同意后立即扫描
            status = .idle
            AppLog.videoScan("权限未决定，主动请求授权")
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                Task { @MainActor in
                    AppLog.videoScan("授权回调：\(newStatus.rawValue)")
                    self?.scan()
                }
            }
            return
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
            // KVC 读取资源文件大小（不加载文件内容）
            let size = (videoResource?.value(forKey: "fileSize") as? Int64) ?? 0
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
        status = items.isEmpty ? .done(count: 0) : (auth == .limited ? .limited : .done(count: items.count))
        AppLog.videoScan("Asset Count=\(items.count)")
    }
}
