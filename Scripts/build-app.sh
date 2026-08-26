#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-release}"

# The app's own vision-language model is a build-time option, because MLX
# compiles Metal kernels and the `metal` compiler ships with Xcode rather than
# with the Command Line Tools. Without it the app still builds and runs — it
# just has Apple's engines and no model of its own.
#
# It is now included whenever this Mac can compile it, rather than only when
# somebody remembered to ask for it. Off-unless-asked is what produced the bug
# this is fixing: `make install` on a Mac with Xcode on it built the smaller
# app, and the smaller app's Models screen listed five models, priced them,
# marked one as suiting the machine, and could not fetch any of them.
#
# MLX=0 builds without the engine deliberately. MLX=1 insists on it and fails
# rather than quietly handing back the smaller app. The Xcode to use is found
# rather than assumed: a machine may have a beta, a release, or both, and
# `xcode-select` may still be pointed at the Command Line Tools.
want_mlx="${MLX:-auto}"
traits_argument=()
developer_dir="${DEVELOPER_DIR:-}"

if [[ "$want_mlx" != "0" ]]; then
    if [[ -z "$developer_dir" ]]; then
        active="$(xcode-select -p 2>/dev/null || true)"
        if [[ "$active" == *Xcode*/Contents/Developer ]]; then
            developer_dir="$active"
        else
            for candidate in /Applications/Xcode*.app; do
                if [[ -d "$candidate/Contents/Developer" ]]; then
                    developer_dir="$candidate/Contents/Developer"
                    break
                fi
            done
        fi
    fi

    # Asked of the toolchain that would actually be used, rather than of
    # whichever one `xcode-select` happens to point at.
    if [[ -n "$developer_dir" ]] \
        && DEVELOPER_DIR="$developer_dir" xcrun -f metal >/dev/null 2>&1; then
        export DEVELOPER_DIR="$developer_dir"
        traits_argument=(--traits MLXEngine)
        echo "Building with the app's own vision model, using $DEVELOPER_DIR"
    elif [[ "$want_mlx" == "1" ]]; then
        if [[ -z "$developer_dir" ]]; then
            echo "MLX=1 needs Xcode, which supplies the Metal compiler."
            echo "Install Xcode, or build without MLX=1."
        else
            echo "Xcode is here but the Metal toolchain is not."
            echo "Run: xcodebuild -downloadComponent MetalToolchain"
        fi
        exit 1
    else
        # Said here as well as in the app, because somebody watching a build
        # scroll past is owed the reason before they go looking for it in a
        # settings window.
        echo "Building without the app's own vision model."
        if [[ -z "$developer_dir" ]]; then
            echo "  The Metal compiler comes with Xcode; the Command Line"
            echo "  Tools do not include it."
        else
            echo "  Xcode is here but the Metal toolchain is not."
            echo "  Run: xcodebuild -downloadComponent MetalToolchain"
        fi
        echo "  Settings -> Models in the app will say the same thing."
    fi
fi

app_dir="$project_dir/dist/Laesesalen.app"
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
