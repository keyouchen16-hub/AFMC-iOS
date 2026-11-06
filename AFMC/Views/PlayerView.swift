import SwiftUI
import AVKit
import UIKit
import Combine
import UniformTypeIdentifiers

final class PlayerUIView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

struct PlayerView: View {
    let url: URL
    var subtitles: [SubtitleTrack] = []
    var resumeKey: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var videoOutput: AVPlayerItemVideoOutput
    @State private var decodedFrame = false
    @State private var observedPlayback: Double = 0
    @State private var previousMediaTime: Double?
    @State private var player: AVPlayer
    @State private var statusObservation: NSKeyValueObservation?
    @State private var cues: [SubtitleCue] = []
    @State private var selectedTrack: SubtitleTrack?
    @State private var currentText = ""
    @State private var subtitlesOn = true
    @State private var isPlaying = true
    @State private var wantsPlayback = true
    @State private var subtitleTask: Task<Void, Never>?
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var dragging = false
    @State private var speed: Double = 1.0
    @State private var lastSaved: Double = -1
    @State private var immersive = false
    @State private var chromeVisible = true
    @State private var showImporter = false
    @State private var connectionSummary: String?
    @State private var waitingSeconds: Double = 0
    @State private var playbackMessage: String?

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let debugHUD = ProcessInfo.processInfo.arguments.contains("--debug-hud")
    @State private var hudText = ""

    init(url: URL, subtitles: [SubtitleTrack] = [], resumeKey: String? = nil) {
        self.url = url
        self.subtitles = subtitles
        self.resumeKey = resumeKey
        let playback = AVPlayer(url: url)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        playback.isMuted = args.contains("--mute") || args.contains(where: { $0.hasPrefix("--auto-") })
        #endif
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playback.currentItem?.add(output)
        _videoOutput = State(initialValue: output)
        _player = State(initialValue: playback)
        _immersive = State(initialValue: ProcessInfo.processInfo.arguments.contains("--immersive"))
    }

    var body: some View {
        NavigationStack { content }
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: player)
                .ignoresSafeArea()

