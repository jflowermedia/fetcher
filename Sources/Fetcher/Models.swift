import Foundation

// MARK: - yt-dlp JSON

struct VideoInfo: Decodable {
    var id: String?
    var title: String?
    var uploader: String?
    var channel: String?
    var duration: Double?
    var thumbnail: String?
    var type: String?
    var playlistCount: Int?
    var entries: [PlaylistEntry]?
    var formats: [Format]?
    var webpageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, channel, duration, thumbnail, entries, formats
        case type = "_type"
        case playlistCount = "playlist_count"
        case webpageURL = "webpage_url"
    }

    var isPlaylist: Bool { type == "playlist" }

    var displayTitle: String { title ?? id ?? "Untitled" }

    var author: String? { uploader ?? channel }

    /// Real media formats only (drops storyboards / image tracks).
    var mediaFormats: [Format] {
        (formats ?? []).filter { !($0.vcodecName == "none" && $0.acodecName == "none") && $0.ext != "mhtml" }
    }

    var availableHeights: [Int] {
        Array(Set(mediaFormats.compactMap { $0.hasVideo ? $0.height : nil })).sorted(by: >)
    }

    var entryCount: Int { playlistCount ?? entries?.count ?? 0 }
}

struct PlaylistEntry: Decodable {
    var id: String?
    var title: String?
}

struct Format: Decodable, Identifiable, Hashable {
    var formatID: String
    var ext: String?
    var width: Int?
    var height: Int?
    var fps: Double?
    var vcodec: String?
    var acodec: String?
    var filesize: Double?
    var filesizeApprox: Double?
    var tbr: Double?
    var abr: Double?
    var formatNote: String?
    var resolution: String?
    var `protocol`: String?

    var id: String { formatID }

    enum CodingKeys: String, CodingKey {
        case ext, width, height, fps, vcodec, acodec, filesize, tbr, abr, resolution
        case `protocol`
        case formatID = "format_id"
        case filesizeApprox = "filesize_approx"
        case formatNote = "format_note"
    }

    var vcodecName: String { vcodec ?? (resolution == "audio only" ? "none" : "?") }
    var acodecName: String { acodec ?? "?" }

    var hasVideo: Bool { vcodecName != "none" }
    var hasAudio: Bool { acodecName != "none" }

    var kind: FormatKind {
        switch (hasVideo, hasAudio) {
        case (true, true): return .muxed
        case (true, false): return .videoOnly
        default: return .audioOnly
        }
    }

    var size: Double? { filesize ?? filesizeApprox }

    // Non-optional sort keys for the table.
    var sortHeight: Int { height ?? 0 }
    var sortFPS: Double { fps ?? 0 }
    var sortSize: Double { size ?? 0 }
    var sortTBR: Double { tbr ?? 0 }
    var sortExt: String { ext ?? "" }
    var sortNote: String { formatNote ?? "" }

    var resolutionLabel: String {
        if !hasVideo { return "audio only" }
        if let w = width, let h = height { return "\(w)×\(h)" }
        return resolution ?? "?"
    }

    var codecLabel: String {
        switch kind {
        case .muxed: return "\(shortCodec(vcodecName)) + \(shortCodec(acodecName))"
        case .videoOnly: return shortCodec(vcodecName)
        case .audioOnly: return shortCodec(acodecName)
        }
    }

    private func shortCodec(_ c: String) -> String {
        if c.hasPrefix("avc1") { return "H.264" }
        if c.hasPrefix("hvc1") || c.hasPrefix("hev1") { return "HEVC" }
        if c.hasPrefix("vp09") || c == "vp9" { return "VP9" }
        if c.hasPrefix("av01") { return "AV1" }
        if c.hasPrefix("mp4a") { return "AAC" }
        return c
    }
}

enum FormatKind: String, CaseIterable, Identifiable {
    case muxed = "Video + Audio"
    case videoOnly = "Video only"
    case audioOnly = "Audio only"
    var id: String { rawValue }
}

// MARK: - Options

enum DownloadMode: String, CaseIterable, Identifiable {
    case video = "Video (MP4)"
    case audio = "Audio"
    case formats = "All Formats"
    var id: String { rawValue }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, opus, flac, wav
    case original = "best"
    var id: String { rawValue }
    var label: String { self == .original ? "Original" : rawValue.uppercased() }
    var isLossy: Bool { [.mp3, .m4a, .opus].contains(self) }
}

enum AudioBitrate: Int, CaseIterable, Identifiable {
    case k320 = 320, k256 = 256, k192 = 192, k128 = 128
    var id: Int { rawValue }
    var label: String { "\(rawValue) kbps" }
}

enum VideoOutput: String, CaseIterable, Identifiable {
    case original = "Original"
    case mp4Remux = "MP4 (remux)"
    case mkvRemux = "MKV (remux)"
    case mp4Recode = "MP4 (QuickTime-ready)"
    var id: String { rawValue }
}

enum AudioOutput: String, CaseIterable, Identifiable {
    case original = "Original"
    case mp3 = "MP3"
    case m4a = "M4A"
    case flac = "FLAC"
    case wav = "WAV"
    var id: String { rawValue }
}

/// Everything needed to start a download, captured at enqueue time.
struct DownloadRequest {
    var url: String
    var title: String
    var thumbnail: URL?
    var modeLabel: String
    var arguments: [String]
    var outputDir: URL
    /// Re-encode VP9/AV1 results to HEVC afterwards so QuickTime and QuickLook can play them.
    var convertForQuickTime = false
}

// MARK: - Formatting helpers

enum Fmt {
    static func bytes(_ b: Double?) -> String {
        guard let b, b > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    static func duration(_ s: Double?) -> String {
        guard let s, s > 0 else { return "" }
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func speed(_ bps: Double?) -> String {
        guard let bps, bps > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }
}
