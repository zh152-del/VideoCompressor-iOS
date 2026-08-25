import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 系统照片选择器（支持多选）。选中后把视频复制到应用临时目录并读取元信息。
struct VideoPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onPicked: ([VideoItem]) -> Void
    let temp: TempFileManager

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 0                  // 0 = 不限制，可多选
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }
            Task { await parent.process(results) }
        }
    }

    private func process(_ results: [PHPickerResult]) async {
        var items: [VideoItem] = []
        for result in results {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { continue }
            do {
                let url = try await loadVideoURL(from: provider)
                let meta = try? await VideoInfoReader.readInfo(at: url)
                let thumbURL = temp.newThumbnailURL()
                try? await VideoInfoReader.generateThumbnail(from: url, to: thumbURL)
                let title = provider.suggestedName ?? "视频 \(items.count + 1)"
                let item = VideoItem(
                    localIdentifier: result.assetIdentifier,
                    sourceURL: url,
                    title: title,
                    durationSeconds: meta?.durationSeconds ?? 0,
                    fileSizeBytes: meta?.fileSizeBytes ?? 0,
                    width: meta?.width ?? 0,
                    height: meta?.height ?? 0,
                    fps: meta?.fps ?? 0,
                    codecDescription: meta?.codecDescription ?? "未知",
                    thumbnailURL: thumbURL,
                    creationDate: meta?.creationDate
                )
                items.append(item)
            } catch {
                continue
            }
        }
        if !items.isEmpty { onPicked(items) }
    }

    private func loadVideoURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                if let url = url {
                    // PHPicker 给的是沙盒临时文件，复制到本应用临时目录以掌控生命周期
                    let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                    let dest = self.temp.newOutputURL(ext: ext)
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: url, to: dest)
                        cont.resume(returning: dest)
                    } catch {
                        cont.resume(throwing: error)
                    }
                } else {
                    cont.resume(throwing: error ?? AppError.videoReadFailed)
                }
            }
        }
    }
}
