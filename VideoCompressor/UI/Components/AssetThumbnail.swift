import SwiftUI
import Photos

/// 历史记录封面：优先从压缩成品的 PHAsset（outputAssetIdentifier）取代表帧，
/// 请求列表显示尺寸的小图（resizeMode .fast），NSCache 缓存避免重复读取。
/// 封面获取失败只影响显示，绝不影响任何压缩功能。
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 300 }
    func image(for id: String) -> UIImage? { cache.object(forKey: id as NSString) }
    func store(_ image: UIImage, for id: String) { cache.setObject(image, forKey: id as NSString) }
}

struct AssetThumbnail: View {
    let assetIdentifier: String?
    var side: CGFloat = 52

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color(.tertiarySystemFill))
                    Image(systemName: "film")
                        .font(.system(size: side * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: assetIdentifier) {
            guard let id = assetIdentifier, image == nil else { return }
            if let cached = ThumbnailCache.shared.image(for: id) {
                image = cached
                return
            }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                return   // 成品 Asset 不存在（如被手动删除），显示占位图
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.resizeMode = .fast
            options.deliveryMode = .fastFormat
            options.isSynchronous = false
            let target = CGSize(width: side * 2, height: side * 2)   // @2x 列表小图
            PHImageManager.default().requestImage(for: asset,
                                                   targetSize: target,
                                                   contentMode: .aspectFill,
                                                   options: options) { img, _ in
                guard let img else { return }
                ThumbnailCache.shared.store(img, for: id)
                Task { @MainActor in image = img }
            }
        }
    }
}
