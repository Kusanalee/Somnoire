# Phase 0 validation (historical)

For current key-exchange and hardware results, see [Phase 1A](Phase1A.md).
This record describes the earlier Phase 0 build and its validation limits.

Validation date: 26 October 2026 (Asia/Manila).

## Passed

- Native macOS Debug and Release builds with Xcode 27.0 (27A266a), Swift 6.4.
- Both `arm64` and `x86_64` slices present in Debug and Release application binaries,
  verified using `lipo -archs`. Deployment target is macOS 13.0.
- 18 XCTest cases executed on the local Apple silicon Mac: **0 failures**.
- Test coverage includes malformed/CoreBluetooth advertisement conversion,
  manufacturer bounds and byte order, non-name hints, metadata merging, missing
  RSSI, repeated UUID identities, complete property flags, connection gating,
  cancellation/late events, log bounds, payload preview truncation, and export privacy.
- The manager starts idle and rejects unseen-device connections without creating
  a Bluetooth central. Tests do not scan, connect, pair, or request Bluetooth access.
- Release application copied to `build/Somnoire.app` and ad-hoc signed with only
  `com.apple.security.app-sandbox` and `com.apple.security.device.bluetooth`.
- `codesign --verify --deep --strict` passes for the runnable Release bundle.
- Built Info.plist inspected: macOS-only platform, deployment target 13.0,
  `LSUIElement = true`, stable bundle identifier and Bluetooth purpose description.
- Source audit found no characteristic writes, manual descriptor writes,
  characteristic reads, RSSI polling, networking calls, or vendor command encoder.
- Property lists/project syntax and Git whitespace checks pass.

The first XCTest execution was blocked by the command sandbox's access to
`com.apple.testmanagerd.control`. Retrying the same compiled tests with local
execution access succeeded. Initial sandboxed build logs also contain unrelated
CoreSimulator service messages; the targets are macOS-only and builds succeeded.

Xcode temporarily adds test-runner sandbox exceptions and embeds the test bundle
in its Debug test host. **The separately signed Release app contains neither the
test bundle nor those exceptions.** Use that Release app for ordinary inspection.

## Artifacts

Generated artifacts are ignored by Git:

- Runnable, signed application: `build/Somnoire.app`.
- Successful XCTest result bundle: `build/LayoutFinal.xcresult`.
- Debug compilation check: `build/DerivedData/Build/Products/Debug/Somnoire.app`.
- Release compilation check: `build/ReleaseCheck/Build/Products/Release/Somnoire.app`.

To reproduce the runnable application after the unsigned Release build:

```sh
ditto build/ReleaseCheck/Build/Products/Release/Somnoire.app build/Somnoire.app
codesign --force --sign - --entitlements Somnoire.entitlements \
  --timestamp=none build/Somnoire.app
codesign --verify --deep --strict build/Somnoire.app
open build/Somnoire.app
```

## Not verified

Native UI automation repeatedly returned `-10005: timeoutReached` when selecting
or launching the Release bundle. No screenshot or accessibility tree was obtained.
Consequently menu-bar visibility, panel layout, no-Dock appearance, and interactive
Scan/Stop/Copy/Quit behavior are **awaiting manual UI validation**. The app did
launch as the XCTest host, but that does not establish those UI behaviors.

No RAPID Pro was exercised. Discovery, standard connection, real GATT services,
notification availability, permission allow/deny behavior, Bluetooth toggling,
and sleep/wake behavior are **awaiting hardware validation**. The README contains
the checklist. Proprietary authentication and battery telemetry are unimplemented.

Cross-compilation establishes Intel binary availability, not Intel runtime
compatibility. Runtime checks on Intel and macOS 13 remain outstanding. The local
host is newer than macOS 13. Developer ID distribution/notarization was not tested.

## Menu-panel layout correction

The initial panel's ScrollView specified only a maximum height. MenuBarExtra's
intrinsic-size measurement collapsed that scroll area, hiding Scan and all body
controls. The panel now gives the scroll area an explicit 480-point height.
A native NSHostingView regression test checks the panel's measured width and
usable height. Bluetooth permission is still requested on Scan, not at launch.
The universal Release app at `build/Somnoire.app` was rebuilt and signed after
this correction. The live menu-bar panel and Bluetooth permission flow still
require interactive validation; native sizing tests do not establish those flows.
