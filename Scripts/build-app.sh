#!/bin/zsh
# Builds SnappySnap.app into build/ and signs it.
# CONFIG=debug|release (default release). The identity comes from Scripts/signing.env, which finds the
# Wooflab team's Developer ID Application certificate in the keychain; SIGN_IDENTITY in the environment
# overrides it, and "-" signs ad-hoc for a throwaway build.
set -euo pipefail
ROOT="${0:A:h:h}"
CONFIG="${CONFIG:-release}"

# A debug build exists to read something a release build will not show. It is never installed, and it is
# not made unless the owner has asked for one: DEBUG_OK=1 is how the caller says so.
if [ "$CONFIG" = "debug" ] && [ "${DEBUG_OK:-0}" != "1" ]; then
  echo "refusing to build debug without the owner asking for it." >&2
  echo "A debug build is not installed and is not a way to run the app: Scripts/install.sh is." >&2
  echo "If the owner has asked for one, run: DEBUG_OK=1 CONFIG=debug Scripts/build-app.sh" >&2
  exit 1
fi
cd "$ROOT"
source "$ROOT/Scripts/signing.env"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product SnappySnap 1>&2
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/SnappySnap.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SnappySnap" "$APP/Contents/MacOS/SnappySnap"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
for bundle in "$BIN_DIR"/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# The app icon. `actool` compiles the Icon Composer document into an Assets.car and an .icns, which
# `Info.plist`'s CFBundleIconFile and CFBundleIconName name. It comes with Xcode, so a Mac with only
# the command line tools builds a bundle whose icon keys point at nothing — which macOS treats as no
# icon at all, not as an error. Everything actool prints is progress, so it goes to stderr: stdout
# carries the bundle path and nothing else, and `run.sh` captures it.
ACTOOL=/usr/bin/actool
if [[ -x "$ACTOOL" ]]; then
  ICON_STAGING="$(mktemp -d)"
  "$ACTOOL" "$ROOT/Assets/snappy-snap.icon" \
    --compile "$ICON_STAGING" \
    --app-icon snappy-snap \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$ICON_STAGING/icon.plist" 1>&2
  cp "$ICON_STAGING/Assets.car" "$ICON_STAGING/snappy-snap.icns" "$APP/Contents/Resources/"
  rm -rf "$ICON_STAGING"
else
  echo "warning: $ACTOOL not found (Xcode is not installed) — building without the app icon." 1>&2
fi

# Signing, innermost first. `--deep` is not used: it re-signs what it finds with the outer bundle's flags
# and Apple has deprecated it for anything meant to ship. A real identity also gets the Hardened Runtime and
# a trusted timestamp, both of which notarization refuses a build without; ad-hoc can have neither.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "warning: ad-hoc signing — the Accessibility grant resets on every build, and the result cannot be" 1>&2
  echo "         notarized. A shippable build comes from Scripts/release.sh." 1>&2
  SIGN_FLAGS=()
else
  SIGN_FLAGS=(--options runtime --timestamp)
fi
for bundle in "$APP/Contents/Resources"/*.bundle(N); do
  codesign --force $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$bundle" 1>&2
done
codesign --force $SIGN_FLAGS --entitlements "$ROOT/Resources/SnappySnap.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP" 1>&2
echo "$APP"
