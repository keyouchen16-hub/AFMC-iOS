import SwiftUI
import UIKit

struct DetailView: View {
    let result: SearchResult
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var playerItem: PlayerItem?
    @State private var resolving = false
    @State private var resolveTask: Task<Void, Never>?
    @State private var pendingSource: PlaybackSource?
    @State private var showFiles = false
    @State private var selectedFile: PlaybackFile?
    @State private var copied = false
    @State private var playbackError: String?

    private var magnetText: String? { Links.magnetLink(for: result) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cover
                    Text(result.title)
                        .font(.title3.weight(.semibold))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        infoRow("来源", result.source)
                        infoRow("大小", result.sizeText)
                        infoRow("做种", result.seedsText)
                        infoRow("分类", SearchQuality.category(result))
                        infoRow("发布", result.publishedText)
                        if EvidenceStore.isVerified(result.hash) {
                            infoRow("播放", "已验证起播")
                        }
                        if let hash = result.hash {
                            infoRow("哈希", String(hash.prefix(10)) + "…")
                        }
                    }
                    actions
                }
                .padding()
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $playerItem) { item in
                PlayerView(url: item.url, subtitles: item.subtitles, resumeKey: item.resumeKey)
            }
            .sheet(isPresented: $showFiles, onDismiss: {
                if let file = selectedFile, let source = pendingSource {
                    playerItem = PlayerItem(url: file.url, subtitles: source.subtitles,
                                            resumeKey: "\(source.hash ?? result.id):\(file.id)")
                }
                selectedFile = nil
            }) {
                NavigationStack {
                    List(pendingSource?.files ?? []) { file in
                        Button {
                            selectedFile = file
                            showFiles = false
                        } label: {
                            VStack(alignment: .leading) {
                                Text(file.name)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("选择视频")
                    .toolbar { Button("取消") { showFiles = false } }
                }
            }
            .onDisappear { resolveTask?.cancel() }
            .alert("无法播放", isPresented: Binding(
                get: { playbackError != nil },
                set: { if !$0 { playbackError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(playbackError ?? "")
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let cover = result.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    Color.secondary.opacity(0.08)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.subheadline)
            Text(value).font(.subheadline)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                resolveTask = Task {
                    resolving = true
                    defer { resolving = false }
                    do {
                        let source = try await model.resolvePlayback(for: result)
                        try Task.checkCancellation()
                        if source.files.count > 1 {
                            pendingSource = source
                            showFiles = true
                        } else {
                            playerItem = PlayerItem(url: source.url, subtitles: source.subtitles,
                                                    resumeKey: source.hash ?? result.hash ?? result.id)
                        }
                    } catch is CancellationError {
                        // Closing the detail view cancels metadata resolution.
                    } catch {
                        playbackError = error.localizedDescription
                        if let hash = result.hash ?? Links.magnetHash(result.magnet) {
                            EvidenceStore.record(hash, state: "failed")
                        }
                    }
                }
            } label: {
                Label(resolving ? "解析中…" : "播放", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(resolving)

            if let magnetText {
                Button {
                    UIPasteboard.general.string = magnetText
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制磁力", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let magnetText {
                ShareLink(item: magnetText) {
                    Label("分享磁力", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let detailsURL = result.detailsURL, let url = URL(string: detailsURL) {
                Link(destination: url) {
                    Label("打开来源页", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }
}

struct PlayerItem: Identifiable {
    let id = UUID()
    let url: URL
    var subtitles: [SubtitleTrack] = []
    var resumeKey: String?
}
