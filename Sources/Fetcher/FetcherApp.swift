import AppKit
import SwiftUI
import UserNotifications

enum AppInfo {
    static let name = "Fetcher"
    static let version = "0.1.1"
    static let stage = "alpha"
    static let versionLabel = "Version \(version) · \(stage)"

    static let website = URL(string: "https://jflowermedia.com/")!
    static let instagram = URL(string: "https://www.instagram.com/jflowermedia/")!

    static let repo = URL(string: "https://github.com/jflowermedia/fetcher")!
    static let issues = URL(string: "https://github.com/jflowermedia/fetcher/issues")!
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: DownloadManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Closing the window mid-download leaves the app running so downloads finish;
    /// the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !(manager?.hasActiveJobs ?? false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let manager, manager.hasActiveJobs else { return .terminateNow }
            let count = manager.jobs.filter { !$0.state.isDone }.count
            let alert = NSAlert()
            alert.messageText = count == 1 ? "A download is still running." : "\(count) downloads are still running."
            alert.informativeText = "Quitting stops them. Partly downloaded files are kept, and Retry picks up where they left off."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            manager.shutDown()
            return .terminateNow
        }
    }
}

@main
struct FetcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager = DownloadManager()
    @State private var updater = Updater()
    @State private var dependencies = Dependencies()
    @AppStorage("watchClipboard") private var watchClipboard = true

    init() {
        if CommandLine.arguments.contains("--self-check") { SelfCheck.runAndExit() }
    }

    var body: some Scene {
        Window("Fetcher", id: "main") {
            ContentView()
                .environment(manager)
                .environment(updater)
                .environment(dependencies)
                .frame(minWidth: 780, minHeight: 640)
                .onAppear { appDelegate.manager = manager }
        }
        .defaultSize(width: 940, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Fetcher") { Self.showAbout() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(updater.isUpdating ? "Updating yt-dlp…" : "Update yt-dlp") {
                    Task { await updater.update() }
                }
                .disabled(updater.isUpdating || manager.hasActiveJobs)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Toggle("Fill In Copied Links Automatically", isOn: $watchClipboard)
            }
            CommandGroup(replacing: .help) {
                Button("Fetcher on GitHub") { NSWorkspace.shared.open(AppInfo.repo) }
                Button("Report a Problem") { NSWorkspace.shared.open(AppInfo.issues) }
                Divider()
                Button("JFlowerMedia Website") { NSWorkspace.shared.open(AppInfo.website) }
                Button("JFlowerMedia on Instagram") { NSWorkspace.shared.open(AppInfo.instagram) }
            }
        }
    }

    // MARK: - Credits

    /// The standard About panel, with the byline and clickable links in the credits area.
    private static func showAbout() {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center

        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred
        ]

        func link(_ text: String, _ url: URL) -> NSAttributedString {
            var attrs = body
            attrs[.link] = url
            return NSAttributedString(string: text, attributes: attrs)
        }

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Downloads video and audio with yt-dlp.\n\n"
                  + "\(AppInfo.versionLabel) — expect rough edges.\n\nBuilt by JFlowerMedia\n",
            attributes: body))
        credits.append(link("jflowermedia.com", AppInfo.website))
        credits.append(NSAttributedString(string: "   ·   ", attributes: body))
        credits.append(link("Instagram", AppInfo.instagram))

        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: AppInfo.version,
        ])
    }
}
