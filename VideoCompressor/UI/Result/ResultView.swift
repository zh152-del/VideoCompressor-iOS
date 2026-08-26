import SwiftUI

/// 单个压缩结果详情与操作（保存到照片 / 删除原视频 / 继续压缩）。
struct ResultView: View {
    let result: CompressionResult
    var onContinue: (() -> Void)? = nil

    @State private var savedID: String? = nil
    @State private var busy = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var settings: SettingsStore

    private var isSaved: Bool { (savedID ?? "").isEmpty == false }
    private var canDeleteOriginal: Bool { (result.item.localIdentifier ?? "").isEmpty == false }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                summaryCard
                detailsCard
                actionsCard
            }
            .padding()
        }
        .navigationTitle("压缩结果")
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: { Text(alertMessage) }
    }

    private var summaryCard: some View {
        let savedAmount = result.item.fileSizeBytes - result.outputSizeBytes
        let ratio = result.item.fileSizeBytes > 0 ? Double(savedAmount) / Double(result.item.fileSizeBytes) : 0
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text("原始大小").font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.bytes(result.item.fileSizeBytes)).font(.title3).fontWeight(.semibold)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("压缩后").font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.bytes(result.outputSizeBytes)).font(.title3).fontWeight(.semibold)
                }
            }
            Text("节省 \(Formatters.bytes(savedAmount))（\(Formatters.savedPercent(ratio))）")
                .font(.headline).foregroundStyle(.green)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var detailsCard: some View {
        VStack(spacing: 8) {
            InfoRow(title: "原始分辨率", value: "\(result.item.width)×\(result.item.height)")
            InfoRow(title: "压缩后分辨率", value: "\(result.outputWidth)×\(result.outputHeight)")
            InfoRow(title: "原始编码", value: result.item.codecDescription)
            InfoRow(title: "新编码", value: result.outputCodec)
            InfoRow(title: "视频时长", value: Formatters.time(result.durationSeconds))
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var actionsCard: some View {
        VStack(spacing: 12) {
            Button { save() } label: {
                Label(isSaved ? "已保存到照片" : "保存到照片", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(busy || isSaved)

            if canDeleteOriginal {
                Button { deleteOriginal() } label: {
                    Label("删除原视频", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemFill))
                        .foregroundStyle(isSaved ? Color.red : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(busy || !isSaved)
            }

            if let onContinue {
                Button {
                    TempFileManager.shared.remove(result.outputURL)
                    onContinue()
                } label: {
                    Label("继续压缩", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func save() {
        busy = true
        Task {
            do {
                // 1) 先保存压缩视频（仅申请 addOnly 权限）
                let id = try await PhotoLibraryService.shared.saveVideo(at: result.outputURL)
                savedID = id
                // 2) 保存成功后才写历史；此时输出文件使命完成，可清理
                history.add(result.historyEntry(savedID: id))
                TempFileManager.shared.remove(result.outputURL)

                // 3) 仅当开启「保存后删除原视频」且原片存在时，才删除原片。
                //    删除失败仅提示，不回滚已保存状态、不崩溃。
                var message = "压缩后的视频已保存到你的照片图库。"
                if settings.deleteOriginalAfterSave, let orig = result.item.localIdentifier {
                    do {
                        try await PhotoLibraryService.shared.deleteOriginal(localIdentifier: orig)
                        message = "压缩后的视频已保存，原视频已删除。"
                    } catch {
                        if let e = error as? AppError {
                            message = "压缩视频已保存，但删除原视频失败：\(e.recoverySuggestion)"
                        } else {
                            message = "压缩视频已保存，但删除原视频失败：\(error.localizedDescription)"
                        }
                    }
                }
                alertTitle = "保存成功"
                alertMessage = message
            } catch {
                // 保存失败：不删输出文件、不删原视频、不写历史为「已保存」、不崩溃。
                if let e = error as? AppError {
                    alertTitle = e.errorDescription
                    alertMessage = e.recoverySuggestion
                } else {
                    alertTitle = "保存失败"
                    alertMessage = error.localizedDescription
                }
            }
            busy = false
            showAlert = true
        }
    }

    private func deleteOriginal() {
        guard let orig = result.item.localIdentifier else { return }
        busy = true
        Task {
            do {
                try await PhotoLibraryService.shared.deleteOriginal(localIdentifier: orig)
                alertTitle = "原视频已删除"
                alertMessage = "压缩视频已保存，原视频已从照片图库中移除。"
            } catch {
                if let e = error as? AppError {
                    alertTitle = e.errorDescription
                    alertMessage = e.recoverySuggestion
                }
            }
            busy = false
            showAlert = true
        }
    }
}
