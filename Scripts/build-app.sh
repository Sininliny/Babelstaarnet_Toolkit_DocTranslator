#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-release}"

# The app's own vision-language model is a build-time option, because MLX
# compiles Metal kernels and the `metal` compiler ships with Xcode rather than
# with the Command Line Tools. Without Xcode the app still builds and runs —
# it just has Apple's engines and no model of its own.
#
# Set MLX=1 to include it. The Xcode to use is found rather than assumed: a
# machine may have a beta, a release, or both, and `xcode-select` may still be
# pointed at the Command Line Tools.
traits_argument=()
if [[ "${MLX:-0}" == "1" ]]; then
    if [[ -z "${DEVELOPER_DIR:-}" ]]; then
        active="$(xcode-select -p 2>/dev/null || true)"
        if [[ "$active" == *Xcode*/Contents/Developer ]]; then
            export DEVELOPER_DIR="$active"
        else
            for candidate in /Applications/Xcode*.app; do
                if [[ -d "$candidate/Contents/Developer" ]]; then
                    export DEVELOPER_DIR="$candidate/Contents/Developer"
                    break
                fi
            done
        fi
    fi
    if [[ -z "${DEVELOPER_DIR:-}" ]]; then
        echo "MLX=1 needs Xcode, which supplies the Metal compiler."
        echo "Install Xcode, or build without MLX=1."
        exit 1
    fi
    if ! xcrun -f metal >/dev/null 2>&1; then
        echo "Xcode is here but the Metal toolchain is not."
        echo "Run: xcodebuild -downloadComponent MetalToolchain"
        exit 1
    fi
    traits_argument=(--traits MLXEngine)
    echo "Building with the local vision model, using $DEVELOPER_DIR"
fi
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
    "${traits_argument[@]}" \
    --product Laesesalen

binary_path="$(
    env \
        CLANG_MODULE_CACHE_PATH="$module_cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
        swift build \
        --disable-sandbox \
        -c "$configuration" \
        "${traits_argument[@]}" \
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
