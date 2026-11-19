import AVFoundation
import Foundation

/// `swift run Fetcher --self-check` runs these and exits without opening a window.
/// Add `--offline` to skip the ones that download from YouTube.
@MainActor
enum SelfCheck {
    static let sample = "https://www.youtube.com/watch?v=jNQXAC9IVRw"  // "Me at the zoo", 19 s
    static let longer = "https://www.youtube.com/watch?v=TkxC1OmjRdg"  // 41 s, VP9 above 1080p

    private static var failures = 0

    static func runAndExit() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)  // line by line, even into a pipe
        Task { @MainActor in
            await run()
            print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        print(ok ? "  ✓ \(name)" : "  ✗ \(name)\(detail().isEmpty ? "" : " — \(detail())")")
        if !ok { failures += 1 }
    }

    private static func run() async {
        print("Parsing")
        check(YtDlp.parseTime("80") == 80, "parseTime seconds")
        check(YtDlp.parseTime("1:20") == 80, "parseTime m:ss")
        check(YtDlp.parseTime("1:02:03") == 3723, "parseTime h:mm:ss")
        check(YtDlp.parseTime("1:20.5") == 80.5, "parseTime fractions")
        check(YtDlp.parseTime("inf") == nil && YtDlp.parseTime("1:x") == nil && YtDlp.parseTime("-5") == nil,
              "parseTime rejects junk")
        check(YtDlp.ClipRange(start: 80, end: 3723, preciseCuts: true).tag == "1m20s-1h2m3s", "clip filename tag")

        let buf = LineBuffer()
        check(buf.append(Data("a\nb\rc".utf8)) == ["a", "b"] && buf.flush() == ["c"], "LineBuffer splits on \\n and \\r")

        let links = ContentView.extractLinks("see https://youtu.be/a and\nhttps://youtu.be/b https://youtu.be/a ftp://x")
        check(links == ["https://youtu.be/a", "https://youtu.be/b"], "extractLinks finds, orders, dedupes", "\(links)")
        check(ContentView.isOnlyLinks("https://youtu.be/a\n https://youtu.be/b "), "clipboard: bare links count")
        check(!ContentView.isOnlyLinks("watch this https://youtu.be/a"), "clipboard: a sentence with a link doesn't")

        guard !CommandLine.arguments.contains("--offline") else { return }
        guard Dependencies.findMissing().isEmpty else {
            check(false, "yt-dlp, ffmpeg and deno installed", Dependencies.findMissing().joined(separator: ", "))
            return
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Fetcher-self-check-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let opts = YtDlp.Options(outputDir: dir, wholePlaylist: false, embedMetadata: true,
                                 embedThumbnail: true, embedSubs: false, embedChapters: true)

        print("\nFetching info")
        var info: VideoInfo?
        do {
            info = try await YtDlp.fetchInfo(url: sample)
            check(info?.title == "Me at the zoo", "title")
            check((info?.mediaFormats.count ?? 0) > 10, "formats listed", "\(info?.mediaFormats.count ?? 0)")
        } catch {
            check(false, "fetch info", error.localizedDescription)
        }
        do {
            _ = try await YtDlp.fetchInfo(url: "https://www.youtube.com/watch?v=xxxxxxxxxxx")
            check(false, "bad link reports an error")
        } catch {
            check(error.localizedDescription.contains("unavailable") || !error.localizedDescription.isEmpty,
                  "bad link reports an error", error.localizedDescription)
        }

        let manager = DownloadManager()

        print("\nVideo (MP4)")
        if let job = await download(manager, YtDlp.videoArgs(opts, maxHeight: nil, preferH264: true), convert: true, dir: dir),
           let file = job.files.first, let probe = await QuickTimeConverter.probe(file) {
            check(probe.videoCodec == "h264" && probe.audioCodecs == ["aac"], "H.264 + AAC", "\(probe)")
            check(probe.coverIndex != nil, "cover art embedded")
            check(!job.log.contains { $0.hasPrefix("Converting") }, "already playable, so not re-encoded")
            await checkPlayable(file)
        }

        print("\nAudio (MP3)")
        if let job = await download(manager, YtDlp.audioArgs(opts, format: .mp3, bitrate: .k192), convert: false, dir: dir),
           let file = job.files.first {
            check(file.pathExtension == "mp3", "mp3 file", file.lastPathComponent)
            let codecs = await streamCodecs(file)
            check(codecs.contains("mp3") && codecs.contains("mjpeg"), "mp3 audio with cover", "\(codecs)")
        }

        print("\nClip 0:05–0:12")
        var clipOpts = opts
        clipOpts.clip = YtDlp.ClipRange(start: 5, end: 12, preciseCuts: true)
        if let job = await download(manager, YtDlp.videoArgs(clipOpts, maxHeight: nil, preferH264: true), convert: true, dir: dir),
           let file = job.files.first, let probe = await QuickTimeConverter.probe(file) {
            check(abs(probe.duration - 7) < 0.6, "about 7 seconds long", "\(probe.duration)")
            check(file.lastPathComponent.contains("[5s-12s]"), "clip range in the filename", file.lastPathComponent)
            check(file.lastPathComponent.hasSuffix("p].mp4"), "resolution in the filename", file.lastPathComponent)
        }

        print("\nAll Formats: VP9 video-only → MP4 (QuickTime-ready)")
        if let vp9 = info?.mediaFormats.first(where: { $0.kind == .videoOnly && $0.vcodecName.hasPrefix("vp") }) {
            let args = YtDlp.formatArgs(opts, format: vp9, videoOutput: .mp4Recode, audioOutput: .original)
            if let job = await download(manager, args, convert: true, dir: dir),
               let file = job.files.first, let probe = await QuickTimeConverter.probe(file) {
                check(probe.videoCodec == "hevc" && probe.audioCodecs == ["aac"], "re-encoded to HEVC + AAC", "\(probe)")
                check(probe.coverIndex != nil, "cover art survived the conversion")
                check(!FileManager.default.fileExists(atPath: QuickTimeConverter.tempURL(for: file).path), "temp file cleaned up")
                await checkPlayable(file)
            }
        } else {
            check(false, "sample has a VP9 video-only format")
        }

        print("\nOpus audio in an MP4 → AAC")
        await checkOpusConversion(dir: dir)

        print("\nTwo links at once")
        let m4a = YtDlp.audioArgs(opts, format: .m4a, bitrate: .k192)
        var accepted: [Bool] = []
        for url in [sample, longer, sample] {
            accepted.append(manager.enqueue(DownloadRequest(url: url, title: "", thumbnail: nil, modeLabel: "batch",
                                                            arguments: m4a, outputDir: dir)))
        }
        check(accepted == [true, true, false], "the same download twice is only queued once", "\(accepted)")
        let batch = Array(manager.jobs.prefix(2))
        await waitUntilDone(batch)
        check(batch.allSatisfy { $0.state == .finished }, "both finish", batch.map(\.statusText).joined(separator: ", "))
        check(batch.allSatisfy { !$0.title.hasPrefix("http") }, "titles filled in from yt-dlp", batch.map(\.title).joined(separator: ", "))
        check(batch.allSatisfy { $0.thumbnail != nil }, "thumbnails filled in from yt-dlp")

        print("\nCancel")
        manager.enqueue(DownloadRequest(url: longer, title: "cancel me", thumbnail: nil, modeLabel: "",
                                        arguments: YtDlp.videoArgs(opts, maxHeight: 2160, preferH264: true),
                                        outputDir: dir, convertForQuickTime: true))
        let job = manager.jobs[0]
        let started = await waitFor(seconds: 60) { (job.progress ?? 0) > 0.05 || job.state.isDone }
        check(started && !job.state.isDone, "download got going", job.statusText)
        manager.cancel(job)
        await waitUntilDone([job], seconds: 15)
        check(job.state == .cancelled, "marked cancelled", job.statusText)
        try? await Task.sleep(for: .seconds(1))
        let leftovers = await processesMentioning(dir.path)
        check(leftovers.isEmpty, "no yt-dlp or ffmpeg left running", leftovers)
    }

    // MARK: Helpers

    private static func download(_ manager: DownloadManager, _ args: [String], convert: Bool, dir: URL) async -> DownloadJob? {
        manager.enqueue(DownloadRequest(url: sample, title: "check", thumbnail: nil, modeLabel: "",
                                        arguments: args, outputDir: dir, convertForQuickTime: convert))
        let job = manager.jobs[0]
        await waitUntilDone([job])
        check(job.state == .finished, "finishes", job.statusText + "\n" + job.log.suffix(5).joined(separator: "\n"))
        check(job.files.count == 1 && job.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
              "reports the file it saved", job.files.map(\.lastPathComponent).joined(separator: ", "))
        return job.state == .finished ? job : nil
    }

    private static func waitUntilDone(_ jobs: [DownloadJob], seconds: Double = 180) async {
        _ = await waitFor(seconds: seconds) { jobs.allSatisfy { $0.state.isDone } }
    }

    private static func waitFor(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private static func checkPlayable(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let decodable = (try? await track?.load(.isDecodable)) ?? false
        check(playable && decodable, "QuickTime can play it")
    }

    private static func streamCodecs(_ url: URL) async -> [String] {
        guard let exe = QuickTimeConverter.ffprobePath,
              let r = try? await YtDlp.run(exe, ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path])
        else { return [] }
        return String(decoding: r.1, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Builds an H.264 + Opus MP4 and runs the converter's own arguments over it.
    private static func checkOpusConversion(dir: URL) async {
        guard let ffmpeg = YtDlp.ffmpegPath else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("opus-test.mp4")
        let made = try? await YtDlp.run(ffmpeg, ["-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
            "-f", "lavfi", "-i", "sine=duration=2",
            "-c:v", "libx264", "-c:a", "libopus", "-shortest", src.path])
        guard made?.0 == 0, let probe = await QuickTimeConverter.probe(src) else {
            check(false, "made an H.264 + Opus test file")
            return
        }
        check(QuickTimeConverter.needsConversion(src, probe) && !QuickTimeConverter.videoNeedsConversion(probe),
              "needs audio conversion only", "\(probe)")
        let out = dir.appendingPathComponent("opus-test-out.mp4")
        let r = try? await YtDlp.run(ffmpeg, QuickTimeConverter.arguments(input: src, output: out, probe: probe))
        let after = await QuickTimeConverter.probe(out)
        check(r?.0 == 0 && after?.videoCodec == "h264" && after?.audioCodecs == ["aac"],
              "video copied, audio now AAC", "\(String(describing: after))")
    }

    private static func processesMentioning(_ text: String) async -> String {
        guard let r = try? await YtDlp.run("/usr/bin/pgrep", ["-fl", text]) else { return "" }
        return String(decoding: r.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
