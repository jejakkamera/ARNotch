#!/bin/zsh
# Builds ARNotch.app into ./dist (release, ad-hoc signed). Usage: ./build.sh [--install]  (--install copies to /Applications)
set -e
cd "${0:A:h}"
/usr/bin/swift build -c release --arch arm64
BIN="$(/usr/bin/swift build -c release --arch arm64 --show-bin-path)/ARNotch"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }
APP="dist/ARNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ARNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# An ad-hoc signature's identity changes with every build, so macOS stops honouring earlier Camera, Calendars
# and Automation grants after an update. A real certificate keeps them across rebuilds: use CREST_SIGN_IDENTITY
# if set, otherwise the first "Apple Development" identity in the keychain, otherwise fall back to ad-hoc.
SIGN_ID="${CREST_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}"
# System-wide now-playing helper, loaded by /usr/bin/perl at runtime (see Helpers/NowPlayingBridge.m).
HELPER="$APP/Contents/Resources/libCrestNowPlaying.dylib"
xcrun clang -isysroot "$(xcrun --show-sdk-path)" -arch arm64 -mmacosx-version-min=14.0 -dynamiclib -fobjc-arc -O2 \
  -framework Foundation Helpers/NowPlayingBridge.m -o "$HELPER"
codesign --force --sign "${SIGN_ID:--}" --timestamp=none "$HELPER"
codesign --force --sign "${SIGN_ID:--}" --timestamp=none "$APP"
echo "Signed with: ${SIGN_ID:-ad-hoc}"
echo "Built $APP"
if [[ "$1" == "--install" ]]; then
  pkill -x ARNotch 2>/dev/null || true
  pkill -x Crest 2>/dev/null || true
  rm -rf /Applications/ARNotch.app
  cp -R "$APP" /Applications/ARNotch.app
  echo "Installed to /Applications/ARNotch.app"
fi
