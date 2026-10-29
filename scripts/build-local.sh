#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
identity='Somnoire Local (kusanalee)'
if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$identity\""; then
  print -u2 'Missing Somnoire Local (kusanalee) signing identity in the login Keychain. No ad-hoc fallback will be used.'
  exit 1
fi
xcodebuild -project Somnoire.xcodeproj -scheme Somnoire -configuration "${1:-Release}" -destination 'generic/platform=macOS' -derivedDataPath build/Kusanalee CODE_SIGN_IDENTITY="$identity" build
