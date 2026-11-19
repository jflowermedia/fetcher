# Developing Fetcher

Notes to self. Everything runs from the project folder:

    cd ~/Documents/GitHub/ytdl

## Everyday change

1. Edit the files in `Sources/Fetcher/`.
2. `swift run Fetcher --self-check` — downloads a 19-second video in every mode through the real download queue, checks the files with ffprobe and AVFoundation, and cancels one mid-download. About two minutes. Add `--offline` for just the parsing checks.
3. `swift run` — builds and launches straight from source. Fastest way to try something.
4. When happy: `./build.sh --install` builds the real app, puts it in /Applications and opens it.
5. Commit and push:

```
git add .
git commit -m "Short description of what changed"
git push
```

Pushing does **not** give anyone a new app. Downloads come from Releases.

## Cutting a release

1. Bump the version: `AppInfo.version` near the top of `Sources/Fetcher/FetcherApp.swift`. That's the only place — the build script reads it and stamps the app bundle to match. Drop `stage` to `"beta"` or `""` when it earns it.
2. Commit and push that change.
3. `./build.sh --zip` — builds and packages `build/Fetcher-<version>.zip` with `ditto` (Finder's Compress can break an app bundle).
4. Publish it:

```
gh release create v0.2.0-alpha build/Fetcher-0.2.0.zip --prerelease --title "Fetcher 0.2" --notes "What changed"
```

## The app icon

`scripts/make-icon.swift` draws it; `build.sh` turns it into `AppIcon.icns` whenever the script changes.

## Where things live

- `YtDlp.swift` — finding the binaries, fetching info, and every yt-dlp argument the app passes.
- `DownloadManager.swift` — the queue, running yt-dlp, and parsing its progress lines.
- `Updater.swift` — yt-dlp's age and the one-click update (`brew upgrade yt-dlp`, or `yt-dlp -U` outside Homebrew).
- The log button on a download shows the exact command, so a failure can be reproduced in Terminal.
