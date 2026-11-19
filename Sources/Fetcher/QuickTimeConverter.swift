import Foundation

/// YouTube only serves H.264 up to 1080p; above that it's VP9 or AV1, which QuickTime and
/// QuickLook can't decode (AV1 only on M3 and later). This re-encodes such files to HEVC with
/// the hardware encoder, and Opus/Vorbis audio to AAC, copying everything else untouched.
enum QuickTimeConverter {
    /// Codecs AVFoundation decodes on every Apple Silicon Mac.
    static let playableCodecs: Set<String> = ["h264", "hevc", "prores", "mpeg4"]
    /// Opus and Vorbis are the usual misfits: QuickTime won't play them inside an MP4.
    static let playableAudioCodecs: Set<String> = ["aac", "alac", "mp3", "ac3", "eac3"]

    /// VideoToolbox quality, 1–100. 55 lands around 1.4× the size of the VP9 source;
    /// 50 matches its size but loses a little more in the re-encode.
    static let quality = 55

    struct Probe {
        var videoCodec: String
        var audioCodecs: [String]
        var duration: Double
        /// Index of the cover art among the file's video streams (`0:v:N`), if there is one.
        var coverIndex: Int?
    }

    static var ffprobePath: String? { YtDlp.find("ffprobe") }

    /// nil when the file has no video stream or can't be read.
    static func probe(_ url: URL) async -> Probe? {
        guard let exe = ffprobePath,
              let result = try? await YtDlp.run(exe, [
                  "-v", "error", "-of", "json",
                  "-show_entries", "stream=codec_type,codec_name:stream_disposition=attached_pic:format=duration",
                  url.path,
              ]),
              result.0 == 0,
              let json = try? JSONSerialization.jsonObject(with: result.1) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else { return nil }

        func isAttachedPic(_ s: [String: Any]) -> Bool {
            ((s["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
        }
        let video = streams.filter { $0["codec_type"] as? String == "video" }
        guard let main = video.first(where: { !isAttachedPic($0) }),
              let codec = main["codec_name"] as? String else { return nil }
        let duration = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init) ?? 0
        let audio = streams.filter { $0["codec_type"] as? String == "audio" }.compactMap { $0["codec_name"] as? String }
        return Probe(videoCodec: codec, audioCodecs: audio, duration: duration,
                     coverIndex: video.firstIndex(where: isAttachedPic))
    }

    static func videoNeedsConversion(_ probe: Probe) -> Bool { !playableCodecs.contains(probe.videoCodec) }

    static func audioNeedsConversion(_ probe: Probe) -> Bool {
        probe.audioCodecs.contains { !playableAudioCodecs.contains($0) }
    }

    static func needsConversion(_ url: URL, _ probe: Probe) -> Bool {
        url.pathExtension.lowercased() == "mp4" && (videoNeedsConversion(probe) || audioNeedsConversion(probe))
    }

    /// What the job row says while this file converts.
    static func summary(_ probe: Probe) -> String {
        switch (videoNeedsConversion(probe), audioNeedsConversion(probe)) {
        case (true, true): return "\(probe.videoCodec) video and \(probe.audioCodecs.joined(separator: "/")) audio to HEVC and AAC"
        case (true, false): return "\(probe.videoCodec) video to HEVC"
        default: return "\(probe.audioCodecs.joined(separator: "/")) audio to AAC"
        }
    }

    /// Writes progress as `out_time_us=…` lines on stdout.
    static func arguments(input: URL, output: URL, probe: Probe) -> [String] {
        var a = ["-v", "error", "-y", "-i", input.path,
                 "-map", "0:V:0", "-map", "0:a?", "-map", "0:s?"]
        if let cover = probe.coverIndex { a += ["-map", "0:v:\(cover)"] }
        a += ["-map_metadata", "0", "-map_chapters", "0",
              "-c", "copy"]
        if videoNeedsConversion(probe) {
            a += ["-c:v:0", "hevc_videotoolbox", "-q:v:0", "\(quality)", "-tag:v:0", "hvc1"]
        }
        if audioNeedsConversion(probe) { a += ["-c:a", "aac", "-b:a", "192k"] }
        if probe.coverIndex != nil { a += ["-disposition:v:1", "attached_pic"] }
        a += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        return a
    }

    /// Where the HEVC copy is written before it replaces the original.
    static func tempURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("hevc-converting.mp4")
    }
}
