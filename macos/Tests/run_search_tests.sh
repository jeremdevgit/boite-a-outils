#!/bin/zsh
# Read-only search tests; all files are temporary demonstration fixtures.
set -euo pipefail
cd "${0:A:h}/.."
OUT=$(mktemp -d)
swiftc -module-cache-path "$OUT/ModuleCache" Sources/FileSearchIndex.swift Tests/FileSearch/main.swift -o "$OUT/search-tests"
"$OUT/search-tests"
