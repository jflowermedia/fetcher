import AppKit
import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if manager.hasFinished {
                    Button("Clear Finished") { manager.clearFinished() }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if manager.jobs.isEmpty {
                Text("No downloads yet")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .background(.background)
    }
}

private extension DownloadsView {
    var footer: some View {
        HStack(spacing: 8) {
            Link("JFlowerMedia", destination: AppInfo.website)
                .font(.caption.weight(.medium))
            Text(AppInfo.versionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            let active = manager.jobs.filter { $0.state.isActive }.count
            let queued = manager.jobs.filter { $0.state == .queued }.count
            if active + queued > 0 {
                Text("\(active) downloading" + (queued > 0 ? " · \(queued) queued" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

struct JobRow: View {
    @Environment(DownloadManager.self) private var manager
    let job: DownloadJob
    @State private var showLog = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: job.thumbnail) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.title).fontWeight(.medium).lineLimit(1)
                    if let item = job.itemLabel {
                        Text(item).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let current = job.currentTitle, job.itemIndex != nil, current != job.title, job.state.isActive {
                    Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(job.request.modeLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                progressLine
            }

            Spacer(minLength: 8)
            buttons
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show Log") { showLog = true }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.request.url, forType: .string)
            }
            Divider()
            Button("Remove") { manager.remove(job) }
        }
        .sheet(isPresented: $showLog) { LogView(job: job) }
    }

    @ViewBuilder
    private var progressLine: some View {
        switch job.state {
        case .downloading, .processing, .converting:
            VStack(alignment: .leading, spacing: 2) {
                if job.state == .processing || job.progress == nil {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: job.progress ?? 0).progressViewStyle(.linear)
                }
                Text(job.statusText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .failed:
            Label(job.statusText, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
        case .finished:
            Label(job.statusText, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .queued, .cancelled:
            Text(job.statusText).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 4) {
            switch job.state {
            case .queued, .downloading, .processing, .converting:
                iconButton("xmark.circle.fill", help: "Cancel") { manager.cancel(job) }
            case .finished:
                iconButton("magnifyingglass.circle.fill", help: "Show in Finder") { revealInFinder() }
            case .failed, .cancelled:
                iconButton("arrow.clockwise.circle.fill", help: "Retry") { manager.retry(job) }
                iconButton("doc.text.magnifyingglass", help: "Show Log") { showLog = true }
            }
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func revealInFinder() {
        let existing = job.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(job.request.outputDir)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }
}

struct LogView: View {
    let job: DownloadJob
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.title).font(.headline)
            ScrollView {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640, height: 420)
    }

    private var logText: String {
        var lines = job.log
        lines.append(contentsOf: job.files.map { "Saved: \($0.path)" })
        let cmd = (["yt-dlp"] + job.request.arguments + ["--", job.request.url]).map { arg in
            arg.contains(where: { " \t\"'$%()".contains($0) }) ? "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'" : arg
        }.joined(separator: " ")
        return (["$ " + cmd, ""] + (lines.isEmpty ? ["(no output)"] : lines)).joined(separator: "\n")
    }
}
