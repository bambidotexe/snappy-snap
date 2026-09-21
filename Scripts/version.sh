#!/bin/zsh
# The version rule, and the only place that knows where the version is written.
#
#   source Scripts/version.sh
#   version_tree                        the version this tree builds
#   version_bump <patch|minor|major> <x.y.z>   that version raised by one level
#   version_set  <x.y.z>                write it everywhere it must agree
#
# The tree always holds exactly the version last published, or the version a local install just carried,
# whichever happened last — never a bumped-ahead placeholder. `Scripts/publish.sh <level>` is the only thing
# that moves the version: it bumps, commits and pushes before it builds, so the commit it tags is the commit
# that carries the version it releases.
set -uo pipefail
VERSION_ROOT="${0:A:h:h}"

# Where the version is written — the one place. CFBundleVersion rises with CFBundleShortVersionString so
# that a rebuild of the same version is still the newer bundle; nothing else names a version to keep in step.
INFO_PLIST="$VERSION_ROOT/Resources/Info.plist"

version_tree() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST"
}

version_bump() {
  local level="${1:?version_bump <patch|minor|major> <x.y.z>}"
  local v="${2:?version_bump <patch|minor|major> <x.y.z>}"
  local major="${v%%.*}" rest="${v#*.}" minor patch
  minor="${rest%%.*}"; patch="${rest#*.}"
  case "$level" in
    patch) echo "$major.$minor.$((patch + 1))" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    major) echo "$((major + 1)).0.0" ;;
    *) echo "version_bump: level must be patch, minor or major, not '$level'" >&2; return 1 ;;
  esac
}

version_set() {
  local v="${1:?version_set <x.y.z>}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $v" "$INFO_PLIST"
  # A build number that only ever rises, so a rebuild of the same version is still the newer bundle.
  local build
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build + 1))" "$INFO_PLIST"
}
