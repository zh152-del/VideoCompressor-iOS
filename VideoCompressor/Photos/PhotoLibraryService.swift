import Foundation
import Photos
import Combine

/// 照片图库权限与读写操作。
///
/// 关键约束（iOS 规范）：
/// 1. 「保存压缩视频」只需 **addOnly** 权限（对应 `NSPhotoLibraryAddUsageDescription`）。
/// 2. 「删除原视频」需要 **readWrite** 权限（对应 `NSPhotoLibraryUsageDescription`），
///    因此删除操作才申请 readWrite，避免向用户无谓请求完全访问。
/// 3. 必须先保存成功，再删除原片；任何失败都返回错误而非崩溃。
///
/// 所有 Photos 回调可能在非主线程触发，统一 `DispatchQueue.main.async` 后再 resume
/// `CheckedContinuation`，防止真机因线程/隔离问题闪退。
@MainActor
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()

    // MARK: - 权限等级查询

    /// 仅保存（添加）所需的最低权限级别状态。
    func addStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// 读取 + 修改（删除原片）所需权限级别状态。
    func readWriteStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - 保存视频（仅申请 addOnly）

    /// 将压缩后的视频保存到照片图库。
    /// - Parameter fileURL: 待保存的视频文件（应为本地可读的 MP4/MOV/M4V）。
    /// - Returns: 新保存资源的 `localIdentifier`，供后续定位或删除。
    /// - Throws: 权限被拒/受限、输出文件缺失/为空/格式不支持、图库写入失败等。
    func saveVideo(at fileURL: URL) async throws -> String {
        // 0. 保存前校验输出文件（存在 / 可读 / 大小 > 0 / 类型正确）
        try validateOutputFile(fileURL)

        // 1. 仅申请 addOnly 权限（不无谓请求 readWrite）
        var status = addStatus()
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        // 2. 完整处理五种授权状态
        switch status {
        case .authorized, .limited:
            break // 允许保存
        case .denied:
            throw AppError.photoPermissionDenied
        case .restricted:
            throw AppError.photoPermissionRestricted
        case .notDetermined:
            // 请求后理论上不会仍处未确定；若如此视为拒绝，避免无限等待。
            throw AppError.photoPermissionDenied
        @unknown default:
            throw AppError.photoPermissionDenied
        }

        // 3. 执行保存：在 changes block 内直接拿到 placeholder 的 localIdentifier，
        //    避免保存后反查相册（不可靠且易在主线程外访问）。
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var placeholderID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                placeholderID = request?.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                DispatchQueue.main.async {
                    if success, let id = placeholderID, !id.isEmpty {
                        cont.resume(returning: id)
                    } else if let error = error {
                        cont.resume(throwing: AppError.saveToPhotoFailed(error.localizedDescription))
                    } else if placeholderID == nil {
                        // creationRequest 返回 nil：文件无法被照片 app 导入（损坏/格式不符）
                        cont.resume(throwing: AppError.saveToPhotoFailed("照片图库无法导入该视频文件"))
                    } else {
                        cont.resume(throwing: AppError.saveToPhotoFailed("照片图库写入失败"))
                    }
                }
            }
        }
    }

    // MARK: - 删除原视频（仅此处申请 readWrite）

    /// 仅在「保存成功」后调用：删除原始资源。
    /// 需要 readWrite 权限；空标识或无该资源时安全跳过（不报错、不崩溃）。
    /// - Parameter localIdentifier: 原视频在照片图库中的 `localIdentifier`。
    func deleteOriginal(localIdentifier: String) async throws {
        guard !localIdentifier.isEmpty else { return }

        // 删除需要 readWrite 权限
        var status = readWriteStatus()
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized, .limited:
            break
        case .denied:
            throw AppError.photoPermissionDenied
        case .restricted:
            throw AppError.photoPermissionRestricted
        case .notDetermined:
            throw AppError.photoPermissionDenied
        @unknown default:
            throw AppError.photoPermissionDenied
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard assets.count > 0 else { return } // 原片可能已在图库外，安全跳过

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        cont.resume()
                    } else {
                        cont.resume(throwing: AppError.deleteOriginalFailed(error?.localizedDescription ?? "删除原视频失败"))
                    }
                }
            }
        }
    }

    // MARK: - 私有：输出文件校验

    /// 保存前校验输出文件：存在 / 可读 / 大小 > 0 / 容器类型受支持。
    private func validateOutputFile(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw AppError.outputFileMissing
        }
        guard fm.isReadableFile(atPath: url.path) else {
            throw AppError.outputFileMissing
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw AppError.outputFileEmpty
        }
        let ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            throw AppError.unsupportedOutputFormat(ext.isEmpty ? "未知" : ext)
        }
    }
}
