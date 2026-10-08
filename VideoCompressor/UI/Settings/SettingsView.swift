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
