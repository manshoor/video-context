#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_executable="$project_root/dist/Video Context.app/Contents/MacOS/VideoContext"

if otool -L "$app_executable" | grep -Eq '/AVKit.framework/|/_AVKit_SwiftUI.framework/'; then
    echo "FAIL: VideoContext links AVKit, which loads the private _AVKit_SwiftUI bridge from the crash report."
    exit 1
fi

codesign --verify --deep --strict "$project_root/dist/Video Context.app"
plutil -lint "$project_root/dist/Video Context.app/Contents/Info.plist"
test -s "$project_root/dist/Video Context.app/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconFile' "$project_root/dist/Video Context.app/Contents/Info.plist")" = "AppIcon"
test -s "$project_root/dist/Video Context.app/Contents/Resources/ModelProbe.jpg"
file "$app_executable" "$project_root/dist/Video Context.app/Contents/MacOS/video-context-mcp"
echo "App bundle checks passed."
