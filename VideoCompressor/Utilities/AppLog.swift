import Foundation
import os

/// 结构化开发日志（os_log），用于真机排查：压缩、保存、删除、导航、UI 状态。
/// Console.app / Instruments 均可按 subsystem 过滤。
enum AppLog {
    private static let logger = Logger(subsystem: "com.videocompressor.axo", category: "app")

    static func app(_ msg: String)  { logger.log("[APP] \(msg, privacy: .public)") }
    static func photo(_ msg: String) { logger.log("[PHOTO] \(msg, privacy: .public)") }
    static func compress(_ msg: String) { logger.log("[COMPRESS] \(msg, privacy: .public)") }
    static func delete(_ msg: String) { logger.log("[DELETE] \(msg, privacy: .public)") }
    static func history(_ msg: String) { logger.log("[HISTORY] \(msg, privacy: .public)") }
    static func ui(_ msg: String) { logger.log("[UI] \(msg, privacy: .public)") }
}
