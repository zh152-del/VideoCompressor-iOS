import SwiftUI

/// 批量压缩结果列表，点击进入单条详情。
struct BatchResultView: View {
    let results: [CompressionResult]
    var onContinue: (() -> Void)? = nil

    var body: some View {
        List {
            ForEach(results) { r in
                NavigationLink {
                    ResultView(result: r, onContinue: onContinue)
                } label: {
                    HStack {
                        AsyncThumbnail(url: r.item.thumbnailURL)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(r.item.title).lineLimit(1)
                            Text("\(Formatters.bytes(r.item.fileSizeBytes)) → \(Formatters.bytes(r.outputSizeBytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let saved = r.item.fileSizeBytes - r.outputSizeBytes
                        let pct = Double(saved) / Double(max(r.item.fileSizeBytes, 1))
                        Text("-\(Formatters.percent(pct))").font(.caption).foregroundStyle(.green)
                    }
                }
            }
        }
        .navigationTitle("批量结果（\(results.count)）")
        .safeAreaInset(edge: .bottom) {
            if let onContinue {
                Button { onContinue() } label: {
                    Text("完成").frame(maxWidth: .infinity).padding()
                }
                .background(Color.accentColor).foregroundStyle(.white)
            }
        }
    }
}
