import Foundation

enum YtDlp {
    /// GUI apps launched from Finder don't inherit the shell PATH, so look in the usual places.
    static let searchDirs: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        "/usr/bin",
    ]

    static func find(_ name: String) -> String? {
        searchDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ytdlpPath: String? { find("yt-dlp") }
    static var ffmpegPath: String? { find("ffmpeg") }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? ""
        env["PATH"] = (searchDirs + [existing]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    static let defaultTemplate = "%(title).200B [%(id)s].%(ext)s"
    static let playlistTemplate = "%(playlist_title|Playlist).150B/%(playlist_index|0)03d - %(title).150B [%(id)s].%(ext)s"
    /// " [1080p]" for anything with video. Without it a second download of the same video at
    /// another quality would hit the first file, and yt-dlp would skip it as already done.
    static let resolutionTag = "%(height& [{}p]|)s"

    // MARK: Info fetch

    struct FetchError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func fetchInfo(url: String) async throws -> VideoInfo {
        guard let exe = ytdlpPath else { throw FetchError(message: "yt-dlp not found. Install it with: brew install yt-dlp ffmpeg deno") }
        let args = ["-J", "--flat-playlist", "--no-playlist", "--no-warnings", "--no-update", "--", url]
        let (status, out, err) = try await run(exe, args)
        guard status == 0 else {
            let text = String(decoding: err, as: UTF8.self)
            let line = text.split(separator: "\n").last { $0.hasPrefix("ERROR:") } ?? text.split(separator: "\n").last
            throw FetchError(message: line.map { String($0).replacingOccurrences(of: "ERROR: ", with: "") } ?? "yt-dlp failed (exit \(status))")
        }
        do {
            return try JSONDecoder().decode(VideoInfo.self, from: out)
        } catch {
            throw FetchError(message: "Couldn't read yt-dlp output: \(error.localizedDescription)")
        }
    }

    /// Runs a process to completion, collecting stdout and stderr.
    static func run(_ exe: String, _ args: [String]) async throws -> (Int32, Data, Data) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.environment = environment
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice
            // Drain both pipes on their own threads so a large JSON blob can't fill a pipe and
            // stall the child, and learn about the exit from terminationHandler: waitUntilExit
            // needs a running run loop, which isn't a given off the main thread.
            let group = DispatchGroup()
            var outData = Data(), errData = Data()
            group.enter()
            p.terminationHandler = { _ in group.leave() }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.notify(queue: .global()) {
                cont.resume(returning: (p.terminationStatus, outData, errData))
            }
        }
    }

    // MARK: Download arguments

    struct Options {
        var outputDir: URL
        var wholePlaylist: Bool
        var embedMetadata: Bool
        var embedThumbnail: Bool
        var embedSubs: Bool
        var embedChapters: Bool
        var clip: ClipRange? = nil
    }

    struct ClipRange {
        var start: Double
        var end: Double
        var preciseCuts: Bool

        /// Filename-safe tag, e.g. "1m20s-2m45s".
        var tag: String { "\(Self.short(start))-\(Self.short(end))" }

        private static func short(_ s: Double) -> String {
            let t = Int(s.rounded())
            let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
            return (h > 0 ? "\(h)h" : "") + (h > 0 || m > 0 ? "\(m)m" : "") + "\(sec)s"
        }
    }

    static func outputTemplate(_ o: Options) -> String {
        let template: String
        if o.wholePlaylist {
            template = playlistTemplate
        } else if let clip = o.clip {
            template = "%(title).180B [%(id)s] [\(clip.tag)].%(ext)s"
        } else {
            template = defaultTemplate
        }
        return template.replacingOccurrences(of: ".%(ext)s", with: resolutionTag + ".%(ext)s")
    }

    /// Parses "80", "1:20", "1:02:03" or "1:20.5" into seconds.
    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p), v.isFinite, v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Arguments shared by every download: progress reporting, output location, binaries.
    static func baseArgs(_ o: Options) -> [String] {
        var a = [
            "--newline", "--progress", "--quiet", "--no-simulate", "--no-update", "--no-colors",
            "--progress-template",
            "download:[[PROG]] %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
            "--print", "before_dl:[[ITEM]]\t%(playlist_index|)s\t%(n_entries|)s\t%(title)s",
            "--print", "before_dl:[[META]]\t%(thumbnail|)s",
            "--print", "post_process:[[POST]]",
            "--print", "after_move:[[FILE]]\t%(filepath)s",
            "-P", o.outputDir.path,
            "-o", outputTemplate(o),
            o.wholePlaylist ? "--yes-playlist" : "--no-playlist",
        ]
        if let clip = o.clip {
            a += ["--download-sections", "*\(clip.start)-\(clip.end)"]
            if clip.preciseCuts { a.append("--force-keyframes-at-cuts") }
        }
        if let ff = ffmpegPath { a += ["--ffmpeg-location", ff] }
        if o.embedMetadata { a.append("--embed-metadata") }
        return a
    }

    private static func videoExtras(_ o: Options, thumbnailOK: Bool) -> [String] {
        var a: [String] = []
        if o.embedThumbnail && thumbnailOK { a += ["--embed-thumbnail", "--convert-thumbnails", "jpg"] }
        if o.embedSubs { a += ["--embed-subs", "--sub-langs", "en.*,-live_chat"] }
        if o.embedChapters { a.append("--embed-chapters") }
        return a
    }

    static func videoArgs(_ o: Options, maxHeight: Int?, preferH264: Bool) -> [String] {
        let res = maxHeight.map { "res:\($0)" } ?? "res"
        let sort = preferH264 ? "\(res),vcodec:h264,acodec:m4a" : "\(res),ext:mp4:m4a"
        return baseArgs(o) + [
            "-f", "bv*+ba/b",
            "-S", sort,
            "--merge-output-format", "mp4",
            "--remux-video", "mp4",
        ] + videoExtras(o, thumbnailOK: true)
    }

    static func audioArgs(_ o: Options, format: AudioFormat, bitrate: AudioBitrate) -> [String] {
        var a = baseArgs(o)
        switch format {
        case .m4a: a += ["-f", "ba[ext=m4a]/ba/b"]
        case .opus: a += ["-f", "ba[acodec=opus]/ba/b"]
        default: a += ["-f", "ba/b"]
        }
        a += ["-x", "--audio-format", format.rawValue]
        if format == .mp3 { a += ["--audio-quality", "\(bitrate.rawValue)K"] }
        if o.embedThumbnail && format != .wav { a += ["--embed-thumbnail", "--convert-thumbnails", "jpg"] }
        return a
    }

    static func formatArgs(_ o: Options, format: Format, videoOutput: VideoOutput, audioOutput: AudioOutput) -> [String] {
        var a = baseArgs(o)
        if format.kind == .audioOnly {
            a += ["-f", format.formatID]
            switch audioOutput {
            case .original:
                // Most raw audio streams (webm/m4a) can take a cover, but not all; skip to be safe.
                break
            case .mp3:
                a += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
            case .m4a, .flac, .wav:
                a += ["-x", "--audio-format", audioOutput.rawValue.lowercased()]
            }
            if o.embedThumbnail && (audioOutput == .mp3 || audioOutput == .m4a || audioOutput == .flac) {
                a += ["--embed-thumbnail", "--convert-thumbnails", "jpg"]
            }
            return a
        }

        let id = format.formatID
        if format.kind == .videoOnly {
            // MP4 players (QuickTime) want AAC, so prefer an m4a audio track when the output is MP4.
            let wantsAAC = videoOutput == .mp4Remux || videoOutput == .mp4Recode
            a += ["-f", wantsAAC ? "\(id)+ba[ext=m4a]/\(id)+ba/\(id)" : "\(id)+ba/\(id)"]
        } else {
            a += ["-f", id]
        }
        switch videoOutput {
        case .original:
            a += videoExtras(o, thumbnailOK: false)
        case .mp4Remux:
            a += ["--merge-output-format", "mp4", "--remux-video", "mp4"] + videoExtras(o, thumbnailOK: true)
        case .mkvRemux:
            a += ["--merge-output-format", "mkv", "--remux-video", "mkv"] + videoExtras(o, thumbnailOK: true)
        case .mp4Recode:
            // Remuxed to MP4 here; QuickTimeConverter re-encodes to HEVC afterwards if it needs it.
            a += ["--merge-output-format", "mp4", "--remux-video", "mp4"] + videoExtras(o, thumbnailOK: true)
        }
        return a
    }
}
