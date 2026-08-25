import SwiftUI

/// 已选视频的信息卡片。
struct VideoInfoCard: View {
    let item: VideoItem
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemFill))
                .frame(width: 64, height: 64)
                .overlay {
                    AsyncThumbnail(url: item.thumbnailURL)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(item.width)×\(item.height) · \(Formatters.bytes(item.fileSizeBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(Formatters.time(item.durationSeconds)) · \(Int(item.fps))fps · \(item.codecDescription)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
