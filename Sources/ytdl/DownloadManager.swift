import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case queued, downloading, processing, converting, finished, failed(String), cancelled

        var isActive: Bool { self == .downloading || self == .processing || self == .converting }
        var isDone: Bool {
            switch self {
            case .finished, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let request: DownloadRequest
    var state: State = .queued
    var progress: Double?
    var downloaded: Double?
    var total: Double?
    var speed: Double?
    var eta: Double?
    var itemIndex: Int?
    var itemCount: Int?
    var currentTitle: String?
    var files: [URL] = []
    var log: [String] = []
    var thumbnail: URL?
    /// Title learned from yt-dlp, for jobs queued without fetching info first (batch links).
    var fetchedTitle: String?

    fileprivate var process: Process?
    fileprivate var cancelRequested = false
    fileprivate var tempFile: URL?

    init(request: DownloadRequest) {
        self.request = request
        self.thumbnail = request.thumbnail
    }

    var title: String {
        request.title.isEmpty ? (fetchedTitle ?? request.url) : request.title
    }

    var statusText: String {
        switch state {
        case .queued: return "Queued"
        case .downloading:
            var parts: [String] = []
            if let p = progress { parts.append(String(format: "%.0f%%", p * 100)) }
            if let total { parts.append("of \(Fmt.bytes(total))") }
            if let s = speed, s > 0 { parts.append(Fmt.speed(s)) }
            if let e = eta, e > 0 { parts.append("\(Fmt.duration(e)) left") }
            return parts.isEmpty ? "Starting…" : parts.joined(separator: " · ")
        case .processing: return "Processing…"
        case .converting:
            let pct = progress.map { String(format: " %.0f%%", $0 * 100) } ?? ""
            return "Converting for QuickTime…" + pct
        case .finished: return files.count > 1 ? "Done · \(files.count) files" : "Done"
        case .failed(let msg): return msg
        case .cancelled: return "Cancelled"
        }
    }

    var itemLabel: String? {
        guard let i = itemIndex else { return nil }
        if let n = itemCount { return "\(i) of \(n)" }
        return "#\(i)"
    }
}

@MainActor
@Observable
final class DownloadManager {
    var jobs: [DownloadJob] = []
    let maxConcurrent = 3

    var hasFinished: Bool { jobs.contains { $0.state.isDone } }

    /// Ignores a request identical to one already queued or running: both would write the
    /// same file, and the second crashes when the first moves it. False when ignored.
    @discardableResult
    func enqueue(_ request: DownloadRequest) -> Bool {
        let duplicate = jobs.contains {
            !$0.state.isDone && $0.request.url == request.url && $0.request.arguments == request.arguments
        }
        guard !duplicate else { return false }
        jobs.insert(DownloadJob(request: request), at: 0)
        pump()
        return true
    }

    var hasActiveJobs: Bool { jobs.contains { !$0.state.isDone } }

    func retry(_ job: DownloadJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i] = DownloadJob(request: job.request)
        pump()
    }

    func remove(_ job: DownloadJob) {
        if !job.state.isDone { cancel(job) }
        jobs.removeAll { $0.id == job.id }
        // A removed job never reports back, so free its slot now.
        pump()
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isDone }
    }

    func cancel(_ job: DownloadJob) {
        switch job.state {
        case .queued:
            job.state = .cancelled
        case .downloading, .processing, .converting:
            job.cancelRequested = true
            if let p = job.process { Self.terminateTree(p) }
        default:
            break
        }
    }

    func cancelAll() {
        for job in jobs { cancel(job) }
    }

    /// For quitting: stop everything and delete half-written HEVC copies, since the
    /// conversion's own cleanup won't get a chance to run.
    func shutDown() {
        cancelAll()
        for job in jobs {
            if let temp = job.tempFile { try? FileManager.default.removeItem(at: temp) }
        }
    }

    private func pump() {
        let running = jobs.filter { $0.state.isActive }.count
        guard running < maxConcurrent else { return }
        // Oldest queued first (jobs are stored newest-first).
        for job in jobs.reversed() where job.state == .queued {
            if jobs.filter({ $0.state.isActive }).count >= maxConcurrent { break }
            start(job)
        }
    }

    private func start(_ job: DownloadJob) {
        guard let exe = YtDlp.ytdlpPath else {
            job.state = .failed("yt-dlp not found — brew install yt-dlp ffmpeg")
            return
        }
        try? FileManager.default.createDirectory(at: job.request.outputDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = job.request.arguments + ["--", job.request.url]
        p.environment = YtDlp.environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        // finish() waits for both the exit and the end of output, so the last [[FILE]] line
        // can't be lost to a race between them.
        let buffer = LineBuffer()
        let done = DispatchGroup()
        done.enter()
        done.enter()
        pipe.fileHandleForReading.readabilityHandler = { [weak job] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let lines = data.isEmpty ? buffer.flush() : buffer.append(data)
            if !lines.isEmpty {
                // DispatchQueue.main keeps lines in order (unstructured Tasks don't guarantee that).
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let job else { return }
                        for line in lines { Self.handle(line, job: job) }
                    }
                }
            }
            if data.isEmpty { done.leave() }
        }
        p.terminationHandler = { _ in done.leave() }
        done.notify(queue: .main) { [weak self, weak job] in
            MainActor.assumeIsolated {
                guard let job else { return }
                self?.finish(job, status: p.terminationStatus)
            }
        }

        job.state = .downloading
        job.process = p
        do {
            try p.run()
        } catch {
            job.state = .failed("Couldn't start yt-dlp: \(error.localizedDescription)")
            job.process = nil
        }
    }

    private func finish(_ job: DownloadJob, status: Int32) {
        job.process = nil
        if job.cancelRequested {
            job.state = .cancelled
        } else if status == 0 && job.request.convertForQuickTime {
            // Still counts against maxConcurrent while converting, so don't pump yet.
            Task { await convertForQuickTime(job) }
            return
        } else if status == 0 {
            complete(job)
        } else {
            let err = job.log.last { $0.hasPrefix("ERROR:") }
                .map { String($0.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces) }
            job.state = .failed(err ?? "yt-dlp exited with code \(status)")
            notify(title: "Download failed", body: job.title)
        }
        pump()
    }

    private func complete(_ job: DownloadJob) {
        job.state = .finished
        job.progress = 1
        notify(title: "Download finished", body: job.title)
    }

    // MARK: QuickTime conversion

    private func convertForQuickTime(_ job: DownloadJob) async {
        for (i, file) in job.files.enumerated() {
            guard !job.cancelRequested else { break }
            guard let probe = await QuickTimeConverter.probe(file),
                  QuickTimeConverter.needsConversion(file, probe) else { continue }
            job.state = .converting
            job.progress = 0
            job.log.append("Converting \(QuickTimeConverter.summary(probe)): \(file.lastPathComponent)")
            let temp = QuickTimeConverter.tempURL(for: file)
            job.tempFile = temp
            let ok = await runFFmpeg(job, QuickTimeConverter.arguments(input: file, output: temp, probe: probe),
                                     duration: probe.duration)
            if ok, !job.cancelRequested {
                do {
                    _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
                    job.files[i] = file
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    job.state = .failed("Downloaded, but couldn't replace it with the HEVC copy: \(error.localizedDescription)")
                    break
                }
            } else {
                try? FileManager.default.removeItem(at: temp)
                if !job.cancelRequested {
                    let err = job.log.last.map { ": \($0)" } ?? ""
                    job.state = .failed("Downloaded, but converting it for QuickTime failed\(err). The original file was kept.")
                }
                break
            }
        }
        job.process = nil
        job.tempFile = nil
        if job.cancelRequested {
            job.state = .cancelled
        } else if job.state == .converting || job.state == .processing || job.state == .downloading {
            complete(job)
        } else {
            notify(title: "Conversion failed", body: job.title)
        }
        pump()
    }

    /// Runs ffmpeg with `-progress pipe:1`, updating the job's progress. True on success.
    private func runFFmpeg(_ job: DownloadJob, _ args: [String], duration: Double) async -> Bool {
        guard let exe = YtDlp.ffmpegPath else {
            job.log.append("ffmpeg not found")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = YtDlp.environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let buffer = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak job] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = buffer.append(data)
            guard let micros = lines.last(where: { $0.hasPrefix("out_time_us=") })
                .flatMap({ Double($0.dropFirst("out_time_us=".count)) }), duration > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { job?.progress = min(max(micros / 1_000_000 / duration, 0), 1) }
            }
        }

        return await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    out.fileHandleForReading.readabilityHandler = nil
                    MainActor.assumeIsolated {
                        for line in errText.split(separator: "\n") { job.log.append(String(line)) }
                    }
                    cont.resume(returning: proc.terminationStatus == 0)
                }
            }
            do {
                try p.run()
                job.process = p
            } catch {
                job.log.append("Couldn't start ffmpeg: \(error.localizedDescription)")
                cont.resume(returning: false)
            }
        }
    }

    private static func handle(_ line: String, job: DownloadJob) {
        if line.hasPrefix("[[PROG]] ") {
            let f = line.dropFirst(9).split(separator: " ").map { Double($0) }
            func v(_ i: Int) -> Double? { i < f.count ? f[i] : nil }
            job.downloaded = v(0)
            job.total = v(1) ?? v(2)
            job.speed = v(3)
            job.eta = v(4)
            if let d = job.downloaded, let t = job.total, t > 0 {
                job.progress = min(d / t, 1)
            }
            if let p = job.progress, p >= 1 {
                job.state = .processing
            } else if job.state == .processing {
                job.state = .downloading
            }
        } else if line.hasPrefix("[[ITEM]]") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            job.itemIndex = parts.count > 1 ? Int(parts[1]) : nil
            job.itemCount = parts.count > 2 ? Int(parts[2]) : nil
            job.currentTitle = parts.count > 3 ? String(parts[3...].joined(separator: "\t")) : nil
            job.progress = nil
            job.state = .downloading
            if job.fetchedTitle == nil { job.fetchedTitle = job.currentTitle }
        } else if line.hasPrefix("[[META]]") {
            let thumb = line.split(separator: "\t", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if job.thumbnail == nil, let url = URL(string: thumb), url.scheme?.hasPrefix("http") == true {
                job.thumbnail = url
            }
        } else if line.hasPrefix("[[POST]]") {
            job.state = .processing
        } else if line.hasPrefix("[[FILE]]") {
            let path = line.split(separator: "\t", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if !path.isEmpty { job.files.append(URL(fileURLWithPath: path)) }
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            job.log.append(line)
            if job.log.count > 200 { job.log.removeFirst(job.log.count - 200) }
        }
    }

    /// yt-dlp spawns ffmpeg/deno children; take them down too.
    private static func terminateTree(_ p: Process) {
        let pid = p.processIdentifier
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", "\(pid)"]
        try? pkill.run()
        pkill.waitUntilExit()
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// Splits a byte stream into lines (on \n or \r). Called from the pipe's background thread.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let i = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = data[data.startIndex..<i]
            data.removeSubrange(data.startIndex...i)
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return [] }
        let s = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return [s]
    }
}
