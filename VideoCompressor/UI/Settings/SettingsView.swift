import SwiftUI

/// 设置页：大标题 + 文字层级分组 + 轻分隔线，不堆卡片。
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var temp: TempFileManager
    @State private var confirmClean = false

    var body: some View {
        NavigationStack {
            Form {
                Section("压缩") {
                    Picker("默认模式", selection: $settings.defaultMode) {
                        ForEach(CompressionMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    Picker("优先编码", selection: $settings.preferredCodec) {
                        ForEach(VideoCodec.allCases) { c in Text(c.displayName).tag(c) }
                    }
                }
                Section {
                    Toggle("压缩成功后删除原视频", isOn: $settings.deleteOriginalAfterSave)
                    Text("只有压缩文件成功保存到照片图库后，才会删除原视频。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("保存")
                } footer: {
                    Text("压缩后体积不小于原视频时，不会保存也不会删除原视频。")
                }
                Section {
                    Toggle("自动跳过小视频", isOn: $settings.skipSmallVideosEnabled)
                    if settings.skipSmallVideosEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("小于该大小自动跳过").font(.subheadline)
                                Spacer()
                                Text("\(Int(settings.skipSmallVideosThresholdMB)) MB")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.skipSmallVideosThresholdMB,
                                   in: 1...1024, step: 1)
                            HStack {
                                Text("常用：")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach([10.0, 50.0, 100.0, 200.0], id: \.self) { v in
                                    Button("\(Int(v))MB") { settings.skipSmallVideosThresholdMB = v }
                                        .font(.caption)
                                        .buttonStyle(PressableButtonStyle())
                                        .foregroundStyle(settings.skipSmallVideosThresholdMB == v
                                                         ? Color.accentColor : Color.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    Text("规则只作用于「一键压缩」的批量任务：文件大小严格小于阈值的视频记为已跳过（不压缩、不删原视频）；等于阈值照常压缩；大小未知的视频不会被跳过。手动单个选择不受影响。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("一键压缩跳过规则")
                }
                Section("外观") {
                    Picker("主题", selection: $settings.appearance) {
                        ForEach(Appearance.allCases) { a in Text(a.displayName).tag(a) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("临时文件") {
                    HStack {
                        Text("已占用空间")
                        Spacer()
                        Text(Formatters.bytes(temp.occupiedBytes)).foregroundStyle(.secondary)
                    }
                    Button { confirmClean = true } label: {
                        Text("清理临时文件").foregroundStyle(.red)
                    }
                }
                Section("隐私") {
                    Text("所有视频均在设备本地处理\n不上传 · 不联网 · 无需账号")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: "1.0.0")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("设置").font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                    .background(Color(.systemGroupedBackground))
            }
            .alert("清理临时文件？", isPresented: $confirmClean) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) { temp.cleanupAll() }
            } message: {
                Text("将删除应用中所有尚未保存的压缩临时文件。")
            }
        }
    }
}
