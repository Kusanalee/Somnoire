# Somnoire

A small native **macOS 13+ menu-bar utility** for the EcoFlow RAPID Pro
27,650mAh (300W), using Swift 6, SwiftUI and CoreBluetooth. Original source is
MIT licensed. No analytics, cloud requests or runtime package installation.
Passive battery monitoring needs no account. An explicit authenticated diagnostic
probe can use a one-time account ID locally; Somnoire never handles your password.

Somnoire is named after the location in *Wuthering Waves*. This is an independent,
experimental project focused on this power bank, not a general EcoFlow client.

**Somnoire continuously monitors the verified battery advertisement profile.**
The menu bar shows a fresh percentage beside Somnoire’s symbol. Automatic
monitoring does not open a GATT connection, subscribe, authenticate or send commands.
Continuous wattage monitoring, persistent sessions, settings and controls remain future work.
Version **0.5.2** added an explicit account-free access experiment: it classifies
the status reply and requests one display report. Two current-bank attempts
received no telemetry; see [Phase 2D](docs/Phase2D.md).
Version **0.5.3** adds **Authenticated telemetry check**, which checks an existing
credential before requesting the same display report. This remains an experiment,
not continuous wattage monitoring; see [Phase 2E](docs/Phase2E.md).
A user-assisted run verified existing-credential acceptance on the current bank.
The following packet identified V19 framing. Version **0.5.5** corrects the
length and encoding rules using the installed official app’s native parser.
A 0.5.5 bank session validated repeated V19 display uploads. Version **0.5.6**
adds their observed route to the authenticated decoder. Its first complete bank
session accepted the credential, decoded 87 telemetry bodies with 29 port-power
updates, then disconnected and resumed passive scanning. Repeated fresh sessions
confirm decoding under load and unloaded. Field 852 reported −22.9 W on C1
(labelled 140W in/out); unloaded port values were absent. Other port mappings
and comparison against the bank’s screen remain pending. Version **0.5.7**
distinguishes decoded telemetry with absent port readings from telemetry silence.

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
The experimental account-ID field and derived credential are volatile. No password
entry, cloud sign-in code, credential persistence or credential-changing API exists.
Raw details and payload previews are local, volatile inspection tools; review them
before sharing manually. Probe traffic has no raw preview. There are no diagnostic
files or application telemetry services.

## Explicit session probes

**Connect & Probe → Key exchange only** performs a fresh ECDH/key-info exchange,
validates it and intentionally disconnects. **Session + status** additionally
verifies an encrypted status reply, then disconnects. The third choice,
**Account-free telemetry check**, uses the same session/status
requests, then observes validated notification headers for up to eight seconds.
It disconnects afterward and does not claim that port power is accessible.
**Account-free access check** additionally interprets typed status and, for a
supported normal-mode reply, requests one full display report using a fixed
app-derived action. It observes for up to 30 seconds, then disconnects. No login,
credential provisioning, unbinding, reset, port/charging settings, or report-period
changes are sent. These four probes are account-free and explicit; there is no reconnect loop. See
[Phase 2D](docs/Phase2D.md) for request provenance and the remaining access gate.

The dedicated **Authenticated telemetry check** button on each eligible bank's
Diagnostics row requires a numeric authorizing account ID in
the secure Diagnostics field. Obtain it once through an official EcoFlow login
using the same account/region as the bank. This probe accepts only normal mode
with an existing credential, sends one `35/86` check, then requests a display
report only after a validated successful reply. There are no credential retries,
pairing changes or resets. The ID clears on probe start/window close, and C wipes
the derived token; SwiftUI text buffers cannot guarantee memory zeroization.
Experimental results show historical protocol-field measurements, with physical
mapping explicitly unverified. **Clear** removes retained results while idle.

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

The current hardware-free suite passed **79 tests**, with six opt-in hardware
checks skipped. The preceding Phase 2B validation passed a **45-second
continuous-monitoring check** and explicit GATT-close/monitoring-resumption checks.
Debug and Release compile for both architectures. Intel/macOS 13 runtime, live
visual inspection, physical out-of-range recovery, and actual sleep/wake remain
manual checks; compilation is not a substitute for those checks.

Hardware checks are separately opt-in schemes: **Somnoire Continuous Monitoring
Check**, **Somnoire Diagnostic Lifecycle Check**, **Somnoire Advertisement Battery
Check**, **Somnoire Hardware Probe**, **Somnoire Session Status Probe**,
**Somnoire Telemetry Access Check**, and **Somnoire Account-Free Access Check**.
Ordinary tests never activate these checks or auto-restore saved monitoring.

The official app now provides an [app-derived P512 telemetry schema](docs/P512-Protocol.md)
and an isolated Swift decoder with synthetic tests. The fixed report-request
experiment did not establish account-free access on the current bank. Physical mapping and never-linked onboarding remain unverified;
production wattage rows are still gated.

## Roadmap and license

Next milestones are evidence-based wattage/telemetry decoding, verified device
settings and controls, and an optional standalone monitoring window. The explicit
existing-credential probe is research; a successful encrypted status probe alone
does not establish authenticated access. No speculative control commands are implemented.

Somnoire's original code is [MIT licensed](LICENSE). See
[ThirdPartyNotices.txt](ThirdPartyNotices.txt) for the separately licensed vendored
dependencies. Local BLE captures, phone dumps, Android APKs and build/test artifacts
are excluded from source control.
