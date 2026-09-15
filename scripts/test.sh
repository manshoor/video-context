#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$project_root/.build"
module_cache="$build_root/ModuleCache"

mkdir -p "$module_cache"
CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
swift test --disable-sandbox --scratch-path "$build_root" "$@"
