import SwiftUI

/// 压缩方式选择页（独立 push 页面）。
///
/// 导航关键修复：使用【系统导航栏 + 系统返回按钮】。
/// 之前隐藏导航栏 + 自定义返回按钮 + dismiss() 的组合在 push 场景下
/// 会破坏边缘侧滑并导致无法返回。不混用导航状态。
///
/// 选中态：当前模式整行有明确的浅蓝圆角选框 + 勾选图标，一眼可见。
struct CompressionSettingsPage: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var profile: Binding<CompressionProfile> {
        Binding(
            get: { appState.profile },
            set: { appState.profile = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                modeSection
                if appState.profile.mode == .custom {
                    customSection
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.large)
        .navigationTitle("压缩方式")
        .onAppear { AppLog.ui("进入压缩方式页面") }
        .onDisappear { AppLog.ui("返回压缩页面（当前模式：\(appState.profile.mode.displayName)）") }
    }

    // MARK: - 模式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("压缩模式")
                .font(.headline)
            ForEach(CompressionMode.allCases) { mode in
                let isSelected = (appState.profile.mode == mode)
                Button {
                    appState.profile.mode = mode
                    AppLog.ui("选择压缩模式：\(mode.displayName)")
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(.primary)
                            Text(mode.hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear,
                                          lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    // MARK: - 自定义参数

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自定义参数")
                .font(.headline)

            Picker("目标分辨率", selection: profile.custom.resolution) {
                ForEach(PresetResolution.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("帧率").font(.subheadline)
                Spacer()
                Text(appState.profile.custom.fps == 0 ? "沿用源帧率" : "\(Int(appState.profile.custom.fps)) fps")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
            }
            Slider(value: profile.custom.fps, in: 0...60, step: 1)

            HStack {
                Text("画质").font(.subheadline)
                Spacer()
                Text("\(Int(appState.profile.custom.quality * 100))%")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Slider(value: profile.custom.quality, in: 0.1...1.0, step: 0.05)

            Picker("编码格式", selection: profile.custom.codec) {
                ForEach(VideoCodec.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: Binding(
                get: { appState.profile.custom.targetSizeMB != nil },
                set: { on in appState.profile.custom.targetSizeMB = on ? 50 : nil }
            )) {
                Text("限制目标文件大小").font(.subheadline)
            }
            if appState.profile.custom.targetSizeMB != nil {
                HStack {
                    Slider(value: Binding(
                        get: { appState.profile.custom.targetSizeMB ?? 50 },
                        set: { appState.profile.custom.targetSizeMB = $0 }
                    ), in: 5...2000, step: 5)
                    Text("\(Int(appState.profile.custom.targetSizeMB ?? 50)) MB")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }
}
