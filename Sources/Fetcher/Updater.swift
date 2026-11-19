import Foundation
import Observation

/// Tracks the installed yt-dlp version and upgrades it. YouTube breaks old versions often.
@MainActor
@Observable
final class Updater {
    var version: String?
    var isUpdating = false
    var message: String?
    var dismissed = false

    /// yt-dlp versions are dates (2026.08.19); call it stale after this many days.
    let staleAfterDays = 60

    var versionDate: Date? {
        guard let version else { return nil }
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    var ageInDays: Int? {
        versionDate.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 }
    }

    var isOutdated: Bool { (ageInDays ?? 0) > staleAfterDays }

    func checkVersion() async {
        guard let exe = YtDlp.ytdlpPath,
              let result = try? await YtDlp.run(exe, ["--version"]), result.0 == 0 else { return }
        version = String(decoding: result.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Homebrew installs are symlinks into the Cellar; anything else gets yt-dlp's own updater.
    private var updateCommand: (String, [String])? {
        guard let exe = YtDlp.ytdlpPath else { return nil }
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: exe)) ?? exe
        if resolved.contains("/Cellar/"), let brew = YtDlp.find("brew") {
            return (brew, ["upgrade", "yt-dlp"])
        }
        return (exe, ["-U"])
    }

    func update() async {
        guard let command = updateCommand, !isUpdating else { return }
        let (exe, args) = command
        let before = version
        isUpdating = true
        message = nil
        defer { isUpdating = false }
        do {
            let (status, out, err) = try await YtDlp.run(exe, args)
            await checkVersion()
            if status != 0 {
                let text = String(decoding: err + out, as: UTF8.self)
                let line = text.split(separator: "\n").last { $0.contains("Error") || $0.contains("ERROR") }
                message = "Update failed: " + (line.map(String.init) ?? "exit code \(status)")
            } else if version != before {
                message = "Updated yt-dlp to \(version ?? "?")."
            } else {
                message = "yt-dlp \(version ?? "") is already the latest version."
            }
        } catch {
            message = "Update failed: \(error.localizedDescription)"
        }
    }
}
