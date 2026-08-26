import Foundation
import Photos
import Combine

/// 照片图库权限与读写操作。关键约束：「先保存成功，再删除原片」。
@MainActor
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// 保存视频文件到图库，返回新资源的 localIdentifier（用于后续删除原片或定位）。
    func saveVideo(at fileURL: URL) async throws -> String {
        // 首次使用时 status 为 .notDetermined，必须先请求授权，否则会无故抛"权限被拒绝"
        var status = authorizationStatus()
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        guard status == .authorized || status == .limited else {
            throw AppError.photoPermissionDenied
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AppError.saveToPhotoFailed("压缩输出文件不存在")
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            // 在 changes block 内直接拿到 placeholder 的 localIdentifier，避免保存后反查相册不可靠
            var placeholderID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                placeholderID = request?.placeholderForCreatedAsset?.localIdentifier
            }) { success, error in
                // 整个类标记为 @MainActor，continuation 必须在主 actor 上 resume，
                // 用 MainActor.run 包装可防止真机上因隔离违规闪退。
                MainActor.run {
                    if success, let id = placeholderID, !id.isEmpty {
                        cont.resume(returning: id)
                    } else if let error = error {
                        cont.resume(throwing: AppError.saveToPhotoFailed(error.localizedDescription))
                    } else {
                        cont.resume(throwing: AppError.saveToPhotoFailed("保存视频失败"))
                    }
                }
            }
        }
    }

    /// 仅在保存成功后调用：删除原始资源。空标识则直接返回（无原片可删）。
    func deleteOriginal(localIdentifier: String) async throws {
        guard !localIdentifier.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard assets.count > 0 else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                MainActor.run {
                    if success {
                        cont.resume()
                    } else {
                        cont.resume(throwing: AppError.deleteOriginalFailed(error?.localizedDescription ?? "删除原视频失败"))
                    }
                }
            }
        }
    }
}
