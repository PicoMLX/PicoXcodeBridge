#!/bin/bash
# Builds "Pico Xcode Bridge.app" from the Swift package and signs it with the hardened runtime.
#
#   Scripts/build-app.sh [release|debug]
#
# Environment:
#   SIGN_IDENTITY         The codesign identity. By default the first "Developer ID Application"
#                         identity in the keychain, else the first "Apple Development" one, else
#                         ad hoc ("-"). If signing with it fails, the script signs ad hoc.
#   PROVISIONING_PROFILE  A provisioning profile that lists group.com.starlingprotocol.pico. With
#                         it, the app is signed with the app-group entitlement and the profile is
#                         embedded. Without it, the app has no entitlements and its defaults go to
#                         ~/Library/Preferences instead of the group container, so Pico can't find
#                         it. See README.md, Signing.
#   OUTPUT_DIR            Where the app goes. Default: .build/app
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-.build/app}"
APP="$OUTPUT_DIR/Pico Xcode Bridge.app"

swift build -c "$CONFIGURATION" --product PicoXcodeBridge
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/PicoXcodeBridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/PicoXcodeBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ENTITLEMENTS=()
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS=(--entitlements Resources/PicoXcodeBridge.entitlements)
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  for kind in "Developer ID Application" "Apple Development"; do
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n "s/.*\"\($kind: .*\)\"$/\1/p" | head -1)"
    [[ -n "$SIGN_IDENTITY" ]] && break
  done
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

# Notarization needs a secure timestamp; other builds skip the round trip to Apple.
TIMESTAMP=--timestamp=none
[[ "$SIGN_IDENTITY" == "Developer ID Application"* ]] && TIMESTAMP=--timestamp

if ! codesign --force --options runtime "$TIMESTAMP" ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} --sign "$SIGN_IDENTITY" "$APP"; then
  echo "Signing with \"$SIGN_IDENTITY\" failed; signing ad hoc instead." >&2
  SIGN_IDENTITY=-
  codesign --force --options runtime --timestamp=none ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
echo "Signed with: $SIGN_IDENTITY"
echo "$APP"
