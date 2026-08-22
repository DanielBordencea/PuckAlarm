#!/bin/bash
# Type-checks both targets against the iOS SDK without needing a simulator runtime,
# a device, or a signing identity. Useful as a fast pre-build gate.
#
#   ./typecheck.sh            # Swift 6 language mode (what the project ships with)
#   ./typecheck.sh 5          # Swift 5, for comparing against the older mode
#
# The file lists come from generate_project.py so this can never drift out of sync with
# what actually gets compiled — an earlier hand-maintained copy of the list did exactly
# that and reported "clean" while a new file was not being checked at all.

set -uo pipefail
cd "$(dirname "$0")"

SWIFT_VERSION="${1:-6}"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
TARGET_TRIPLE="arm64-apple-ios$(python3 - <<'PY'
import re, pathlib
src = pathlib.Path("generate_project.py").read_text()
print(re.search(r'DEPLOYMENT_TARGET\s*=\s*"([^"]+)"', src).group(1))
PY
)"

read_list() {
    python3 - "$1" <<'PY'
import ast, re, sys, pathlib
src = pathlib.Path("generate_project.py").read_text()
name = sys.argv[1]
print("\n".join(ast.literal_eval(re.search(name + r"\s*=\s*(\[[^]]*\])", src, re.S).group(1))))
PY
}

# `mapfile` is bash 4+; macOS ships bash 3.2, so read the lists the portable way.
SHARED=(); APP_ONLY=(); EXT_ONLY=()
while IFS= read -r line; do SHARED+=("$line"); done < <(read_list SHARED_SOURCES)
while IFS= read -r line; do APP_ONLY+=("$line"); done < <(read_list APP_ONLY_SOURCES)
while IFS= read -r line; do EXT_ONLY+=("$line"); done < <(read_list EXT_ONLY_SOURCES)

status=0

check() {
    local name=$1
    shift
    echo "=== $name (Swift $SWIFT_VERSION) ==="
    local output
    output=$(xcrun swiftc -typecheck -sdk "$SDK" -target "$TARGET_TRIPLE" \
        -swift-version "$SWIFT_VERSION" "$@" 2>&1 | grep -E "error|warning:")
    if [ -z "$output" ]; then
        echo "clean"
    else
        echo "$output"
        status=1
    fi
}

check "app target" "${SHARED[@]}" "${APP_ONLY[@]}"
check "widget target" -parse-as-library "${SHARED[@]}" "${EXT_ONLY[@]}"

exit $status
