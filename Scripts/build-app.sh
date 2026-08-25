#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
app_dir="$project_dir/dist/Læsesalen.app"
binary_dir="$app_dir/Contents/MacOS"
resource_dir="$app_dir/Contents/Resources"
module_cache="$project_dir/.build/module-cache"

cd "$project_dir"
mkdir -p "$module_cache"
env \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    swift build \
    --disable-sandbox \
    -c "$configuration" \
    --product Laesesalen

binary_path="$(
    env \
        CLANG_MODULE_CACHE_PATH="$module_cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
        swift build \
        --disable-sandbox \
        -c "$configuration" \
        --show-bin-path
)/Laesesalen"

rm -rf "$app_dir"
mkdir -p "$binary_dir" "$resource_dir"
cp "$binary_path" "$binary_dir/Laesesalen"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

iconset_dir="$project_dir/.build/Laesesalen.iconset"
rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
env \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    swift "$project_dir/Scripts/generate-app-icon.swift" "$iconset_dir"
iconutil -c icns "$iconset_dir" -o "$resource_dir/Laesesalen.icns"

signing_identity="${SIGNING_IDENTITY:-}"

# Nothing is nested inside the bundle but the icon, so there is no inner code
# to sign and --deep has nothing to reach.
if [[ -n "$signing_identity" ]]; then
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$signing_identity" \
        "$app_dir"
    echo "Signed with $signing_identity"
else
    # A stable designated requirement, so the permissions macOS grants this
    # bundle survive a rebuild instead of being asked for again.
    codesign \
        --force \
        --sign - \
        --requirements '=designated => identifier "dev.sinin.laesesalen"' \
        "$app_dir"
    echo "Ad-hoc signed with a stable designated requirement."
fi

echo "Built $app_dir"
