import SwiftUI

/// 压缩方式选择页（独立页面）：模式 + 自定义高级参数。
/// 文字排版驱动，无卡片堆叠。
struct CompressionSettingsPage: View {
    @Binding var profile: CompressionProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                modeSection
                if profile.mode == .custom {
                    customSection
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Text("压缩方式")
                    .font(.largeTitle.bold())
                Text(profile.mode.hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 模式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("压缩模式")
                .font(.headline)
            ForEach(CompressionMode.allCases) { mode in
                Button {
                    profile.mode = mode
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(mode.hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.mode == mode {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if mode != CompressionMode.allCases.last {
                    Divider()
                }
            }
        }
    }

    // MARK: - 自定义参数

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自定义参数")
                .font(.headline)

            Picker("目标分辨率", selection: $profile.custom.resolution) {
                ForEach(PresetResolution.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("帧率").font(.subheadline)
                Spacer()
                Text(profile.custom.fps == 0 ? "沿用源帧率" : "\(Int(profile.custom.fps)) fps")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
            }
            Slider(value: $profile.custom.fps, in: 0...60, step: 1)

            HStack {
                Text("画质").font(.subheadline)
                Spacer()
                Text("\(Int(profile.custom.quality * 100))%")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Slider(value: $profile.custom.quality, in: 0.1...1.0, step: 0.05)

            Picker("编码格式", selection: $profile.custom.codec) {
                ForEach(VideoCodec.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: Binding(
                get: { profile.custom.targetSizeMB != nil },
                set: { on in profile.custom.targetSizeMB = on ? 50 : nil }
            )) {
                Text("限制目标文件大小").font(.subheadline)
            }
            if profile.custom.targetSizeMB != nil {
                HStack {
                    Slider(value: Binding(
                        get: { profile.custom.targetSizeMB ?? 50 },
                        set: { profile.custom.targetSizeMB = $0 }
                    ), in: 5...2000, step: 5)
                    Text("\(Int(profile.custom.targetSizeMB ?? 50)) MB")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }
}
