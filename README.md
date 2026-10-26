# Somnoire

A small native **macOS 13+ menu-bar utility** for the EcoFlow RAPID Pro
27,650mAh (300W), using Swift 6, SwiftUI and CoreBluetooth. Original source is
MIT licensed. No account, analytics, cloud requests or runtime package installation.

Somnoire is named after the location in *Wuthering Waves*. This is an independent,
experimental project focused on this power bank, not a general EcoFlow client.

**0.5.0 continuously monitors the verified battery advertisement profile.**
The menu bar shows a fresh percentage beside Somnoire’s symbol. Automatic
monitoring does not open a GATT connection, subscribe, authenticate or send commands.
Settings, wattages, authenticated sessions and controls remain future work.

## Use

1. Open Somnoire and turn on **Monitor Battery** in its menu. Bluetooth permission
   is requested only after this action. Keep the bank awake and nearby.
2. After a three-second association period, Somnoire selects a sole eligible bank.
   If multiple banks match, use **Choose Power Bank…** and select yours.
3. Monitoring continues with the menu closed. The app remembers the enabled state
   and selected peripheral UUID locally, restoring them when you next launch it.
   Launch at login is not installed. **Monitor Battery** can be turned off anytime.
4. A reading expires after 30 seconds without a valid manufacturer payload. The
   menu bar shows a dash when paused, sleeping, unavailable or stale. A retained
   percentage in the menu is explicitly labeled **Last reported**.
5. **Diagnostics…** opens a resizable utility window. Opening the window alone
   does not scan or connect. **Discover Devices** performs bounded 30-second
   diagnostic discovery; **Connect** explicitly inspects GATT and may be dropped
   by the bank after roughly ten seconds. This does not affect the separate
   advertisement-based battery feature.
6. Closing diagnostics cancels active inspection/probing and restores monitoring
   if enabled. **Quit Somnoire** ends the app and its Bluetooth work.

The status **Nearby** means advertisements are being received. It does not claim
an authenticated connection. Run one Somnoire instance at a time; duplicate
launches reuse the existing instance. If the bank is missing, check its proximity,
Bluetooth availability, and whether the official app is occupying its BLE session.

## Build and run

Open `Somnoire.xcodeproj`, choose **Somnoire → My Mac**, and Run. Xcode 16+ with
Swift 6 is required; local validation uses Xcode 27 / Swift 6.4. The app supports
Apple silicon and Intel and uses local ad-hoc signing, so no developer account is
required for local builds. The bundle identifier is `org.somnoire.Somnoire`.

```sh
# Hardware-free tests (use arch=x86_64 on an Intel Mac)
xcodebuild -project Somnoire.xcodeproj -scheme Somnoire \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Local test

# Universal, locally signed Release app
xcodebuild -project Somnoire.xcodeproj -scheme Somnoire \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/Run build
open build/Run/Build/Products/Release/Somnoire.app
```

Build artifacts are not committed; build locally using Xcode or the commands above.
There is no Dock icon; look for Somnoire’s moon-and-stars symbol. macOS may hide
extras when the menu bar is crowded. Quit an existing instance before running a
new build from Xcode. Developer ID signing/notarization and a downloadable binary
release are not included.

## Diagnostics and privacy

Diagnostics use bounded in-memory events and relative times. Automatic monitoring
records decoding-category transitions, not every advertisement. Receipt/coalescing
counts are aggregated. **Copy Diagnostics** excludes device names, peripheral UUIDs,
serials, battery readings, absolute timestamps, raw advertisements, packet bodies,
credentials and cryptographic keys. **Clear** clears events and volatile previews.

Only the monitoring preference and selected CoreBluetooth UUID are saved locally.
Raw details and payload previews are local, volatile inspection tools; review them
before sharing manually. Probe traffic has no raw preview. There are no diagnostic
files or application telemetry services.

## Explicit session probes

**Connect & Probe → Key exchange only** performs a fresh ECDH/key-info exchange,
validates it and intentionally disconnects. **Session + status** additionally
verifies an encrypted status reply, then disconnects. Both are explicit experiments;
neither performs login, telemetry queries, controls or persistent monitoring.

The project vendors a small BSD-2-Clause micro-ecc curve library and a pinned
Apache-2.0 protocol lookup table. Their provenance and licenses are retained under
`Vendor/` and in bundled `ThirdPartyNotices.txt`. Original Somnoire code remains MIT.
There is no OpenSSL, Python, subprocess or network dependency at runtime.

## Reliability and permissions

- Monitoring pauses during sleep and Bluetooth loss; it resumes only when enabled.
  Denied/restricted access is explained without repeated prompts or retries.
- If permission is denied, enable Somnoire in **System Settings → Privacy & Security
  → Bluetooth**, then relaunch if the OS does not deliver the changed state.
- Initial Bluetooth permission is not reset automatically. Keep signing and bundle
  identity stable during development. The Release sandbox permits Bluetooth only.
- The advertisement mapping is restricted to the observed P512/type-7 profile. It
  matched the physical bank display at 100% and 96%; other models/firmware layouts
  are not inferred. Unknown values are unavailable, never clamped or replaced by zero.
- Continuous duplicate advertisement delivery has a radio/power cost. Pause it when
  unnecessary. The app filters unrelated devices and coalesces presentation updates.

## Architecture and validation

The app delegate owns one main-actor manager. CoreBluetooth stays in
`BluetoothManager.swift`; pure monitoring selection/freshness policy and value
snapshots are separate from transport. Native menus and a SwiftUI diagnostics view
consume the shared observable state. There are no external UI frameworks.

See [current Phase 2B behavior and validation](docs/Phase2B.md). Historical evidence:
[Phase 2A battery mapping](docs/Phase2A.md), [Phase 1B encrypted status](docs/Phase1B.md),
[Phase 1A key exchange](docs/Phase1A.md), and [reference/license research](docs/BLE-Research.md).

The current local validation passed **51 hardware-free tests**, a **45-second
continuous-monitoring check**, and explicit GATT-close/monitoring-resumption checks.
Debug and Release compile for both architectures. Intel/macOS 13 runtime, live
visual inspection, physical out-of-range recovery, and actual sleep/wake remain
manual checks; compilation is not a substitute for those checks.

Hardware checks are separately opt-in schemes: **Somnoire Continuous Monitoring
Check**, **Somnoire Diagnostic Lifecycle Check**, **Somnoire Advertisement Battery
Check**, **Somnoire Hardware Probe**, and **Somnoire Session Status Probe**. Ordinary
tests never activate these checks or auto-restore saved monitoring.

## Roadmap and license

Next milestones are evidence-based wattage/telemetry decoding, verified device
settings and controls, and an optional standalone monitoring window. Authentication
and account requirements remain separate research; a successful encrypted status
probe does not establish authenticated access. No speculative control commands are
implemented.

Somnoire's original code is [MIT licensed](LICENSE). See
[ThirdPartyNotices.txt](ThirdPartyNotices.txt) for the separately licensed vendored
dependencies. Local BLE captures, phone dumps, Android APKs and build/test artifacts
are excluded from source control.