            subtitleOverlay
            if let playbackMessage {
                Text(playbackMessage)
                    .foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding().background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    .padding(24)
            }
            hud
            if !immersive || chromeVisible { controls }
            if immersive && chromeVisible {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation { immersive = false; chromeVisible = true }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .padding(10)
                                .background(.black.opacity(0.5), in: Circle())
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 60)
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if immersive { withAnimation { chromeVisible.toggle() } }
        }
        .statusBarHidden(immersive)
        .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("关闭字幕") {
                        subtitleTask?.cancel()
                        subtitlesOn = false
                        currentText = ""
                    }
                    ForEach(subtitles) { track in
                        Button(track.name) {
                            subtitlesOn = true
                            load(track)
                        }
                    }
                    if SubtitleStore.load(resumeKey) != nil {
                        Button("显示导入的字幕") {
                            subtitleTask?.cancel()
                            if let data = SubtitleStore.load(resumeKey) {
                                cues = SubtitleParser.parse(String(decoding: data, as: UTF8.self))
                                selectedTrack = nil
                                subtitlesOn = true
                            }
                        }
                    }
                    Divider()
                    Button("导入字幕文件…") {
                        showImporter = true
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("关闭") {
                    player.pause()
                    dismiss()
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .data]) { result in
            if case .success(let url) = result {
                importSubtitle(url)
            }
        }
        .task(id: url) {
            while !Task.isCancelled {
                if let summary = try? await EngineClient.connectionSummary(for: url) { connectionSummary = summary }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .onReceive(ticker) { _ in tick() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            saveProgress()
            guard wantsPlayback else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.defaultRate = Float(speed)
            player.play()
            NSLog("AFMC_BACKGROUND play rate=%.1f", player.rate)
        }
    }

    @ViewBuilder
    private var subtitleOverlay: some View {
        if subtitlesOn, !currentText.isEmpty {
            VStack {
                Spacer()
                Text(currentText)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 96)
            }
        }
    }

    @ViewBuilder
    private var hud: some View {
        if debugHUD {
            VStack {
                HStack {
                    Text(hudText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .background(.black.opacity(0.6))
                    Spacer()
                }
                .padding(.top, 60)
                .padding(.leading, 8)
                Spacer()
            }
        }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: wantsPlayback ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white)
                        .font(.title3)
                }
                Text(timeText(position))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                Slider(value: $position, in: 0...max(duration, 0.1)) { editing in
                    dragging = editing
                    if !editing {
                        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                    }
                }
                .tint(.white)
                Text(timeText(duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                Button {
                    withAnimation { immersive = true; chromeVisible = false }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.white)
                }
                Menu {
                    ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button(value == 1.0 ? "正常速度" : String(format: "%.2fx", value)) {
                            speed = value
                            player.defaultRate = Float(value)
                            if wantsPlayback { player.play() }
                        }
                    }
                } label: {
                    Text(String(format: "%.2fx", speed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45))
        }
    }

    private func togglePlay() {
        wantsPlayback.toggle()
        if wantsPlayback {
            if duration > 0 && position >= duration - 0.5 {
                player.seek(to: .zero)
            }
            player.defaultRate = Float(speed)
            player.play()
        } else {
            player.pause()
        }
    }

    private func onAppear() {
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            NSLog("AFMC_AUDIO active")
        } catch {
            NSLog("AFMC_AUDIO error %@", error.localizedDescription)
        }
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

        statusObservation = player.currentItem?.observe(\.status) { item, _ in
            switch item.status {
            case .readyToPlay:
                NSLog("AFMC_PLAYER ready")
                if let key = self.resumeKey, let saved = ProgressStore.load(key), saved > 5 {
                    NSLog("AFMC_RESUME %@ to %.0f", key, saved)
                    let length = item.duration.seconds
                    if !length.isFinite || saved < length - 2 {
                        self.player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
                    }
                }
            case .failed: NSLog("AFMC_PLAYER failed %@", item.error?.localizedDescription ?? "-")
            default: break
            }
        }
        player.play()
        if immersive { chromeVisible = false }

        if let data = SubtitleStore.load(resumeKey),
           let text = String(data: data, encoding: .utf8) {
            cues = SubtitleParser.parse(text)
            selectedTrack = nil
            NSLog("AFMC_SUBTITLE imported cues=%d", cues.count)
        } else if let preferred = preferredTrack() {
            load(preferred)
        }
    }

    private func onDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        saveProgress()
        subtitleTask?.cancel()
        statusObservation = nil
        player.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        if let item = player.currentItem, item.status == .failed {
            playbackMessage = "播放失败：" + (item.error?.localizedDescription ?? "无法解码或连接中断")
            if let key = resumeKey, EvidenceStore.recent(key)?["state"] as? String != "failed" {
                EvidenceStore.record(key, state: "failed")
            }
        } else if wantsPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            waitingSeconds += 0.5
            playbackMessage = "正在缓冲视频…" + (connectionSummary.map { "\n" + $0 } ?? "")
            if waitingSeconds >= 30 && !decodedFrame {
                playbackMessage = "当前资源起播较慢，可返回选择其他版本" + (connectionSummary.map { "\n" + $0 } ?? "")
                if let key = resumeKey, EvidenceStore.recent(key)?["state"] as? String != "failed" {
                    EvidenceStore.record(key, state: "failed")
                }
            }
        } else {
            playbackMessage = nil
        }
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite {
            duration = itemDuration
        }
        if !dragging {
            let seconds = player.currentTime().seconds
            if seconds.isFinite { position = seconds }
        }
        isPlaying = player.timeControlStatus == .playing
        if duration > 0 && position >= duration - 0.1 && !isPlaying {
            wantsPlayback = false
        }
        if let key = resumeKey, isPlaying, abs(position - lastSaved) > 5 {
            ProgressStore.save(key, position)
            lastSaved = position
        }
        if !decodedFrame {
            let frameTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            if videoOutput.hasNewPixelBuffer(forItemTime: frameTime),
               videoOutput.copyPixelBuffer(forItemTime: frameTime, itemTimeForDisplay: nil) != nil {
                decodedFrame = true
            }
        }
        if let previous = previousMediaTime, isPlaying, decodedFrame {
            let advance = position - previous
            if advance > 0 && advance < 2 { observedPlayback += advance }
        }
        previousMediaTime = position
        if let key = resumeKey, observedPlayback >= 5, decodedFrame, isPlaying, EvidenceStore.recent(key)?["state"] as? String != "played" {
            EvidenceStore.markVerified(key)
            NSLog("AFMC_EVIDENCE %@", key)
        }
        updateCue()
        if debugHUD {
            hudText = String(format: "cues=%d t=%.0f rate=%.1f status=%d control=%d sub=%@",
                             cues.count, position, player.rate, player.currentItem?.status.rawValue ?? -1,
                             player.timeControlStatus.rawValue, String(currentText.prefix(12))) + " muted=\(player.isMuted)"
        }
    }

    private func saveProgress() {
        guard let key = resumeKey, position > 0 else { return }
        ProgressStore.save(key, position)
        NSLog("AFMC_PROGRESS %@ at %.0f", key, position)
    }

    private func importSubtitle(_ url: URL) {
        subtitleTask?.cancel()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        cues = SubtitleParser.parse(text)
        selectedTrack = nil
        subtitlesOn = true
        if let key = resumeKey {
            SubtitleStore.save(data, for: key)
        }
        NSLog("AFMC_SUBTITLE import cues=%d", cues.count)
    }

    private func preferredTrack() -> SubtitleTrack? {
        subtitles.first { $0.name.lowercased().contains("zh") || $0.name.lowercased().contains("chi") }
            ?? subtitles.first { $0.name.lowercased().contains("en") }
            ?? subtitles.first
    }

    private func load(_ track: SubtitleTrack) {
        selectedTrack = track
        cues = []
        currentText = ""
        subtitleTask?.cancel()
        subtitleTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: track.url), !Task.isCancelled else { return }
            let parsed = SubtitleParser.parse(String(decoding: data, as: UTF8.self))
            await MainActor.run {
                cues = parsed
                NSLog("AFMC_SUBTITLE %@ cues=%d", track.name, parsed.count)
            }
        }
    }

    private func updateCue() {
        guard subtitlesOn, !cues.isEmpty else {
            currentText = ""
            return
        }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        currentText = cues.first { seconds >= $0.start && seconds <= $0.end }?.text ?? ""
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct DirectLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var item: PlayerItem?
    @State private var torrentResult: SearchResult?

    var body: some View {
        NavigationStack {
            Form {
                Section("磁力、种子或视频链接") {
                    TextField("magnet:… / .torrent / .mp4 / .m3u8", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    Button("播放") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: trimmed) else { return }
                        if let hash = Links.magnetHash(trimmed) {
                            let name = URLComponents(string: trimmed)?.queryItems?.first(where: { $0.name == "dn" })?.value
                            torrentResult = SearchResult(title: name ?? "磁力资源", source: "手动打开", magnet: trimmed, hash: hash)
                        } else if url.pathExtension.lowercased() == "torrent" {
                            torrentResult = SearchResult(title: url.lastPathComponent, source: "手动打开", torrentURL: trimmed)
                        } else {
                            item = PlayerItem(url: url)
                        }
                    }
                    .disabled(!validLink)
                }
            }
            .navigationTitle("打开链接")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(item: $torrentResult) { result in
                DetailView(result: result)
            }
            .sheet(item: $item) { item in
                PlayerView(url: item.url, subtitles: item.subtitles, resumeKey: item.resumeKey)
            }
        }
    }

    private var validLink: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Links.magnetHash(trimmed) != nil { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return false }
        return true
    }

}
