import SwiftUI

/// 从本地文件加载缩略图。缩略图由 VideoInfoReader 生成（已按 preferredTransform 校正方向），
/// 此处以 aspect-fit 显示，保持真实宽高比，绝不为填充容器而拉伸变形。
struct AsyncThumbnail: View {
    let url: URL?
    var body: some View {
        Group {
            if let url = url, let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
    }
}
