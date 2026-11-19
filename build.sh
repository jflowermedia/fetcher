#!/bin/bash
# Builds build/ytdl.app (release, ad-hoc signed).
#
#   ./build.sh           build build/ytdl.app
#   ./build.sh --open    build it and launch it
#   ./build.sh --install build it, copy it into /Applications and launch it from there
#   ./build.sh --zip     build it and package build/ytdl-<version>.zip for a GitHub release
#
# Options combine, e.g. ./build.sh --install --zip
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ytdl.app
# Single source of truth for the version: AppInfo.version in YtdlApp.swift.
VERSION="$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/ytdl/YtdlApp.swift | head -1)"
echo "Version: $VERSION"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ytdl"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ytdl"

# App icon
ICONSET=build/AppIcon.iconset
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ytdl</string>
  <key>CFBundleDisplayName</key><string>ytdl</string>
  <key>CFBundleIdentifier</key><string>local.ytdl</string>
  <key>CFBundleExecutable</key><string>ytdl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Built by JFlowerMedia · jflowermedia.com</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

for arg in "$@"; do
  case "$arg" in
    --open) open "$APP" ;;
    --install)
      # Quit a running copy first; replacing an app out from under itself can crash it.
      osascript -e 'quit app "ytdl"' 2>/dev/null || true
      while pgrep -xq ytdl; do sleep 0.2; done
      rm -rf /Applications/ytdl.app
      ditto "$APP" /Applications/ytdl.app
      touch /Applications/ytdl.app          # nudges Finder to pick up a changed icon
      echo "Installed to /Applications/ytdl.app"
      open /Applications/ytdl.app ;;
    --zip)
      ZIP="build/ytdl-$VERSION.zip"
      rm -f "$ZIP"
      ditto -c -k --keepParent "$APP" "$ZIP"   # ditto, not zip: preserves the bundle
      echo "Packaged $ZIP" ;;
  esac
done
exit 0
