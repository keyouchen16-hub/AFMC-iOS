import SwiftUI
import AVFoundation

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: SearchResult?
    @State private var showSources = false
    @State private var showSettings = false
    @State private var sidebarOpen = false
    @State private var showReports = false
    @State private var showDirect = false
    @State private var playerItem: PlayerItem?
    @FocusState private var searchFocused: Bool
    @State private var expandedGroups: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                if !model.results.isEmpty {
                    filterBar
                    if let notice = model.sortNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(AppPalette.accent.opacity(0.07))
                    }
                }
                Group {
                    if model.results.isEmpty {
                        emptyState
                    } else {
                        resultList
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { value in
                    guard !sidebarOpen, value.translation.width > 60,
                          value.translation.width > abs(value.translation.height) * 1.5 else { return }
                    searchFocused = false
                    withAnimation(.easeOut(duration: 0.2)) { sidebarOpen = true }
                })
            }
            .background(AppPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.isSearching {
                        statusBar
                            .background(.regularMaterial, in: Capsule())
                    }
                    searchInput
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .sheet(item: $selected) { result in
                DetailView(result: result)
                    .environmentObject(model)
            }
            .sheet(isPresented: $showSources) {
                SettingsView(sourcesOnly: true).environmentObject(model)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .sheet(isPresented: $showReports) {
                ReportView(reports: model.reports)
            }
            .sheet(isPresented: $showDirect) {
                DirectLinkView()
            }
            .sheet(item: $playerItem) { item in
                PlayerView(url: item.url, subtitles: item.subtitles, resumeKey: item.resumeKey)
            }
            .task {
                await autoSearchIfRequested()
            }
            .onChange(of: model.libraryPlayURL) { _, url in
                guard let url else { return }
                showSettings = false
                playerItem = PlayerItem(url: url)
                model.libraryPlayURL = nil
            }
        }
        .tint(AppPalette.accent)
        .sensoryFeedback(.selection, trigger: sidebarOpen)
        .sensoryFeedback(.selection, trigger: model.sortOption)
        .sensoryFeedback(.selection, trigger: model.categoryFilter)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: sidebarOpen)
        .overlay(alignment: .leading) {
            if sidebarOpen { sidebar }
        }
    }

    /// 调试/验收用：
    /// `--auto-query <关键词>` 启动后自动搜索一次；
    /// `--auto-open <标题片段>` 搜索后打开匹配项详情；
    /// `--auto-play <视频地址>` 直接打开播放器。
    private func autoSearchIfRequested() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-fixture-results") {
            model.query = "手势测试"
            model.results = (0..<30).map { index in
                SearchResult(title: "手势测试资源 \(index)", source: "本地测试", category: "影视")
            }
            return
        }
        if let i = args.firstIndex(of: "--auto-probe-hashes"), i + 1 < args.count {
            model.query = "蜘蛛侠同哈希对照"
            let hashes = args[i + 1].split(separator: ",").compactMap { Links.normalizeHash(String($0)) }
            await probeTopResults(hashes.enumerated().map { offset, hash in
                SearchResult(title: "蜘蛛侠原排名 \(offset + 1)", source: "同哈希对照",
                             magnet: "magnet:?xt=urn:btih:\(hash)", hash: hash)
            })
            return
        }
        if args.contains("--auto-network-probe") {
            await networkProbe()
            return
        }
        if let i = args.firstIndex(of: "--auto-probe-link"), i + 1 < args.count {
            model.query = "公开测试样本"
            await probeTopResults([SearchResult(title: "Big Buck Bunny", source: "WebTorrent", torrentURL: args[i + 1])])
            return
        }
        if let index = args.firstIndex(of: "--auto-detail-torrent"), index + 1 < args.count {
            selected = SearchResult(title: "多文件播放验收", source: "本地验收", torrentURL: args[index + 1])
            return
        }
        if let index = args.firstIndex(of: "--mark-evidence"), index + 1 < args.count {
            EvidenceStore.markVerified(args[index + 1])
        }
        if let index = args.firstIndex(of: "--auto-query"), index + 1 < args.count {
            model.query = args[index + 1]
            await model.search()
            let first = model.results.first?.title ?? "-"
            NSLog("AFMC_RESULT query=%@ count=%d sources=%d first=%@", model.query, model.results.count, model.reports.count, first)
            if args.contains("--sort-audit") {
                let original = model.sortOption
                var audit: [[String: Any]] = []
                for option in SortOption.allCases {
                    model.sortOption = option
                    audit.append(["sort": option.rawValue, "notice": model.sortNotice ?? "",
                                  "count": model.displayedResults.count,
                                  "top": model.displayedResults.prefix(10).map { row -> [String: Any] in
                        ["title": row.title, "source": row.source, "year": row.contentYear as Any? ?? NSNull(),
                         "upload": row.uploadDate?.ISO8601Format() as Any? ?? NSNull(),
                         "verified": EvidenceStore.isVerified(row.hash ?? Links.magnetHash(row.magnet))]
                    }])
                }
                if let data = try? JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]),
                   let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? data.write(to: directory.appendingPathComponent("sort-audit.json"))
                }
                model.sortOption = original
            }
            if let sortIndex = args.firstIndex(of: "--auto-sort"), sortIndex + 1 < args.count,
               let option = SortOption(rawValue: args[sortIndex + 1]) { model.sortOption = option }
            if args.contains("--auto-probe-top") {
                await probeTopResults()
            }
            if let openIndex = args.firstIndex(of: "--auto-open"), openIndex + 1 < args.count {
                let needle = args[openIndex + 1]
                selected = model.results.first {
                    $0.title.localizedCaseInsensitiveContains(needle)
                }
            }
        }
        if let index = args.firstIndex(of: "--auto-play"), index + 1 < args.count,
           let url = URL(string: args[index + 1]) {
            playerItem = PlayerItem(url: url)
        }
        if args.contains("--show-sidebar") { sidebarOpen = true }
        if args.contains("--show-settings") { showSettings = true }
        if args.contains("--show-reports") { showReports = true }
        if args.contains("--auto-host-test") { await model.testHost() }
        if let index = args.firstIndex(of: "--auto-torrent"), index + 1 < args.count {
            do {
                let source = try await EngineClient.resolve(link: args[index + 1])
                NSLog("AFMC_TORRENT_PLAY %@", source.url.absoluteString)
                playerItem = PlayerItem(url: source.url, subtitles: source.subtitles)
            } catch {
                NSLog("AFMC_TORRENT_ERROR %@", error.localizedDescription)
            }
        }
        if let index = args.firstIndex(of: "--auto-magnet"), index + 1 < args.count {
            let probe = SearchResult(title: "debug", source: "debug", magnet: args[index + 1])
            if let seedIndex = args.firstIndex(of: "--seed-progress"), seedIndex + 1 < args.count,
               let seconds = Double(args[seedIndex + 1]),
               let hash = Links.magnetHash(probe.magnet) {
                ProgressStore.save(hash, seconds)
                NSLog("AFMC_SEED_PROGRESS %@ %.0f", hash, seconds)
            }
            do {
                let source = try await model.resolvePlayback(for: probe)
                NSLog("AFMC_PLAY %@", source.url.absoluteString)
                playerItem = PlayerItem(url: source.url, subtitles: source.subtitles,
                                        resumeKey: Links.magnetHash(probe.magnet))
            } catch {
                NSLog("AFMC_PLAY_ERROR %@", error.localizedDescription)
            }
        }
        #endif
    }

    #if DEBUG
    @MainActor private func networkProbe() async {
        var records: [[String: Any]] = []
        do {
            let source = try await EngineClient.resolve(link: "https://webtorrent.io/torrents/big-buck-bunny.torrent")
            let urls = [source.url, URL(string: "https://webtorrent.io/torrents/Big%20Buck%20Bunny/Big%20Buck%20Bunny.mp4")!]
            for url in urls {
                let start = Date()
                var result: [String: Any] = ["url": url.absoluteString]
                let session = URLSession(configuration: .ephemeral)
                var request = URLRequest(url: url)
                request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
                request.timeoutInterval = 12
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    result["status"] = (response as? HTTPURLResponse)?.statusCode ?? 0
                    result["mime"] = response.mimeType ?? ""
                    var count = 0
                    for try await _ in bytes { count += 1; if count >= 4096 { break } }
                    result["bytes"] = count
                } catch { result["error"] = error.localizedDescription }
                session.invalidateAndCancel()
                result["seconds"] = Date().timeIntervalSince(start)
                records.append(result)
            }
        } catch { records.append(["resolveError": error.localizedDescription]) }
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("network-probe.json")
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path, options: .atomic)
        }
    }

    @MainActor private func probeTopResults(_ supplied: [SearchResult]? = nil) async {
        let rows = supplied ?? Array(model.displayedResults.prefix(3))
        let probeQuery = model.query
        var records: [[String: Any]] = []
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playback-probe.json")
        func save() {
            let report: [String: Any] = ["query": probeQuery, "date": ISO8601DateFormatter().string(from: Date()),
                                       "device": UIDevice.current.model, "results": records]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: destination, options: .atomic)
            }
        }
        for (index, row) in rows.enumerated() {
            let start = Date()
            var record: [String: Any] = ["rank": index + 1, "title": row.title, "source": row.source,
                                        "hash": row.hash ?? "", "muted": true, "state": "resolving"]
            records.append(record); save()
            model.statusText = "静音验证第 \(index + 1)/\(rows.count) 条"
            do {
                let source: PlaybackSource
                if let direct = row.playableDirectURL {
                    source = PlaybackSource(url: direct)
                } else if let link = Links.magnetLink(for: row) ?? row.torrentURL {
                    try EmbeddedEngine.shared.ensureStarted()
                    source = try await EngineClient.resolve(link: link,
                        baseURL: URL(string: "http://127.0.0.1:8099")!, session: .shared, timeout: 15)
                } else { source = try await model.resolvePlayback(for: row) }
                record["metadataSeconds"] = Date().timeIntervalSince(start)
                record["videoURL"] = source.url.absoluteString
                record["files"] = source.files.map { $0.name }
                record["resolvedHash"] = source.hash ?? ""
                let item = AVPlayerItem(url: source.url)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.play()
                let deadline = Date().addingTimeInterval(25)
                var decoded = false
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if output.hasNewPixelBuffer(forItemTime: time),
                       output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                        decoded = true
                        record["firstFrameSeconds"] = Date().timeIntervalSince(start)
                        break
                    }
                    if item.status == .failed { break }
                }
                record["state"] = decoded ? "decoded_frame" : "no_frame_within_25s"
                record["playerError"] = item.error?.localizedDescription ?? ""
                record["playerStatus"] = item.status.rawValue
                record["waitingReason"] = player.reasonForWaitingToPlay?.rawValue ?? ""
                if let hash = source.hash {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:8099/torrents")!)
                    request.httpMethod = "POST"
                    request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "get", "hash": hash])
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 3
                    if let (data, _) = try? await URLSession.shared.data(for: request),
                       let state = try? JSONSerialization.jsonObject(with: data) { record["torrentState"] = state }
                }
                player.pause(); player.replaceCurrentItem(with: nil)
            } catch { record["state"] = "resolve_failed"; record["error"] = error.localizedDescription }
            record["elapsedSeconds"] = Date().timeIntervalSince(start)
            if let key = row.hash ?? Links.magnetHash(row.magnet) ?? (record["resolvedHash"] as? String) {
                EvidenceStore.record(key, state: record["state"] as? String == "decoded_frame" ? "decoded" : "failed",
                                     seconds: record["firstFrameSeconds"] as? Double)
            }
            records[index] = record; save()
            EmbeddedEngine.shared.stop()
        }
        model.statusText = "静音验证完成 · 见实测报告"
    }
    #endif

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                searchFocused = false
                withAnimation(.easeOut(duration: 0.2)) { sidebarOpen = true }
            } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }
                .accessibilityLabel("打开菜单")
            Spacer()
            if !model.results.isEmpty {
                Text("\(model.displayedResults.count) 条结果")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Menu {
                Picker("排序", selection: $model.sortOption) {
                    ForEach(SortOption.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.sortOption.label).font(.subheadline)
                    Image(systemName: "chevron.down").font(.caption2)
                }.frame(minHeight: 44)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { withAnimation { sidebarOpen = false } }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image("BrandLogo").resizable().scaledToFit()
                            .frame(width: 48, height: 48)
                            .accessibilityLabel("AFMC 标志")
                        Spacer()
                        Button { withAnimation { sidebarOpen = false } } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }.accessibilityLabel("关闭菜单")
                    }
                    .padding(.bottom, 20)
                    sidebarButton("搜索", icon: "magnifyingglass") { searchFocused = true }
                    sidebarButton("搜索源", icon: "square.stack.3d.up") { showSources = true }
                    sidebarButton("链接播放", icon: "play.rectangle") { showDirect = true }
                    if !model.reports.isEmpty {
                        sidebarButton("本次来源状态", icon: "waveform.path.ecg") { showReports = true }
                    }
                    Spacer()
                    Divider()
                    sidebarButton("设置", icon: "slider.horizontal.3") { showSettings = true }
                }
                .padding(20)
                .frame(width: min(300, geometry.size.width * 0.82), height: geometry.size.height)
                .background(AppPalette.sidebar)
                .transition(reduceMotion ? .opacity : .move(edge: .leading))
                .gesture(DragGesture().onEnded { value in
                    if value.translation.width < -60 { withAnimation { sidebarOpen = false } }
                })
            }
        }
    }

    private func sidebarButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            sidebarOpen = false
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.body).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 14)
                .foregroundStyle(title == "搜索" ? AppPalette.accent : Color.primary)
                .background(title == "搜索" ? AppPalette.accent.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(model.categories, id: \.self) { category in
                    Button { model.categoryFilter = category } label: {
                        VStack(spacing: 10) {
                            Text(category).font(.subheadline.weight(.medium))
                            Rectangle().fill(model.categoryFilter == category ? AppPalette.accent : .clear).frame(height: 2)
                        }
                        .foregroundStyle(model.categoryFilter == category ? AppPalette.accent : .secondary)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 24).padding(.top, 12)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var resultList: some View {
        List {
            ForEach(model.groupedResults) { group in
                Section {
                    if group.isGrouped {
                        DisclosureGroup(isExpanded: expansionBinding(group.id)) {
                            ForEach(group.results) { result in
                                row(for: result)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                if let cover = group.results.compactMap(\.coverURL).first, let url = URL(string: cover) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color.clear }
                                    .frame(width: 48, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                Text(group.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                Text("\(group.results.count) 个版本 · \(group.results.count > 0 ? group.results[0].sizeText : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let first = group.results.first, let detail = model.sortOption.detail(for: first) {
                                    Text(detail).font(.caption).foregroundStyle(AppPalette.accent)
                                }
                                }
                            }.padding(.vertical, 6)
                        }
                    } else if let result = group.results.first {
                        row(for: result)
                    }
                }
                .listRowBackground(AppPalette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
    }

    private func row(for result: SearchResult) -> some View {
        Button {
            selected = result
        } label: {
            ResultRow(result: result, sortOption: model.sortOption)
        }
        .buttonStyle(.plain)
    }

    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { expanded in
                if expanded { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if model.isSearching {
                ProgressView()
                Text("搜索中…").foregroundStyle(.secondary)
            } else if !model.reports.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var searchInput: some View {
        if #available(iOS 26.0, *) {
            searchInputContent.glassEffect(.regular, in: Capsule())
        } else {
            searchInputContent.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    private var searchInputContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("搜索资源")
                .onSubmit {
                    searchFocused = false
                    Task { await model.search() }
                }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Button {
                searchFocused = false
                Task { await model.search() }
            } label: {
                Image(systemName: "arrow.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.black : .white)
                    .frame(width: 40, height: 40)
                    .background(AppPalette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSearching)
            .accessibilityLabel("开始搜索")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 56)

    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(model.isSearching || model.results.isEmpty
                 ? model.statusText
                 : "\(model.displayedResults.count)/\(model.results.count) 条 · \(model.sortOption.label)")
                .font(.footnote)
                .lineLimit(1)
            Spacer()
            if !model.reports.isEmpty {
                Button("来源") { showReports = true }
                    .font(.footnote)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct ResultRow: View {
    let result: SearchResult
    var sortOption: SortOption = .relevance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let cover = result.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.08)
                }
                .frame(width: 48, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(SearchQuality.displayTitle(result.title))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if EvidenceStore.isVerified(result.hash) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(AppPalette.accent)
                    }
                }
                HStack(spacing: 8) {
                    Label(result.source, systemImage: "dot.radiowaves.left.and.right")
                    Label(result.sizeText, systemImage: "internaldrive")
                    Label(result.seedsText, systemImage: "arrow.up.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(spacing: 8) {
                    Text(SearchQuality.category(result))
                    let summary = SearchQuality.technicalSummary(result)
                    if !summary.isEmpty { Text(summary) }
                    Text(EvidenceStore.label(result.hash ?? Links.magnetHash(result.magnet)))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let detail = sortOption.detail(for: result) {
                    Text(detail).font(.caption).foregroundStyle(AppPalette.accent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ReportView: View {
    let reports: [SourceReport]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(reports) { report in
                    HStack(spacing: 8) {
                        Text(report.name).font(.subheadline)
                        Spacer()
                        Text(report.statusText)
                            .font(.caption)
                            .foregroundStyle(report.error == nil ? Color.secondary : Color.red)
                            .lineLimit(1)
                        Text(String(format: "%.1fs", report.seconds))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("搜索源状态")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
