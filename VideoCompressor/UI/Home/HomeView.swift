import SwiftUI

struct HomeView: View {
    @EnvironmentObject var temp: TempFileManager
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var session = CompressionSession()
    @State private var selected: [VideoItem] = []
    @State private var profile = CompressionProfile()
    @State private var showPicker = false
    @State private var showProgress = false
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("选择视频", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if selected.isEmpty {
                        EmptyStateView(systemImage: "video.badge.plus", title: "还没有选择视频",
                                       message: "点击上方按钮，从照片图库选择需要压缩的视频（可多选）。")
                            .frame(minHeight: 220)
                    } else {
                        ForEach(selected) { item in
                            VideoInfoCard(item: item) {
                                if let idx = selected.firstIndex(where: { $0.id == item.id }) {
                                    selected.remove(at: idx)
                                }
                            }
                        }
                    }

                    if !selected.isEmpty {
                        CompressionSettingsView(profile: $profile)
                    }

                    if !selected.isEmpty {
                        Button {
                            startCompression()
                        } label: {
                            Text("开始压缩（\(selected.count)）")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("axo")
            .sheet(isPresented: $showPicker) {
                VideoPicker(onPicked: { items in
                    selected.append(contentsOf: items)
                }, temp: temp)
            }
            .fullScreenCover(isPresented: $showProgress) {
                CompressionProgressView(session: session) {
                    showProgress = false
                    selected.removeAll()
                }
            }
            .alert(error?.errorDescription ?? "", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                if let e = error { Text(e.recoverySuggestion) }
            }
        }
        .onAppear { profile.mode = settings.defaultMode }
    }

    private func startCompression() {
        session.run(items: selected, profile: profile)
        showProgress = true
    }
}
