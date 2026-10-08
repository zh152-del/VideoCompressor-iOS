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
/// 本类标注 `@MainActor`：Photos 的授权弹窗与 `performChanges` 回调都必须在主线程，
/// 且 `PHPhotoLibrary.requestAuthorization` 在 @MainActor 上下文直接 `await` 即可（CI 的 Swift 5.10
/// 不支持 `MainActor.run` 的 async 闭包重载，故直接在主线程上下文调用）。
/// 对于 `performChanges` 的异步回调（可能来自后台队列），统一用 `Task { @MainActor in … }`
/// 回到主线程后再 `resume` continuation，避免跨线程/执行器不匹配导致的真机闪退。
@MainActor
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()

    private init() {}

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
    /// - Parameters:
    ///   - fileURL: 待保存的视频文件（应为本地可读的 MP4/MOV/M4V）。
    ///   - originalFilename: 保存到相册时的文件名（如 "IMG_1234__VC__.mp4"，用于 __VC__ 压缩标记）。
    ///     通过 PHAssetCreationRequest 的 originalFilename 实现——保存时命名，零重编码、零内容改动。
    /// - Returns: 新保存资源的 `localIdentifier`，供后续定位或删除。
    /// - Throws: 权限被拒/受限、输出文件缺失/为空/格式不支持、图库写入失败等。
    func saveVideo(at fileURL: URL, originalFilename: String? = nil) async throws -> String {
        // 0. 保存前校验输出文件（存在 / 可读 / 大小 > 0 / 类型受支持）
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

        // 3. 执行保存：创建请求可指定 originalFilename（__VC__ 标记），change block 内直接拿到 placeholder id
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var placeholderID: String?
            PHPhotoLibrary.shared().performChanges({
                if let name = originalFilename, !name.isEmpty {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: fileURL, options: options)
                    placeholderID = request.placeholderForCreatedAsset?.localIdentifier
                } else {
                    let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                    placeholderID = request?.placeholderForCreatedAsset?.localIdentifier
                }
            }) { success, error in
                // 通过主线程 Task 回到主线程后再 resume，避免跨线程/执行器问题
                Task { @MainActor in
                    if success, let id = placeholderID, !id.isEmpty {
                        // 【保存确认】重新 fetch 对应 PHAsset，确认资源真实存在于图库
                        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                        if fetched.count > 0 {
                            if let name = originalFilename {
                                AppLog.mark("Add __VC__：成品保存为 \(name)")
                            }
                            cont.resume(returning: id)
                        } else {
                            cont.resume(throwing: AppError.saveToPhotoFailed("保存已提交但在图库中未找到对应资源"))
                        }
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

    // MARK: - 原视频导出（PHAsset → 本地文件，供压缩链路使用）

    /// 将相册视频资源导出为本地文件（流式写出到临时目录，不整段载入内存）。
    func exportVideo(from asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first else {
            throw AppError.noVideoTrack
        }
        let ext = (resource.originalFilename as NSString).pathExtension
        let url = TempFileManager.shared.newOutputURL(ext: ext.isEmpty ? "mov" : ext)
        return try await withCheckedThrowingContinuation { cont in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = false
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { error in
                Task { @MainActor in
                    if error != nil {
                        cont.resume(throwing: AppError.videoReadFailed)
                    } else {
                        cont.resume(returning: url)
                    }
                }
            }
        }
    }

    // MARK: - 删除原视频（仅此处申请 readWrite）

    /// 批量删除原始资源（一次性 performChanges，系统只弹一次确认）。
    /// - Parameters:
    ///   - identifiers: 仅允许传入「对应压缩视频已成功保存到 Photos」的原视频标识。
    /// - Returns: 删除失败的标识数组（如系统确认被拒/部分失败），调用方保留状态供重试。
    func deleteOriginals(localIdentifiers: [String]) async -> (deleted: [String], failed: [String]) {
        // 过滤无效标识 + 只删除图库中真实存在的资源
        let valid = localIdentifiers.filter { !$0.isEmpty }
        guard !valid.isEmpty else { return ([], []) }

        // 删除需要 readWrite 权限；权限不足直接整体失败，不假装成功
        var status = readWriteStatus()
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            return ([], valid)   // 全部标记失败，保留待删除状态
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: valid, options: nil)
        guard assets.count > 0 else { return (valid, []) } // 原片已不在图库，视为已删除

        let targetIDs: [String] = (0..<assets.count).compactMap { assets.object(at: $0).localIdentifier }

        let result: (deleted: [String], failed: [String]) = await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                Task { @MainActor in
                    if success {
                        AppLog.delete("批量删除成功：\(targetIDs.count) 个原视频")
                        cont.resume(returning: (targetIDs, []))
                    } else {
                        AppLog.delete("批量删除失败：\(error?.localizedDescription ?? "未知")")
                        cont.resume(returning: ([], targetIDs))
                    }
                }
            }
        }
        return result
    }

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
                Task { @MainActor in
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
