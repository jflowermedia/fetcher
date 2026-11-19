import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(Updater.self) private var updater

    @State private var urlText = ""
    @State private var info: VideoInfo?
    @State private var fetchedURL: String?
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var fetchTask: Task<Void, Never>?
    /// Set when the field holds more than one link: they're queued without fetching info.
    @State private var batchURLs: [String] = []

    @AppStorage("mode") private var mode: DownloadMode = .video
    @AppStorage("videoHeight") private var videoHeight = 0  // 0 = best
    @AppStorage("preferH264") private var preferH264 = true
    @AppStorage("audioFormat") private var audioFormat: AudioFormat = .mp3
    @AppStorage("audioBitrate") private var audioBitrate: AudioBitrate = .k320
    @AppStorage("videoOutput") private var videoOutput: VideoOutput = .mp4Remux
    @AppStorage("audioOutput") private var audioOutput: AudioOutput = .original
    @AppStorage("outputDir") private var outputDirPath = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    @AppStorage("embedMetadata") private var embedMetadata = true
    @AppStorage("embedThumbnail") private var embedThumbnail = true
    @AppStorage("embedSubs") private var embedSubs = false
    @AppStorage("embedChapters") private var embedChapters = true
    @AppStorage("watchClipboard") private var watchClipboard = true
    @AppStorage("preciseCuts") private var preciseCuts = true
    @AppStorage("convertForQuickTime") private var convertForQuickTime = true
    @State private var wholePlaylist = false
    @State private var selectedFormatID: String?
    @State private var clipEnabled = false
    @State private var clipStart = ""
    @State private var clipEnd = ""
    @State private var lastPasteboardChange = -1
    @State private var isDropTargeted = false

    private let ytdlpMissing = YtDlp.ytdlpPath == nil
    private let ffmpegMissing = YtDlp.ffmpegPath == nil

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 14) {
                if ytdlpMissing || ffmpegMissing { missingBanner }
                updateBanner
                urlBar
                infoCard
                if info != nil || !batchURLs.isEmpty {
                    Picker("Mode", selection: $mode) {
                        ForEach(availableModes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    modeOptions
                    optionsBar
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(minHeight: 300, maxHeight: .infinity, alignment: .top)

            DownloadsView()
                .frame(minHeight: 140, idealHeight: 240)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addLinks(urls.map(\.absoluteString))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onChange(of: urlText) { _, new in scheduleFetch(new) }
        .onChange(of: info?.id) { _, _ in
            selectedFormatID = nil
            clipEnabled = false
            if info?.isPlaylist == true && mode == .formats { mode = .video }
        }
        .onChange(of: batchURLs.isEmpty) { _, _ in
            if !batchURLs.isEmpty && mode == .formats { mode = .video }
        }
        .onAppear(perform: checkPasteboard)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPasteboard()
        }
        .task { await updater.checkVersion() }
    }

    // MARK: Sections

    private var missingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(ytdlpMissing ? "yt-dlp wasn't found." : "ffmpeg wasn't found — merging, MP4 and audio conversion won't work.")
                    .fontWeight(.medium)
                Text("Install with Homebrew:  brew install yt-dlp ffmpeg").font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var updateBanner: some View {
        if updater.isUpdating || updater.message != nil || (updater.isOutdated && !updater.dismissed) {
            HStack(spacing: 10) {
                if updater.isUpdating {
                    ProgressView().controlSize(.small)
                    Text("Updating yt-dlp… this can take a minute.")
                } else if let message = updater.message {
                    Image(systemName: message.hasPrefix("Update failed") ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.hasPrefix("Update failed") ? .red : .green)
                    Text(message).textSelection(.enabled)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
                    Text("yt-dlp \(updater.version ?? "") is \(updater.ageInDays ?? 0) days old — YouTube downloads may fail.")
                }
                Spacer()
                if !updater.isUpdating && updater.message == nil {
                    Button("Update") { Task { await updater.update() } }
                        .disabled(manager.hasActiveJobs)
                        .help(manager.hasActiveJobs ? "Wait for downloads to finish first" : "Upgrade yt-dlp")
                }
                if !updater.isUpdating {
                    Button {
                        updater.dismissed = true
                        updater.message = nil
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var urlBar: some View {
        HStack {
            TextField("Paste a link, or several…", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit { fetch(force: true) }
            Button {
                if let s = NSPasteboard.general.string(forType: .string) {
                    urlText = Self.extractLinks(s).joined(separator: " ")
                }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .controlSize(.large)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            if isFetching {
                ProgressView().controlSize(.small).frame(width: 28)
            } else {
                Button { fetch(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .controlSize(.large)
                    .disabled(trimmedURL.isEmpty || !batchURLs.isEmpty)
                    .help("Fetch info")
            }
        }
    }

    @ViewBuilder
    private var infoCard: some View {
        if !batchURLs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(batchURLs.count) links", systemImage: "link").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(batchURLs, id: \.self) { url in
                            Text(url).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                Text("Each link is downloaded with the settings below.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } else if let fetchError {
            Label(fetchError, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if let info {
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: thumbnailURL(info)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.displayTitle).font(.headline).lineLimit(2).textSelection(.enabled)
                    if let author = info.author { Text(author).foregroundStyle(.secondary) }
                    HStack(spacing: 10) {
                        if info.isPlaylist {
                            Label("Playlist · \(info.entryCount) videos", systemImage: "list.bullet")
                        } else {
                            if !Fmt.duration(info.duration).isEmpty {
                                Label(Fmt.duration(info.duration), systemImage: "clock")
                            }
                            Label("\(info.mediaFormats.count) formats", systemImage: "square.stack")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } else if !isFetching {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Paste or drop a link to get started").foregroundStyle(.secondary)
                if watchClipboard {
                    Text("Links you copy are filled in automatically when you switch to ytdl.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                VStack(spacing: 4) {
                    Text("Built by JFlowerMedia")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Link("jflowermedia.com", destination: AppInfo.website)
                        Text("·").foregroundStyle(.tertiary)
                        Link("Instagram", destination: AppInfo.instagram)
                    }
                    .font(.caption)
                }
                .padding(.top, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    @ViewBuilder
    private var modeOptions: some View {
        switch mode {
        case .video:
            Form {
                Picker("Quality", selection: $videoHeight) {
                    Text("Best available").tag(0)
                    ForEach(heightChoices, id: \.self) { h in Text(heightLabel(h)).tag(h) }
                }
                Toggle("Prefer H.264 (plays everywhere, incl. QuickTime)", isOn: $preferH264)
                Toggle("Convert to HEVC when needed, so it plays in QuickTime and QuickLook", isOn: $convertForQuickTime)
                if (videoHeight == 0 || videoHeight > 1080) && (maxHeight > 1080 || !batchURLs.isEmpty) {
                    Text(convertForQuickTime
                         ? "Above 1080p YouTube only offers VP9 or AV1. ytdl re-encodes those to HEVC after downloading: hardware-accelerated, but it takes a moment and the file is a little larger."
                         : "Above 1080p YouTube only offers VP9 or AV1, which QuickTime and QuickLook can't play. Use IINA or VLC, or turn on HEVC conversion.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)
        case .audio:
            Form {
                Picker("Format", selection: $audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                if audioFormat == .mp3 {
                    Picker("Bitrate", selection: $audioBitrate) {
                        ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                    }
                }
                Text(audioHint).font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.columns)
        case .formats:
            if let info {
                FormatsView(formats: info.mediaFormats, selection: $selectedFormatID)
                    .frame(minHeight: 160, maxHeight: .infinity)
                if let f = selectedFormat {
                    HStack {
                        Text(f.kind == .videoOnly ? "Video-only stream — best audio will be merged in." : f.kind.rawValue)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if f.kind == .audioOnly {
                            Picker("Output", selection: $audioOutput) {
                                ForEach(AudioOutput.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .frame(width: 220)
                        } else {
                            Picker("Output", selection: $videoOutput) {
                                ForEach(VideoOutput.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .frame(width: 240)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var clipRow: some View {
        HStack(spacing: 8) {
            Toggle("Clip", isOn: $clipEnabled)
                .help("Download only part of the video")
            if clipEnabled {
                TextField("Start", text: $clipStart, prompt: Text("0:00"))
                    .frame(width: 80)
                Text("to")
                TextField("End", text: $clipEnd, prompt: Text(Fmt.duration(info?.duration).isEmpty ? "1:00" : Fmt.duration(info?.duration)))
                    .frame(width: 80)
                Toggle("Precise cuts", isOn: $preciseCuts)
                    .help("Re-encodes around the cut points so the clip starts exactly where you asked. Slower.")
                if let error = clipError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var optionsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 16) {
                Toggle("Metadata", isOn: $embedMetadata)
                Toggle("Thumbnail", isOn: $embedThumbnail)
                if mode != .audio {
                    Toggle("Subtitles", isOn: $embedSubs)
                    Toggle("Chapters", isOn: $embedChapters)
                }
                if canDownloadPlaylist {
                    Toggle("Whole playlist", isOn: $wholePlaylist)
                }
            }
            if canClip { clipRow }
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(abbreviatedOutputDir).lineLimit(1).truncationMode(.middle)
                    .help(outputDirPath)
                Button("Change…", action: chooseFolder)
                Spacer()
                Button(action: startDownload) {
                    Label(batchURLs.isEmpty ? "Download" : "Download \(batchURLs.count)", systemImage: "arrow.down.circle.fill")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canDownload)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: Derived state

    private var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var availableModes: [DownloadMode] {
        info?.isPlaylist == true || !batchURLs.isEmpty ? [.video, .audio] : DownloadMode.allCases
    }

    private var maxHeight: Int { info?.availableHeights.first ?? 0 }

    private var heightChoices: [Int] {
        let standard = [2160, 1440, 1080, 720, 480, 360]
        guard let info, !info.isPlaylist, batchURLs.isEmpty else { return standard }
        let avail = info.availableHeights
        return standard.filter { h in avail.contains { $0 >= h } }
            .union(avail.filter { $0 >= 144 && $0 < 360 }.prefix(1))
    }

    private func heightLabel(_ h: Int) -> String {
        switch h {
        case 2160: return "4K (2160p)"
        case 1440: return "1440p"
        default: return "\(h)p"
        }
    }

    private var audioHint: String {
        switch audioFormat {
        case .mp3: return "Re-encoded to MP3 at the chosen bitrate."
        case .m4a: return "AAC in M4A — copied from YouTube without re-encoding when possible."
        case .opus: return "Opus — YouTube's best-quality audio, copied without re-encoding."
        case .flac: return "Lossless container (no quality gain over the source, but widely editable)."
        case .wav: return "Uncompressed PCM. Large files; no cover art."
        case .original: return "Whatever the best audio stream is, untouched."
        }
    }

    private var selectedFormat: Format? {
        info?.mediaFormats.first { $0.formatID == selectedFormatID }
    }

    private var canDownloadPlaylist: Bool {
        if !batchURLs.isEmpty { return batchURLs.contains { $0.contains("list=") } }
        return info?.isPlaylist == true || (fetchedURL ?? "").contains("list=")
    }

    private var effectiveWholePlaylist: Bool { canDownloadPlaylist && wholePlaylist }

    /// Clips only make sense for a single video.
    private var canClip: Bool {
        batchURLs.isEmpty && info?.isPlaylist == false && !effectiveWholePlaylist
    }

    private var clipRange: YtDlp.ClipRange? {
        guard canClip, clipEnabled else { return nil }
        let start = clipStart.isEmpty ? 0 : YtDlp.parseTime(clipStart)
        let end = clipEnd.isEmpty ? info?.duration : YtDlp.parseTime(clipEnd)
        guard let start, let end, end > start else { return nil }
        if let d = info?.duration, start >= d { return nil }
        return YtDlp.ClipRange(start: start, end: end, preciseCuts: preciseCuts)
    }

    private var clipError: String? {
        guard canClip, clipEnabled, clipRange == nil else { return nil }
        if !clipStart.isEmpty && YtDlp.parseTime(clipStart) == nil { return "Start should look like 1:20" }
        if !clipEnd.isEmpty && YtDlp.parseTime(clipEnd) == nil { return "End should look like 2:45" }
        if clipEnd.isEmpty && info?.duration == nil { return "Enter an end time" }
        return "End must be after start"
    }

    private var canDownload: Bool {
        guard !ytdlpMissing else { return false }
        if !batchURLs.isEmpty { return true }
        guard info != nil, clipError == nil else { return false }
        if mode == .formats { return selectedFormat != nil }
        return true
    }

    private var abbreviatedOutputDir: String { (outputDirPath as NSString).abbreviatingWithTildeInPath }

    private func thumbnailURL(_ info: VideoInfo) -> URL? {
        if let t = info.thumbnail, let u = URL(string: t) { return u }
        if let id = info.id, !info.isPlaylist { return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
        return nil
    }

    // MARK: Links

    /// All http(s) links in a blob of text, in order, without duplicates.
    static func extractLinks(_ text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { $0.url?.absoluteString }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .filter { seen.insert($0).inserted }
    }

    private func addLinks(_ links: [String]) {
        let combined = Self.extractLinks(urlText + " " + links.joined(separator: " "))
        urlText = combined.joined(separator: " ")
    }

    /// Fills the field with a freshly copied link when the user switches to the app.
    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard watchClipboard, pb.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pb.changeCount
        guard let text = pb.string(forType: .string) else { return }
        let links = Self.extractLinks(text)
        guard !links.isEmpty, links != Self.extractLinks(urlText) else { return }
        urlText = links.joined(separator: " ")
    }

    // MARK: Actions

    private func scheduleFetch(_ text: String) {
        let links = Self.extractLinks(text)
        if links.count > 1 {
            fetchTask?.cancel()
            batchURLs = links
            info = nil
            fetchError = nil
            fetchedURL = nil
            isFetching = false
            return
        }
        batchURLs = []
        let t = links.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != fetchedURL else { return }
        fetchTask?.cancel()
        guard t.hasPrefix("http"), URL(string: t)?.host != nil else {
            if t.isEmpty { info = nil; fetchError = nil; fetchedURL = nil }
            return
        }
        fetchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            fetch(force: false)
        }
    }

    private func fetch(force: Bool) {
        guard batchURLs.isEmpty else { return }
        let url = Self.extractLinks(urlText).first ?? trimmedURL
        guard !url.isEmpty, force || url != fetchedURL else { return }
        fetchedURL = url
        isFetching = true
        fetchError = nil
        Task {
            do {
                let result = try await YtDlp.fetchInfo(url: url)
                guard url == fetchedURL else { return }  // a newer URL was entered meanwhile
                info = result
                wholePlaylist = result.isPlaylist
            } catch {
                guard url == fetchedURL else { return }
                info = nil
                fetchError = error.localizedDescription
            }
            isFetching = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: outputDirPath)
        if panel.runModal() == .OK, let url = panel.url {
            outputDirPath = url.path
        }
    }

    private func arguments(_ opts: YtDlp.Options) -> (args: [String], label: String)? {
        switch mode {
        case .video:
            let args = YtDlp.videoArgs(opts, maxHeight: videoHeight == 0 ? nil : videoHeight, preferH264: preferH264)
            return (args, "MP4 · " + (videoHeight == 0 ? "Best" : heightLabel(videoHeight)))
        case .audio:
            let args = YtDlp.audioArgs(opts, format: audioFormat, bitrate: audioBitrate)
            return (args, audioFormat.label + (audioFormat == .mp3 ? " · \(audioBitrate.label)" : ""))
        case .formats:
            guard let f = selectedFormat else { return nil }
            let args = YtDlp.formatArgs(opts, format: f, videoOutput: videoOutput, audioOutput: audioOutput)
            let out = f.kind == .audioOnly ? audioOutput.rawValue : videoOutput.rawValue
            return (args, "Format \(f.formatID) (\(f.ext ?? "?"), \(f.resolutionLabel)) → \(out)")
        }
    }

    private func startDownload() {
        let opts = YtDlp.Options(
            outputDir: URL(fileURLWithPath: outputDirPath),
            wholePlaylist: effectiveWholePlaylist,
            embedMetadata: embedMetadata,
            embedThumbnail: embedThumbnail,
            embedSubs: embedSubs && mode != .audio,
            embedChapters: embedChapters && mode != .audio,
            clip: clipRange
        )
        guard let built = arguments(opts) else { return }
        let (args, label) = built
        let convert: Bool
        switch mode {
        case .video: convert = convertForQuickTime
        case .audio: convert = false
        case .formats: convert = selectedFormat?.kind != .audioOnly && videoOutput == .mp4Recode
        }
        var suffix = opts.wholePlaylist ? " · playlist" : ""
        if let clip = opts.clip { suffix += " · clip \(Fmt.duration(clip.start).isEmpty ? "0:00" : Fmt.duration(clip.start))–\(Fmt.duration(clip.end))" }

        if !batchURLs.isEmpty {
            // Titles and thumbnails arrive from yt-dlp once each job starts. Queued in order: first link starts first.
            for url in batchURLs {
                manager.enqueue(DownloadRequest(url: url, title: "", thumbnail: nil, modeLabel: label + suffix,
                                                arguments: args, outputDir: opts.outputDir,
                                                convertForQuickTime: convert))
            }
            urlText = ""
            return
        }

        guard let info, let url = fetchedURL else { return }
        let title = opts.wholePlaylist && !info.isPlaylist ? "Playlist from \(info.displayTitle)" : info.displayTitle
        manager.enqueue(DownloadRequest(
            url: url,
            title: title,
            thumbnail: thumbnailURL(info),
            modeLabel: label + suffix,
            arguments: args,
            outputDir: opts.outputDir,
            convertForQuickTime: convert
        ))
    }
}

private extension Array where Element == Int {
    func union<S: Sequence>(_ other: S) -> [Int] where S.Element == Int {
        var result = self
        for x in other where !result.contains(x) { result.append(x) }
        return result
    }
}
