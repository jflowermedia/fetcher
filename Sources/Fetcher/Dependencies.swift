import AppKit
import Foundation
import Observation

/// yt-dlp, ffmpeg and deno come from Homebrew. Fetcher installs whichever are missing on launch.
@MainActor
@Observable
final class Dependencies {
    nonisolated static let tools = ["yt-dlp", "ffmpeg", "deno"]

    var missing: [String] = Dependencies.findMissing()
    var isInstalling = false
    var error: String?

    var hasHomebrew: Bool { YtDlp.find("brew") != nil }

    nonisolated static func findMissing() -> [String] { tools.filter { YtDlp.find($0) == nil } }

    func refresh() { missing = Self.findMissing() }

    /// Installs the missing tools with Homebrew. Without Homebrew, opens Terminal to install it
    /// first, since its installer asks for an admin password.
    func install() async {
        refresh()
        guard !missing.isEmpty, !isInstalling else { return }
        guard let brew = YtDlp.find("brew") else { openTerminalInstaller(); return }
        isInstalling = true
        error = nil
        defer { isInstalling = false }
        do {
            let (status, out, err) = try await YtDlp.run(brew, ["install"] + missing)
            refresh()
            if status != 0 || !missing.isEmpty {
                let text = String(decoding: err + out, as: UTF8.self)
                let line = text.split(separator: "\n").last { $0.contains("Error") }
                error = "Couldn't install \(missing.joined(separator: ", ")): " + (line.map(String.init) ?? "brew exited with code \(status)")
            }
        } catch {
            self.error = "Couldn't run Homebrew: \(error.localizedDescription)"
        }
    }

    private func openTerminalInstaller() {
        let script = """
            #!/bin/bash
            echo "Installing Homebrew, then yt-dlp, ffmpeg and deno for Fetcher."
            echo
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
            brew install \(Self.tools.joined(separator: " ")) || exit 1
            echo
            echo "Done. You can close this window and switch back to Fetcher."
            """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Install Fetcher Dependencies.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            self.error = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }
}
