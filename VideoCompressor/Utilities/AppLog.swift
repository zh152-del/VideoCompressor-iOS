import Foundation
import os

/// 一条真实日志（落盘 + 内存环形缓冲，供设置页查看与导出）。
struct DiagLogEntry: Codable, Identifiable {
    let id: UUID = UUID()
    let time: Date
    let level: String      // INFO / WARN / ERROR
    let module: String     // 压缩 / 保存 / 扫描 / 历史 …
    let taskId: String?    // 任务 ID（App 级事件为 nil）
    let stage: String      // 阶段（读取/解码/编码/写入/验证/保存/历史…）
    let message: String
    var errorDomain: String?
    var errorCode: Int?
    var errorText: String?

    /// 导出为单行可读文本（UTF-8 TXT）。
    var textLine: String {
        let f = DiagLogEntry.textFormatter
        var line = "\(f.string(from: time)) [\(level)] [\(module)]"
        if let t = taskId, !t.isEmpty { line += " [task:\(String(t.prefix(8)))]" }
        line += " [\(stage)] \(message)"
        if let d = errorDomain { line += " | errDomain=\(d)" }
        if let c = errorCode { line += " errCode=\(c)" }
        if let e = errorText { line += " err=\(e)" }
        return line
    }

    static let textFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// 诊断日志：同时写系统日志（Console 可看）与本地文件（可导出排查）。
///
/// - 落盘目录：Documents/AXO-Logs/axo-YYYY-MM-DD.log（按天轮转，单文件上限 5 MB 后滚动为 .1）
/// - 内存缓冲：最近 500 条，供设置页直接查看
/// - 写文件失败不会影响压缩任务本身
enum DiagLog {
    private static let queue = DispatchQueue(label: "com.videocompressor.axo.diaglog", qos: .utility)
    private static let osLogger = Logger(subsystem: "com.videocompressor.axo", category: "diag")
    private static let maxBuffer = 500
    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024
    private static var buffer: [DiagLogEntry] = []
    private static var currentTaskId: String?
    private static var didWarnAboutDisk = false

    static var logDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("AXO-Logs", isDirectory: true)
    }

    static func beginTask(_ taskId: String) { currentTaskId = taskId }

    /// 记录一条真实事件（真实错误请传 error，会记录错误域/错误码）。
    static func log(_ level: String = "INFO", _ module: String, _ stage: String, _ message: String,
                    taskId: String? = nil, error: Error? = nil) {
        let entry = DiagLogEntry(time: Date(), level: level, module: module,
                                 taskId: taskId ?? currentTaskId, stage: stage, message: message,
                                 errorDomain: (error as NSError?)?.domain,
                                 errorCode: (error as NSError?)?.code,
                                 errorText: error?.localizedDescription)
        queue.async {
            DiagLog.buffer.append(entry)
            if DiagLog.buffer.count > DiagLog.maxBuffer {
                DiagLog.buffer.removeFirst(DiagLog.buffer.count - DiagLog.maxBuffer)
            }
            DiagLog.appendToFile(entry)
        }
        switch level {
        case "ERROR": osLogger.error("\(entry.textLine, privacy: .public)")
        case "WARN":  osLogger.warning("\(entry.textLine, privacy: .public)")
        default:      osLogger.info("\(entry.textLine, privacy: .public)")
        }
    }

    /// 内存中的最近日志（按时间倒序）。
    static func recentEntries(limit: Int = 300) -> [DiagLogEntry] {
        queue.sync { Array(buffer.suffix(limit).reversed()) }
    }

