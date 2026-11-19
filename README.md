# ytdl

**Paste a link, get the file.** A native Mac app for [yt-dlp](https://github.com/yt-dlp/yt-dlp): MP4 that plays in QuickTime, audio as MP3 or lossless, or any format a site offers, without remembering a single flag.

Built by [JFlowerMedia](https://jflowermedia.com/) · [Download](../../releases) · macOS 14 or later

> **Alpha, version 0.1.0.** Tested on one Mac with YouTube. Bug reports welcome in [Issues](../../issues).

## Features

- **Video (MP4)** — pick a quality from Best down to 360p. H.264 and AAC are preferred, so files play everywhere, QuickTime included.
- **Audio** — MP3 at the bitrate you choose, M4A, Opus, FLAC, WAV or the original stream, with cover art and metadata.
- **All Formats** — a sortable table of every stream on offer. Pick a video-only stream and the best audio is merged in. Keep the original, remux to MP4 or MKV, or re-encode to MP4.
- **Clips** — download just 1:20 to 2:45 instead of the whole video. **Precise cuts** re-encodes at the cut points so the clip starts exactly where you asked.
- **Many links at once** — paste or drop several links and they all queue with the same settings.
- **Copied links fill themselves in** when you switch to ytdl. Turn it off under **Edit → Fill In Copied Links Automatically**.
- **Playlists**, embedded subtitles and chapters, up to three downloads at a time, cancel and retry, and a log for every download.
- **Keeps yt-dlp current** — sites change often and old versions of yt-dlp stop working. ytdl warns when yt-dlp is over 60 days old and updates it in one click.

## Install

ytdl drives yt-dlp and ffmpeg, so install those first with [Homebrew](https://brew.sh):

```
brew install yt-dlp ffmpeg deno
```

(deno is what yt-dlp uses to get past YouTube's JavaScript checks.)

Then download `ytdl-0.1.0.zip` from [Releases](../../releases), unzip, and drag **ytdl.app** to Applications.

ytdl isn't notarized by Apple, so macOS blocks the first launch:

1. Open ytdl and click **Done** on the warning.
2. Go to **System Settings → Privacy & Security** and click **Open Anyway** beside ytdl.
3. Open ytdl again and click **Open**.

Or run `xattr -dr com.apple.quarantine /Applications/ytdl.app` once.

**Build from source** (needs Xcode's command line tools):

```
git clone https://github.com/jflowermedia/ytdl.git
cd ytdl
./build.sh --open
```

See [DEVELOPING.md](DEVELOPING.md) for more.

## Shortcuts

| Keys | Does |
|---|---|
| ⇧⌘V | Paste a link from the clipboard |
| Return | Fetch the link's info |
| ⌘Return | Download |

## Troubleshooting

- **Downloads suddenly failing?** Update yt-dlp: **ytdl → Update yt-dlp**. Site changes break old versions.
- **A download failed?** Click the log button on its row. It shows the exact yt-dlp command, so you can run it in Terminal yourself.
- **"yt-dlp wasn't found"** — ytdl looks in `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`.
- **MP4 won't play in QuickTime above 1080p** — YouTube only offers H.264 up to 1080p. Higher resolutions are VP9 or AV1, which QuickTime can't play. Use IINA or VLC, or choose 1080p.

## Known gaps

- Settings for the filename template, parallel downloads and speed limits aren't exposed yet.
- Downloads aren't remembered across relaunches.

## Credits

Built by **JFlowerMedia** · [jflowermedia.com](https://jflowermedia.com/) · [@jflowermedia](https://www.instagram.com/jflowermedia/)

All the downloading is done by [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org/). ytdl is a front end for them.

## License

MIT, see [LICENSE](LICENSE).

## Disclaimer

ytdl is alpha software, provided as is, without warranty. Only download content you have the right to download, and respect each site's terms of service and the creator's copyright. No liability is accepted for how it's used.
