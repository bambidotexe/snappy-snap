#!/bin/zsh
# Install locally and launch. A familiar name for the one local action there is.
#
#   Scripts/run.sh
#
# This is `Scripts/install.sh` and nothing more: the production bundle — signed with the Wooflab team's
# Developer ID, notarized, stapled — installed in /Applications and launched, with no .app and no .dmg left
# anywhere under the repository.
#
# It is not a debug loop. A build of this app reaches a Mac through `Scripts/install.sh` or
# `Scripts/publish.sh` and through nothing else: a bundle left in build/ is a complete application that
# Spotlight offers and that runs beside the installed copy as a second menu-bar item with the same bundle
# identifier and the same preferences.
set -euo pipefail
exec "${0:A:h}/install.sh"
