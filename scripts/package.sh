#!/bin/zsh
# Packs build/Wallpap.app into dist/Wallpap.dmg and dist/Wallpap.zip (+ SHA256SUMS.txt).
#   scripts/package.sh 1.2.3
# Set WALLPAP_SIGN_IDENTITY to sign the DMG with a Developer ID certificate.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: scripts/package.sh <version>}"
APP="build/Wallpap.app"
DIST="dist"
NAME="Wallpap"   # stable names keep releases/latest/download/Wallpap.dmg working

[[ -d "$APP" ]] || { echo "Нет $APP — сначала запустите ./build.sh --no-install" >&2; exit 1; }
rm -rf "$DIST" && mkdir -p "$DIST"

# ZIP (ditto keeps signatures, symlinks and extended attributes intact)
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

# DMG with an Applications shortcut for drag-and-drop install
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Wallpap $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/$NAME.dmg" >/dev/null

if [[ -n "${WALLPAP_SIGN_IDENTITY:-}" && "${WALLPAP_SIGN_IDENTITY}" != "-" ]]; then
  codesign --force --timestamp --sign "$WALLPAP_SIGN_IDENTITY" "$DIST/$NAME.dmg"
fi

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
ls -lh "$DIST"
