import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var temp: TempFileManager
    @State private var confirmClean = false

    var body: some View {
        NavigationStack {
            Form {
                Section("压缩默认") {
                    Picker("默认模式", selection: $settings.defaultMode) {
                        ForEach(CompressionMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    Picker("优先编码", selection: $settings.preferredCodec) {
                        ForEach(VideoCodec.allCases) { c in Text(c.displayName).tag(c) }
                    }
                }
                Section("保存") {
                    Toggle("保存成功后自动删除原视频", isOn: $settings.deleteOriginalAfterSave)
                    Text("仅在压缩视频成功保存到照片图库后，才会删除原视频。")
                        .font(.caption).foregroundStyle(.secondary)
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
                        Text(Formatters.bytes(temp.occupiedBytes))
                    }
                    Button { confirmClean = true } label: {
                        Text("清理临时文件").foregroundStyle(.red)
                    }
                }
                Section("隐私") {
                    Text("本应用全程在设备本地处理视频，不上传、不联网、不需要账号。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: "1.0.0")
                    LabeledContent("构建", value: "本地 / CI 编译")
                }
            }
            .navigationTitle("设置")
            .alert("清理临时文件？", isPresented: $confirmClean) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) { temp.cleanupAll() }
            } message: {
                Text("将删除应用中所有尚未保存的压缩临时文件。")
            }
        }
    }
}
