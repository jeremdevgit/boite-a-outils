#!/bin/zsh
# Compile « Boîte à outils.app » (Apple Silicon + Intel) dans ./build
set -e
cd "$(dirname "$0")"
APP="build/Boîte à outils.app"
BIN="BoiteAOutils"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "→ Génération de l'icône"
  swift Resources/make_icon.swift build
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "→ Compilation"
mkdir -p build
# Les deux architectures en parallèle ; -file-prefix-map retire le chemin local des sources du binaire.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14 \
    -file-prefix-map "$PWD=." Sources/*.swift -o build/$BIN-$arch &
done
wait

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create build/$BIN-arm64 build/$BIN-x86_64 -output "$APP/Contents/MacOS/$BIN"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/Licences.txt "$APP/Contents/Resources/"
xattr -cr "$APP"
# Certificat local stable : les autorisations macOS restent valides d'une version à l'autre.
IDENTITY="Boite a outils (local)"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep -s "$IDENTITY" "$APP"
else
  echo "  (certificat local absent : signature ad hoc, les autorisations devront être redonnées après chaque mise à jour)"
  codesign --force --deep -s - "$APP"
fi
echo "✓ $APP"
