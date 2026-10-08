import SwiftUI

/// 已选视频列表行：小圆角缩略图 + 名称 + 大小·时长，右侧轻量状态。
/// 不使用巨大卡片，行间用轻分隔线（由父级控制）。
struct VideoRow: View {
    let item: VideoItem
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            AsyncThumbnail(url: item.thumbnailURL)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(Formatters.bytes(item.fileSizeBytes)) · \(Formatters.time(item.durationSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
