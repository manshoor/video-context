#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$project_root/.build"
module_cache="$build_root/ModuleCache"
app_bundle="$project_root/dist/Video Context.app"
contents="$app_bundle/Contents"

mkdir -p "$module_cache"

CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
swift build --disable-sandbox --scratch-path "$build_root" -c release -debug-info-format none --product VideoContext

CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
swift build --disable-sandbox --scratch-path "$build_root" -c release -debug-info-format none --product video-context-mcp

bin_path="$(CLANG_MODULE_CACHE_PATH="$module_cache" SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" swift build --disable-sandbox --scratch-path "$build_root" -c release --show-bin-path)"

mkdir -p "$contents/MacOS" "$contents/Resources"
CLANG_MODULE_CACHE_PATH="$module_cache" swift "$project_root/scripts/generate-icon.swift" "$build_root/AppIcon.iconset"
if ! iconutil -c icns "$build_root/AppIcon.iconset" -o "$contents/Resources/AppIcon.icns"; then
    # The icon is unchanged in this build. Keep the existing packaged icon when
    # iconutil rejects a regenerated iconset on the current macOS runtime.
    test -s "$contents/Resources/AppIcon.icns"
    echo "Using the existing AppIcon.icns after iconutil rejected the regenerated iconset."
fi
cp "$project_root/Resources/Info.plist" "$contents/Info.plist"
cp "$bin_path/VideoContext" "$contents/MacOS/VideoContext"
cp "$bin_path/video-context-mcp" "$contents/MacOS/video-context-mcp"
# SwiftPM's flat resource bundle is for command-line builds; a macOS app uses Contents/Resources.
cp "$project_root/Sources/VideoContextApp/Resources/ModelProbe.jpg" "$contents/Resources/ModelProbe.jpg"
if [[ -d "$contents/MacOS/VideoContext_VideoContextApp.bundle" ]]; then
    rm -rf -- "$contents/MacOS/VideoContext_VideoContextApp.bundle"
fi
chmod 755 "$contents/MacOS/VideoContext" "$contents/MacOS/video-context-mcp"

codesign --force --deep --sign - "$app_bundle"
echo "$app_bundle"
