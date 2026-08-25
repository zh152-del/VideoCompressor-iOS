import SwiftUI

/// 从本地文件加载缩略图。
struct AsyncThumbnail: View {
    let url: URL?
    var body: some View {
        Group {
            if let url = url, let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
    }
}
