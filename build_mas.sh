#!/bin/bash
# Build the Mac App Store edition of Readlet: sandboxed, no self-updater, signed installer package.
#
# One-time setup (Apple Developer account, see AppStore/CHECKLIST.md):
#   • App ID io.novarock.readlet, a "Mac App Store" provisioning profile for it
#   • certificates "Apple Distribution" and "3rd Party Mac Developer Installer" in your login keychain
#
#   TEAM_ID=ABCDE12345 \
#   MAS_APP_IDENTITY="Apple Distribution: Your Name (ABCDE12345)" \
#   MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (ABCDE12345)" \
#   MAS_PROFILE=~/Downloads/Readlet_Mac_App_Store.provisionprofile \
#   ./build_mas.sh
set -e
cd "$(dirname "$0")"
[ -f .env.local ] && . ./.env.local
: "${TEAM_ID:?set TEAM_ID in environment or .env.local}"
export TEAM_ID
MAS=1 UNIVERSAL=1 INSTALL=0 exec ./build_app.sh
