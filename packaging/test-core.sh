#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if xcodebuild -version >/dev/null 2>&1; then
    exec swift test --disable-xctest "$@"
fi

frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
exec swift test --build-system native --disable-xctest \
    -Xswiftc "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks" "$@"
