import SwiftUI

/// 进度条组件。
struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemFill))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor)
                    .frame(width: max(0, min(1, CGFloat(value))) * geo.size.width)
            }
        }
        .frame(height: 12)
        .animation(.easeInOut(duration: 0.2), value: value)
    }
}
