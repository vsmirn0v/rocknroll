#!/bin/bash
set -euo pipefail
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-update-safety.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
cat > "$build_dir/LocalizationShim.swift" <<'EOF'
import Foundation

func L(_ key: String, _ arguments: CVarArg...) -> String {
    guard !arguments.isEmpty else { return key }
    return String(format: key, arguments: arguments)
}
EOF
swiftc -swift-version 5 -parse-as-library -D NATIVE_UPDATE_SAFETY_STANDALONE \
    "$build_dir/LocalizationShim.swift" \
    "$source_dir/Updates/UpdateSafety.swift" "$source_dir/Tests/Parity/UpdateSafetyTests.swift" \
    -o "$build_dir/update-safety-tests"
"$build_dir/update-safety-tests"
