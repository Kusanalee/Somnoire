# Building Somnoire

Somnoire targets macOS 13 or later and uses Swift 6. The current validation
machine uses Xcode 27. Open `Somnoire.xcodeproj`, choose the Somnoire scheme and
My Mac, then Run. Both Apple silicon and Intel are included in universal builds.
Personal builds reuse the local signing certificate described below and do not require a Developer ID account.

## Tests

```sh
xcodebuild -project Somnoire.xcodeproj -scheme Somnoire \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Local test
```

Use `arch=x86_64` on an Intel Mac. Hardware checks are opt-in; the ordinary
suite does not connect to the bank. Build/test output stays under ignored `build/`.

## Universal release build

```sh
xcodebuild -project Somnoire.xcodeproj -scheme Somnoire \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/Local build
open build/Local/Build/Products/Release/Somnoire.app
```

Quit an existing Somnoire instance before testing another build. The app is a
menu-bar utility that shows its Dock icon while onboarding, Settings or Diagnostics windows are open. Its bundle identifier is
`io.github.kusanalee.Somnoire`. Release entitlements permit only App Sandbox and Bluetooth; there is no network
or user-selected-file entitlement.

## Prerelease packaging

Verify the app with `codesign --verify --deep --strict` and check the executable
with `lipo -archs` before packaging. Use `ditto -c -k --sequesterRsrc --keepParent`
to preserve the app bundle in a ZIP, then verify an extracted copy. Include a
SHA-256 checksum beside the downloadable ZIP. The app is not notarized.

Keep Android packages, device captures, credentials, account IDs, raw payloads
and private research artifacts out of Git and release assets. Public crypto test
vectors use deliberately synthetic values; their generator records provenance.

## Multiple development copies and notification icons

Keep CFBundleVersion increasing when preparing updated builds. Many old bundles
with the same identifier/build can leave macOS resolving notification metadata
from an iconless development copy. Check the running bundle and the bundle URL
resolved by NSWorkspace when diagnosing this. Build 21 refreshes the icon-bearing
bundle registration; notification permissions and the bundle identifier are
unchanged. Quit the old instance before opening the new app, and verify the build
number in About before sending a test notification. Do not reset global icon
caches or notification authorization to work around a development-copy conflict.

Build 22 packages the supplied app artwork through
Resources/Assets.xcassets/AppIcon.appiconset. Xcode generates the ICNS, compiled
catalog and icon plist keys; avoid manually overriding those generated keys.
The build-21 registration refresh and build-22 catalog alone did not resolve the banner placeholder. The later Kusanalee namespace with persistent local signing was live-tested: notification artwork appears, Bluetooth grants survive a changed build, and migrated bank access reconnects after relaunch.

## Kusanalee local signing

The personal-machine bundle identifier is now `io.github.kusanalee.Somnoire`.
Use `scripts/build-local.sh Release` (or Debug). This requires the reusable login
Keychain identity `Somnoire Local (kusanalee)` and intentionally fails if it is
unavailable; there is no ad-hoc fallback. Keep the same private key across builds.
Do not commit or distribute the private key. This is local signing, not Developer
ID or notarization, and it does not provide Gatekeeper distribution approval.
The local certificate is restricted to code signing in user-level trust settings;
no system trust store was modified. Losing or replacing it changes app identity.

The new credential service is `io.github.kusanalee.Somnoire.bank-credential`.
A normal-access legacy read can migrate an existing credential into the new
service. Legacy entries remain for rollback; Forget addresses both services.
Denied/locked/malformed/migration-save failures are distinct from missing access
and never cause deletion. If macOS prevents reuse, use guided numeric-ID setup.

For this Mac's one-time upgrade, quit both identities before running
`scripts/migrate-local-preferences.py`. Launch/quit the new identity once first
to create its sandbox. The script privately backs up legacy preferences, validates
an allowlist, preserves new preferences, and disables alerts until opt-in under
the new permission identity. It never accesses credential bytes. Check old/new
Launch at Login settings manually so only the new identity is registered.
