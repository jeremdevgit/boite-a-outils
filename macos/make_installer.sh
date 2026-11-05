#!/bin/zsh
# Crée les installateurs (.dmg et .pkg) de la Boîte à outils dans ./dist
set -e
cd "$(dirname "$0")"
./build.sh
APP="build/Boîte à outils.app"
VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
OUT="$PWD/dist"
mkdir -p "$OUT"
STAGE="build/dmg"

echo "→ Image disque"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Lisez-moi.txt" <<TXT
Boîte à outils $VERSION — installation

1. Glissez « Boîte à outils » sur le dossier « Applications ».
2. Ouvrez-la depuis le Launchpad ou le dossier Applications.

Une version déjà installée est simplement remplacée (vos réglages sont conservés).

Si macOS indique que l'app ne peut pas être vérifiée :
Réglages Système › Confidentialité et sécurité › « Ouvrir quand même ».

Créé par jeremdevgit — https://github.com/jeremdevgit

Conseillé : Réglages Système › Confidentialité et sécurité ›
Accès complet au disque › ajoutez « Boîte à outils ».
TXT
DMG="$OUT/Boite-a-outils-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Boîte à outils $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

echo "→ Paquet d'installation"
PKGROOT="build/pkgroot"
rm -rf "$PKGROOT" && mkdir -p "$PKGROOT/Applications"
cp -R "$APP" "$PKGROOT/Applications/"
PKG="$OUT/Boite-a-outils-$VERSION.pkg"
# Toujours installer dans /Applications (sinon macOS peut « mettre à jour » une copie trouvée ailleurs)
pkgbuild --analyze --root "$PKGROOT" build/component.plist >/dev/null
plutil -replace 0.BundleIsRelocatable -bool false build/component.plist
pkgbuild --root "$PKGROOT" --ownership recommended --scripts Resources/pkg-scripts --component-plist build/component.plist --identifier com.boiteaoutils.mac \
         --version "$VERSION" --install-location / "$PKG" >/dev/null

# Ne laisse aucune copie de l'app hors de l'installateur (évite les doublons Spotlight / « Ouvrir avec »)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
rm -rf build
(cd "$OUT" && shasum -a 256 "Boite-a-outils-$VERSION.dmg" "Boite-a-outils-$VERSION.pkg" > SHA256SUMS-macos.txt)

echo "✓ $DMG"
echo "✓ $PKG"
