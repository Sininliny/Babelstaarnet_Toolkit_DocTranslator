#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/Scripts/build-app.sh"

destination="/Applications/Læsesalen.app"
if [[ -d "$destination" ]]; then
    rm -rf "$destination"
fi
cp -R "$project_dir/dist/Læsesalen.app" "$destination"
echo "Installed $destination"
echo "A bundle you built was never downloaded, so Gatekeeper has nothing to"
echo "quarantine and there is no Open Anyway step."
open "$destination"
