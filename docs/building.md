# Building Somnoire

Somnoire targets macOS 13 or later and uses Swift 6. The current validation
machine uses Xcode 27. Open `Somnoire.xcodeproj`, choose the Somnoire scheme and
My Mac, then Run. Both Apple silicon and Intel are included in universal builds.
Local builds use ad-hoc signing and do not require a Developer ID account.

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
menu-bar utility with no Dock icon. Its bundle identifier is
`org.somnoire.Somnoire`. Release entitlements permit sandboxed Bluetooth and
read-only access to user-selected files; there is no network entitlement.

## Prerelease packaging

Verify the app with `codesign --verify --deep --strict` and check the executable
with `lipo -archs` before packaging. Use `ditto -c -k --sequesterRsrc --keepParent`
to preserve the app bundle in a ZIP, then verify an extracted copy. Include a
SHA-256 checksum beside the downloadable ZIP. The app is not notarized.

Keep Android packages, device captures, credentials, account IDs, raw payloads
and private research artifacts out of Git and release assets. Public crypto test
vectors use deliberately synthetic values; their generator records provenance.
