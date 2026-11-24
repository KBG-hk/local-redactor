#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_args=(-c release --product LocalRedactor)
if ! xcodebuild -version >/dev/null 2>&1; then
    build_args+=(--build-system native)
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"

mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.bundle.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/LocalRedactor.app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$binary_dir/LocalRedactor" "$app/Contents/MacOS/LocalRedactor"
install -m 644 packaging/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --entitlements packaging/Entitlements.plist "$app"
codesign --verify --strict "$app"

destination="$PWD/dist/LocalRedactor.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging/previous.app"
fi
if ! mv "$app" "$destination"; then
    if [[ -e "$staging/previous.app" ]]; then
        mv "$staging/previous.app" "$destination"
    fi
    exit 1
fi
printf '%s\n' "$destination"