    /// 读取磁盘上全部日志（按时间正序）——崩溃后已落盘的内容仍可读取。
    static func readAllOnDisk() -> [DiagLogEntry] {
        queue.sync {
            let fm = FileManager.default
            let dir = logDirectory
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                  !files.isEmpty else { return [] }
            var out: [DiagLogEntry] = []
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    if let e = parseLine(String(line)) { out.append(e) }
                }
            }
            return out
        }
    }

    private static func parseLine(_ line: String) -> DiagLogEntry? {
        // 2026-01-01 12:00:00.000 [INFO] [压缩] [task:1A2B3C4D] [编码] 文本 | errDomain=x errCode=1 err=y
        guard let headEnd = line.firstIndex(of: "]") else { return nil }
        let timePart = String(line[..<headEnd])
        guard let date = DiagLogEntry.textFormatter.date(from: timePart) else { return nil }
        var remain = String(line[line.index(after: headEnd)...]).trimmingCharacters(in: .whitespaces)

        func nextTag() -> String? {
            guard remain.hasPrefix("[") else { return nil }
            guard let close = remain.firstIndex(of: "]") else { return nil }
            let tag = String(remain[remain.index(after: remain.startIndex)..<close])
            remain = String(remain[remain.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            return tag
        }
        var level = "INFO", module = "", stage = ""
        var taskId: String?
        if let t = nextTag() { level = t }
        if let m = nextTag() { module = m }
        if let t = nextTag(), t.hasPrefix("task:") { taskId = String(t.dropFirst("task:".count)) }
        if let s = nextTag() { stage = s }

        var message = remain
        var domain: String?, code: Int?, errText: String?
        if let cut = message.range(of: " | errDomain=") {
            let tail = String(message[cut.upperBound...])
            message = String(message[..<cut.lowerBound])
            for token in tail.split(separator: " ").map(String.init) {
                if token.hasPrefix("errDomain=") { domain = String(token.dropFirst("errDomain=".count)) }
                else if token.hasPrefix("errCode=") { code = Int(token.dropFirst("errCode=".count)) }
                else if token.hasPrefix("err=") { errText = String(token.dropFirst("err=".count)) }
            }
            if let e = tail.range(of: "err=") { errText = String(tail[e.upperBound...]) }
        }
        return DiagLogEntry(time: date, level: level, module: module, taskId: taskId,
                            stage: stage, message: message,
                            errorDomain: domain, errorCode: code, errorText: errText)
    }

    private static func appendToFile(_ e: DiagLogEntry) {
        let fm = FileManager.default
        let dir = logDirectory
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch {
                if !didWarnAboutDisk {
                    didWarnAboutDisk = true
                    osLogger.error("诊断日志目录创建失败：\(error.localizedDescription, privacy: .public)")
                }
                return
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let file = dir.appendingPathComponent("axo-\(f.string(from: e.time)).log")
        if let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? UInt64, size > maxFileBytes {
            let rolled = dir.appendingPathComponent("axo-\(f.string(from: e.time)).log.1")
            try? fm.removeItem(at: rolled)
            try? fm.moveItem(at: file, to: rolled)
        }
        guard let data = (e.textLine + "\n").data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: file) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)   // 首次创建
        }
    }

    /// 清理旧日志（保留最近 keepDays 天）。
    static func cleanOldLogs(keepDays: Int = 7) -> Int {
        queue.sync {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else { return 0 }
            let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
            var removed = 0
            for f in files where f.pathExtension == "log" {
                if let d = try? fm.attributesOfItem(atPath: f.path)[.creationDate] as? Date, d < cutoff {
                    try? fm.removeItem(at: f); removed += 1
                }
            }
            return removed
        }
    }
}

/// 统一的结构化开发日志（os_log + 诊断文件双写）。
enum AppLog {
    private static let logger = Logger(subsystem: "com.videocompressor.axo", category: "app")

    static func app(_ msg: String)      { emit("APP", "启动", msg) }
    static func photo(_ msg: String)    { emit("PHOTO", "Photos", msg) }
    static func compress(_ msg: String) { emit("COMPRESS", "压缩", msg) }
    static func delete(_ msg: String)   { emit("DELETE", "删除", msg) }
    static func history(_ msg: String)  { emit("HISTORY", "历史", msg) }
    static func ui(_ msg: String)       { emit("UI", "界面", msg) }
    static func videoScan(_ msg: String) { emit("SCAN", "扫描", msg) }
    static func mark(_ msg: String)     { emit("MARK", "标记", msg) }
    static func thumbnail(_ msg: String) { emit("THUMB", "封面", msg) }
    static func perf(_ msg: String)     { emit("PERF", "性能", msg) }

    /// 失败/异常专用：带错误域与错误码，可直接用于排查"无法压缩"。
    static func failure(_ module: String, _ stage: String, _ msg: String, error: Error? = nil) {
        DiagLog.log("ERROR", module, stage, msg, error: error)
        logger.error("[\(module, privacy: .public)][\(stage, privacy: .public)] \(msg, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
    }

    /// 阶段事件（读取/解码/编码/写入/验证/保存等）。
    static func stage(_ stage: String, _ msg: String, taskId: String? = nil) {
        DiagLog.log("INFO", "COMPRESS", stage, msg, taskId: taskId)
    }

    private static func emit(_ tag: String, _ stage: String, _ msg: String) {
        logger.log("[\(tag, privacy: .public)] \(msg, privacy: .public)")
        DiagLog.log("INFO", tag, stage, msg)
    }
}