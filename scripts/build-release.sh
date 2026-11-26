#!/usr/bin/env bash
# Baut RepoWatch im Release-Modus und packt ein DMG (Plan Phase 6).
#
#   scripts/build-release.sh 1.0.0
#
# Signieren und Notarisieren passieren nur, wenn die Umgebungsvariablen gesetzt sind:
#   DEVELOPER_ID_IDENTITY  z. B. "Developer ID Application: Max Muster (ABCDE12345)"
#   DEVELOPER_TEAM_ID      z. B. ABCDE12345
#   NOTARY_KEY_PATH        Pfad zur .p8-Datei eines App-Store-Connect-API-Schlüssels
#   NOTARY_KEY_ID          Key-ID dieses Schlüssels
#   NOTARY_ISSUER_ID       Issuer-ID
# Ohne sie wird ad hoc signiert: Das DMG läuft dann nur nach „Rechtsklick → Öffnen“.
set -euo pipefail

VERSION="${1:?Version angeben, z. B. 1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
DMG="$OUT/RepoWatch-$VERSION.dmg"

rm -rf "${OUT:?}"
mkdir -p "$OUT"
cd "$ROOT"
xcodegen generate --quiet

if [[ -n "${DEVELOPER_ID_IDENTITY:-}" && -n "${DEVELOPER_TEAM_ID:-}" ]]; then
  echo "→ Signiere mit: $DEVELOPER_ID_IDENTITY"
  SIGNING=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY"
    DEVELOPMENT_TEAM="$DEVELOPER_TEAM_ID"
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
  SIGNED=1
else
  echo "→ Keine Developer-ID gesetzt: ad hoc signiert, nicht notarisiert."
  SIGNING=(CODE_SIGN_IDENTITY=-)
  SIGNED=0
fi

xcodebuild \
  -project RepoWatch.xcodeproj \
  -scheme RepoWatch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$OUT/DerivedData" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${SIGNING[@]}" \
  build | grep -E "error:|warning: .*(App|Sources)/|BUILD" || true

APP="$OUT/DerivedData/Build/Products/Release/RepoWatch.app"
[[ -d "$APP" ]] || { echo "Build fehlgeschlagen: $APP fehlt" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "→ App gebaut und Signatur gültig: $APP"

# DMG mit Verknüpfung zum Programme-Ordner
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "RepoWatch $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "${STAGING:?}"

if [[ "$SIGNED" == 1 ]]; then
  codesign --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    echo "→ Notarisiere (kann einige Minuten dauern) …"
    xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  else
    echo "→ Signiert, aber nicht notarisiert (NOTARY_* fehlt)."
  fi
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "→ Fertig: $DMG"
echo "signed=$SIGNED" > "$OUT/build-info"
