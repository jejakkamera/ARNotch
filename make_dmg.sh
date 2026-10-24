#!/bin/zsh
# Builds ARNotch.app (release) and packs it into dist/ARNotch-<version>.dmg with an Applications shortcut.
# Usage: ./make_dmg.sh
set -e
cd "${0:A:h}"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/ARNotch.app/Contents/Info.plist)
OUT="dist/ARNotch-$VERSION.dmg"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/stage"
ditto dist/ARNotch.app "$WORK/stage/ARNotch.app"
ln -s /Applications "$WORK/stage/Applications"

# Writable image first so the volume can get the app icon, then compress.
hdiutil create -volname "ARNotch" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -size 40m -ov "$WORK/rw.dmg" >/dev/null 2>&1
MNT=$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -nobrowse 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}')
cp Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -c icnC "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"
sync
hdiutil detach "$MNT" >/dev/null 2>&1

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null 2>&1
hdiutil verify "$OUT" >/dev/null 2>&1
echo "Built $OUT"
