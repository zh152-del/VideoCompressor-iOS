import SwiftUI

/// 压缩设置面板（模式 + 自定义选项）。
struct CompressionSettingsView: View {
    @Binding var profile: CompressionProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("压缩设置").font(.headline)
            Picker("压缩模式", selection: $profile.mode) {
                ForEach(CompressionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(profile.mode.hint).font(.caption).foregroundStyle(.secondary)

            if profile.mode == .custom {
                customOptions
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var customOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("目标分辨率（不会放大低分辨率视频）").font(.subheadline).fontWeight(.medium)
                Picker("分辨率", selection: $profile.custom.resolution) {
                    ForEach(PresetResolution.allCases) { r in
                        Text(r.displayName).tag(r)
                    }
                }
                .pickerStyle(.menu)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("帧率（0 = 沿用源帧率）").font(.subheadline).fontWeight(.medium)
                HStack {
                    Slider(value: $profile.custom.fps, in: 0...60, step: 1)
                    Text(profile.custom.fps == 0 ? "源" : "\(Int(profile.custom.fps))").frame(width: 44)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("画质（影响码率）").font(.subheadline).fontWeight(.medium)
                HStack {
                    Slider(value: $profile.custom.quality, in: 0.1...1.0, step: 0.05)
                    Text("\(Int(profile.custom.quality * 100))%").frame(width: 44)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("编码格式").font(.subheadline).fontWeight(.medium)
                Picker("编码", selection: $profile.custom.codec) {
                    ForEach(VideoCodec.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("限制目标文件大小", isOn: Binding(
                    get: { profile.custom.targetSizeMB != nil },
                    set: { on in profile.custom.targetSizeMB = on ? 50 : nil }
                ))
                if profile.custom.targetSizeMB != nil {
                    HStack {
                        Slider(value: Binding(
                            get: { profile.custom.targetSizeMB ?? 50 },
                            set: { profile.custom.targetSizeMB = $0 }
                        ), in: 5...2000, step: 5)
                        Text("\(Int(profile.custom.targetSizeMB ?? 50)) MB").frame(width: 70)
                    }
                }
            }
        }
    }
}
