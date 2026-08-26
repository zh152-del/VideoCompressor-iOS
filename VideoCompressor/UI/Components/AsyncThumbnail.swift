import SwiftUI

/// 从本地文件加载缩略图。缩略图由 VideoInfoReader 生成（已按 preferredTransform 校正方向），
/// 此处明确使用图片真实宽高比以 aspect-fit 显示，绝不为填充容器而拉伸变形。
struct AsyncThumbnail: View {
    let url: URL?

    var body: some View {
        GeometryReader { geometry in
            if let url = url,
               FileManager.default.fileExists(atPath: url.path),
               let uiImage = UIImage(contentsOfFile: url.path) {
                let ratio = uiImage.size.width > 0 ? uiImage.size.width / uiImage.size.height : 1.0
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            } else {
                Image(systemName: "film")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width * 0.55, height: geometry.size.height * 0.55)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
