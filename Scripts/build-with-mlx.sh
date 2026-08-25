#!/bin/zsh

set -euo pipefail

# `swift build --traits MLXEngine`, with Xcode found rather than assumed.
#
# Kept apart from build-app.sh so that `make build-mlx` and `make test-mlx`
# can use the same discovery without assembling an app bundle.

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
    echo "This needs Xcode, which supplies the Metal compiler MLX is built"
    echo "against. The Command Line Tools do not include it."
    exit 1
fi

if ! xcrun -f metal >/dev/null 2>&1; then
    echo "Xcode is installed but the Metal toolchain is a separate download."
    echo "Run: xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

echo "Using $DEVELOPER_DIR"
exec swift "${1:-build}" --traits MLXEngine "${@:2}"
