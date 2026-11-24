import CryptoKit
import Foundation
import Observation

/// yt-dlp, ffmpeg and deno. Copies from Homebrew are used when they're there; Fetcher downloads
/// its own of whichever are missing, into the user's Library, so nothing needs an admin password.
struct ToolPackage {
    enum Checksum {
        /// Known when this version of Fetcher was built.
        case pinned(String)
        /// Published beside the download, as `<sha256>  <file name>` lines.
        case published(URL)
    }

    struct Archive {
        var url: URL
        var checksum: Checksum
    }

    var name: String
    /// What the package provides, and what the file is called in the archive.
    var binaries: [String: String]
    var archives: [Archive]

    static let all = [ytdlp, ffmpeg, deno]

    static let ytdlp = ToolPackage(
        name: "yt-dlp",
        // The zip rather than the single file: that one unpacks itself on every run.
        binaries: ["yt-dlp": "yt-dlp_macos"],
        archives: [Archive(url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!,
                           checksum: .published(URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!))])

    /// FFmpeg doesn't publish Mac builds of its own. These are Martin Riedl's, held to one version.
    static let ffmpeg = ToolPackage(
        name: "ffmpeg",
        binaries: ["ffmpeg": "ffmpeg", "ffprobe": "ffprobe"],
        archives: [Archive(url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1795207104_9.1/ffmpeg.zip")!,
                           checksum: .pinned("1f66e9a690a7f1c9e60b012379f8869c11818d1797f45b21dbb2f2564ba61ae1")),
                   Archive(url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1795207104_9.1/ffprobe.zip")!,
                           checksum: .pinned("6ef2df5f575042923a28537ab37adf936f28bf3e7b85de23a1447ed447ec1dbd"))])

    static let deno = ToolPackage(
        name: "deno",
        binaries: ["deno": "deno"],
        archives: [Archive(url: URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip")!,
                           checksum: .published(URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip.sha256sum")!))])

    // MARK: Where they live

    static let defaultRoot = URL.applicationSupportDirectory.appending(path: "Fetcher/Tools")

    func directory(in root: URL = defaultRoot) -> URL { root.appending(path: name) }

    /// Fetcher's own copy of a tool, if it has one.
    static func ownCopy(of tool: String, in root: URL = defaultRoot) -> String? {
        for package in all {
            guard let file = package.binaries[tool] else { continue }
            let path = package.directory(in: root).appending(path: file).path
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return nil
    }

    var isMissing: Bool { binaries.keys.contains { YtDlp.find($0) == nil } }

    // MARK: Installing

    struct InstallError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Downloads, checks and unpacks the package, then swaps it in for any copy already there.
    func install(in root: URL = defaultRoot) async throws {
        #if !arch(arm64)
        throw InstallError(message: "Fetcher can only download \(name) on Apple Silicon. Install it with Homebrew.")
        #else
        let files = FileManager.default
        let staging = root.appending(path: ".\(name)-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        for archive in archives {
            let zip = try await Self.download(archive.url)
            defer { try? files.removeItem(at: zip) }
            let file = archive.url.lastPathComponent
            let expected: String
            switch archive.checksum {
            case .pinned(let sum): expected = sum
            case .published(let url):
                let list = try await Self.download(url)
                defer { try? files.removeItem(at: list) }
                guard let sum = Self.checksum(of: file, in: try String(contentsOf: list, encoding: .utf8)) else {
                    throw InstallError(message: "no checksum was published for \(file)")
                }
                expected = sum
            }
            guard try Self.sha256(zip) == expected else {
                throw InstallError(message: "\(file) didn't match its checksum, so it wasn't used")
            }
            let (status, _, err) = try await YtDlp.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
            guard status == 0 else {
                throw InstallError(message: "couldn't unpack \(file): " + String(decoding: err, as: UTF8.self))
            }
        }
        for file in binaries.values {
            let path = staging.appending(path: file).path
            guard files.fileExists(atPath: path) else { throw InstallError(message: "\(file) wasn't in the download") }
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        let destination = directory(in: root)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: destination)
        }
        #endif
    }

    private static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw InstallError(message: "\(url.host() ?? "the server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent)")
        }
        return file
    }

    static func checksum(of file: String, in list: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[1] == file, parts[0].count == 64 { return parts[0].lowercased() }
        }
        return nil
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Installs whichever tools are missing on launch.
@MainActor
@Observable
final class Dependencies {
    var missing: [String] = Dependencies.findMissing()
    var isInstalling = false
    var installing: String?
    var error: String?

    nonisolated static func findMissing() -> [String] { ToolPackage.all.filter(\.isMissing).map(\.name) }

    func refresh() { missing = Self.findMissing() }

    func install() async {
        refresh()
        guard !missing.isEmpty, !isInstalling else { return }
        isInstalling = true
        error = nil
        defer { isInstalling = false; installing = nil }
        for package in ToolPackage.all where package.isMissing {
            installing = package.name
            do {
                try await package.install()
            } catch {
                self.error = "Couldn't download \(package.name): \(error.localizedDescription)"
                break
            }
            refresh()
        }
    }
}
