#!/bin/zsh
# Compile et lance les tests fonctionnels (aucune donnée personnelle n'est modifiée).
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
sed 's/^@main//' Sources/App.swift > "$OUT/AppSansMain.swift"
swiftc -Onone -swift-version 5 -target arm64-apple-macos14 \
  $(ls Sources/*.swift | grep -v '/App.swift') "$OUT/AppSansMain.swift" Tests/main.swift -o "$OUT/tests"
"$OUT/tests"
