import SwiftUI
import UniformTypeIdentifiers

/// 诊断日志页：查看 / 按任务筛选 / 导出 TXT + JSON（交给用户选择保存位置，例如"文件"App 里的 WorkBuddy 文件夹）。
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [DiagLogEntry] = []
    @State private var taskFilter: String = ""
    @State private var exportTaskId: String = ""
    @State private var showExporter = false
    @State private var exportFiles: [URL] = []
    @State private var statusMessage: String?
    @State private var confirmClean = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("日志条数").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(filtered.count) / \(entries.count)")
                }
                HStack {
                    TextField("按任务 ID 前缀筛选", text: $taskFilter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button("刷新") { reload() }
                    .buttonStyle(PressableButtonStyle())
            } header: {
                Text("诊断日志")
            } footer: {
                Text("日志已落盘到 App 内 Documents/AXO-Logs（按天轮换，单文件上限 5MB）。闪退后已落盘的内容仍可读取。")
            }

            Section("导出") {
                Button {
                    prepareExport(scope: .all)
                } label: {
                    Label("导出全部日志（TXT + JSON）", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    prepareExport(scope: .latestTask)
                } label: {
                    Label("导出最近一次任务", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(lastTaskId == nil)

                if lastTaskId != nil {
                    TextField("指定任务 ID", text: $exportTaskId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        prepareExport(scope: .specific(exportTaskId.isEmpty ? (lastTaskId ?? "") : exportTaskId))
                    } label: {
                        Label("导出指定任务", systemImage: "target")
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                Button(role: .destructive) {
                    confirmClean = true
                } label: {
                    Label("清理 7 天前的旧日志", systemImage: "trash")
                }
                .buttonStyle(PressableButtonStyle())

                if let msg = statusMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                Text("导出后会弹出系统文件保存界面，请选择目标文件夹（例如 iOS「文件」App 中的 WorkBuddy 目录）。App 无法自行写入其他 App 的目录。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("最近日志（最新在上）") {
                ForEach(filtered.prefix(300)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.message)
                            .font(.system(size: 12, design: .monospaced))
                        HStack(spacing: 6) {
                            Text(DiagLogEntry.textFormatter.string(from: e.time))
                            Text(e.level).foregroundStyle(color(for: e.level))
                            Text(e.module)
                            if let st = e.stage { Text(st) }
                            if let t = e.taskId { Text("task:\(String(t.prefix(8)))") }
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        if let d = e.errorDomain {
                            Text("errDomain=\(d) code=\(e.errorCode.map(String.init) ?? "-") \(e.errorText ?? "")")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .confirmationDialog("确定清理 7 天前的旧日志？", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("清理", role: .destructive) {
                let n = DiagLog.cleanOldLogs(keepDays: 7)
                statusMessage = "已清理 \(n) 个旧日志文件"
                reload()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showExporter) {
            if exportFiles.isEmpty {
                ProgressView().padding()
            } else {
                FileExporterView(files: exportFiles, onDone: { showExporter = false })
            }
        }
    }

    private enum ExportScope {
        case all, latestTask, specific(String)
    }

    private var filtered: [DiagLogEntry] {
        let key = (taskFilter.isEmpty ? exportTaskId : taskFilter).trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return entries }
        return entries.filter { ($0.taskId?.lowercased().contains(key) ?? false) }
    }

    private var lastTaskId: String? {
        entries.first(where: { $0.taskId != nil })?.taskId
    }

    private func reload() {
        // 合并磁盘与内存，磁盘优先（崩溃前落盘的内容）
        var merged = DiagLog.readAllOnDisk()
        let existing = Set(merged.map(\.textLine))
        for e in DiagLog.recentEntries(limit: 500) where !existing.contains(e.textLine) {
            merged.append(e)
        }
        entries = merged.sorted { $0.time > $1.time }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN":  return .orange
        default:      return .secondary
        }
    }

    /// 生成 TXT + JSON + 摘要，交给系统导出器（用户自选目录）。
    private func prepareExport(scope: ExportScope) {
        let subset: [DiagLogEntry]
        switch scope {
        case .all:         subset = entries
        case .latestTask:  subset = entries.filter { $0.taskId != nil && $0.taskId == lastTaskId }
        case .specific(let id):
            let key = id.lowercased()
            subset = entries.filter { ($0.taskId?.lowercased().contains(key) ?? false) }
        }
        guard !subset.isEmpty else {
            statusMessage = "没有可导出的日志"
            return
        }
        do {
            let files = try DiagLogExporter.makeExportFiles(entries: subset.sorted { $0.time < $1.time })
            exportFiles = files
            statusMessage = "已生成 \(files.count) 个文件（\(subset.count) 条日志），请选择保存位置"
            showExporter = true
        } catch {
            statusMessage = "导出准备失败：\(error.localizedDescription)"
            AppLog.failure("DIAG", "导出", "生成导出文件失败", error: error)
        }
    }
}

/// 生成导出文件（TXT + JSON + 任务摘要）。
enum DiagLogExporter {
    static func makeExportFiles(entries: [DiagLogEntry]) throws -> [URL] {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let base = "AXO-Diagnostics-\(stamp.string(from: Date()))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axo-diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. 可读 TXT
        let txtURL = dir.appendingPathComponent("\(base).txt")
        let header = """
        AXO 视频压缩 · 诊断日志
        导出时间：\(stamp.string(from: Date()))
        日志条数：\(entries.count)
        设备：\(UIDevice.current.model) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        说明：日志仅在成功落盘后才会存在；进程崩溃后只能取到崩溃前已写入的内容。

        """
        let body = entries.map(\.textLine).joined(separator: "\n")
        try (header + body).write(to: txtURL, atomically: true, encoding: .utf8)

        // 2. 结构化 JSON
        let jsonURL = dir.appendingPathComponent("\(base).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        struct Wrapper: Codable {
            let exportedAt: String
            let device: String
            let count: Int
            let entries: [DiagLogEntry]
        }
        let wrapper = Wrapper(exportedAt: stamp.string(from: Date()),
                              device: "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)",
                              count: entries.count, entries: entries)
        try enc.encode(wrapper).write(to: jsonURL, options: .atomic)

        // 3. 任务状态摘要（快速定位失败阶段）
        let sumURL = dir.appendingPathComponent("\(base)-summary.txt")
        var summary = "任务状态摘要（按任务 ID）\n"
        var byTask: [String: [DiagLogEntry]] = [:]
        for e in entries {
            guard let t = e.taskId, !t.isEmpty else { continue }
            byTask[t, default: []].append(e)
        }
        if byTask.isEmpty {
            summary += "（本次导出不含任务级日志）\n"
        }
        for (task, list) in byTask.sorted(by: { $0.key < $1.key }) {
            let errors = list.filter { $0.level == "ERROR" }
            let stages = list.map { $0.stage }.filter { !$0.isEmpty }
            summary += "\n任务 \(task.prefix(8))\n"
            summary += "  事件数：\(list.count)\n"
            summary += "  最后阶段：\(stages.last ?? "-")\n"
            summary += "  最后事件：\(list.last?.message ?? "-")\n"
            summary += "  错误数：\(errors.count)\n"
            for e in errors.prefix(3) {
                summary += "   - [\(e.stage)] \(e.message) \(e.errorText ?? "")\n"
            }
        }
        try summary.write(to: sumURL, atomically: true, encoding: .utf8)

        return [txtURL, jsonURL, sumURL]
    }
}

/// 多文件导出：系统保存界面（用户自选目录，例如"文件"App 的 WorkBuddy 文件夹）。
struct FileExporterView: UIViewControllerRepresentable {
    let files: [URL]
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: files, applicationActivities: nil)
        vc.excludedActivityTypes = nil
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static var dismissable: (UIActivityViewController) -> (() -> Void)? {
        { vc in
            // UIActivityViewController 无闭包式 dismiss；用包装控制器
            return { }
        }
    }
}