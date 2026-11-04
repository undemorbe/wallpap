#!/bin/zsh
# Builds Wallpap.app (with the embedded wallpaper extension) and installs it into /Applications.
set -euo pipefail
cd "${0:A:h}"

# Signing identity: first "Apple Development" certificate, or ad-hoc.
IDENTITY="${WALLPAP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Wallpap"

mkdir -p build
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 \
  Extension/*.swift -o build/WallpapWallpaper \
  -framework ExtensionFoundation -framework AVFoundation -framework QuartzCore -framework IOSurface -framework IOKit \
  -Xlinker -e -Xlinker _NSExtensionMain

APP="build/Wallpap.app"
EXT="$APP/Contents/Extensions/WallpapWallpaper.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Wallpap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Layered icon (Default / Dark / Clear / Tinted), compiled by scripts/make-icon.swift
[[ -f Resources/Assets.car ]] && cp Resources/Assets.car "$APP/Contents/Resources/"
cp build/WallpapWallpaper "$EXT/Contents/MacOS/WallpapWallpaper"
cp Extension/Info.plist "$EXT/Contents/Info.plist"

# Optional version stamping (used by CI): WALLPAP_VERSION=1.2.3 WALLPAP_BUILD=42 ./build.sh
if [[ -n "${WALLPAP_VERSION:-}" ]]; then
  for plist in "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WALLPAP_VERSION" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${WALLPAP_BUILD:-1}" "$plist"
  done
fi

SIGN=(--force --sign "$IDENTITY" --options runtime)
[[ "$IDENTITY" != "-" ]] && SIGN+=(--timestamp)   # secure timestamp is required for notarization
codesign "${SIGN[@]}" --entitlements Extension/Extension.entitlements "$EXT"
codesign "${SIGN[@]}" "$APP"
echo "Подписано: $IDENTITY"

if [[ "${1:-}" != "--no-install" ]]; then
  rm -rf /Applications/Wallpap.app
  cp -R "$APP" /Applications/
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -f -R /Applications/Wallpap.app >/dev/null 2>&1 || true
  pluginkit -a /Applications/Wallpap.app/Contents/Extensions/WallpapWallpaper.appex >/dev/null 2>&1 || true
  echo "Установлено: /Applications/Wallpap.app"
else
  echo "Собрано: $APP"
fi
