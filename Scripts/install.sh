#!/bin/zsh
# **Install locally.** One of the two ways a build of this app ever reaches a Mac.
#
#   Scripts/install.sh
#
# Builds the same signed, notarized, stapled production bundle a release ships, at the version the rule in
# Scripts/version.sh gives, puts it in /Applications, and leaves nothing behind: when this script returns
# there is no .app and no .dmg anywhere under the repository, so nothing but /Applications can be launched
# by Spotlight, opened by the Finder, or started at login.
#
# The other way is Scripts/publish.sh, which does all of this and puts the disk image on GitHub as well.
#
# There is no third way. A debug build is for reading a crash a release build will not show, it is never
# installed, and it is not made without the owner asking for it (see Scripts/build-app.sh).
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/Scripts/signing.env"
source "$ROOT/Scripts/version.sh"
source "$ROOT/Scripts/no-leftovers.sh"

DEST="/Applications/$APP_NAME.app"
MOUNT=""

# Whatever happens — a failed build, a refused install, an interrupt — the repository is left with nothing
# launchable in it. This runs on the way out of every path through the script.
cleanup() {
  [ -n "$MOUNT" ] && [ -d "$MOUNT" ] && /usr/bin/hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  no_leftovers "$ROOT"
}
trap cleanup EXIT INT TERM

VERSION="$(version_tree)"
echo "installing $APP_NAME $VERSION" >&2

DMG="$("$ROOT/Scripts/release.sh")"

# ---------------------------------------------------------------------------------------------------------
# The bundle that goes to /Applications is the one inside the disk image, so what is installed is exactly
# what a release would hand a stranger — stapled ticket and all.
# ---------------------------------------------------------------------------------------------------------
MOUNT="$(mktemp -d)"
/usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null

# Quit the running copy and wait for it to actually exit. Replacing the bundle under a running process, or
# launching before the old one has gone, leaves two menu-bar items or a copy running from a path that no
# longer exists — this app has no status to ask first, so quitting is unconditional.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.1
done
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "$APP_NAME is still running after 5 s. Quit it, then run this again." >&2
  exit 1
fi

rm -rf "$DEST"
/usr/bin/ditto "$MOUNT/$APP_NAME.app" "$DEST"
/usr/bin/hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
MOUNT=""

# What was installed says for itself what it is. A bundle that fails this must not be left in /Applications.
codesign --verify --deep --strict "$DEST" 2>/dev/null || { echo "the installed bundle does not verify" >&2; rm -rf "$DEST"; exit 1; }
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
[ "$INSTALLED" = "$VERSION" ] || { echo "installed $INSTALLED, expected $VERSION" >&2; exit 1; }
xcrun stapler validate "$DEST" >/dev/null 2>&1 || echo "warning: the installed bundle carries no stapled ticket" >&2
echo "installed $DEST ($INSTALLED)" >&2

# A stable Developer ID identity keeps the same code signature across installs, so the Accessibility grant
# in System Settings survives this reinstall; an ad-hoc build (Scripts/build-app.sh's own warning) would not.
# A reinstall is not a person asking for the Settings window: this marker tells the launch below to open
# nothing. The app reads it once and removes it (Sources/SystemAdapters/QuietLaunch.swift).
QUIET="$HOME/Library/Application Support/SnappySnap"
/bin/mkdir -p "$QUIET"
: > "$QUIET/quiet-launch"

open "$DEST"
echo "$DEST"
