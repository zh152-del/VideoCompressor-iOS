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
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }) { success, error in
                if success {
                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    options.fetchLimit = 1
                    let fetch = PHAsset.fetchAssets(with: .video, options: options)
                    cont.resume(returning: fetch.firstObject?.localIdentifier ?? "")
                } else {
                    cont.resume(throwing: AppError.saveToPhotoFailed(error?.localizedDescription ?? "未知错误"))
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
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: AppError.deleteOriginalFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }
    }
}
