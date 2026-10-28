# Phase 2E — existing-credential telemetry experiment

## Operation and source evidence

This explicit experiment checks the current bank's existing credential. It cannot
set a credential, replace pairing, unbind, reset, change charging settings, or
configure reporting periods. Normal monitoring remains advertisement-only.

The retained official Android app 6.17.4.14/11113 is the static source (package
and bundle hashes are in [P512 Protocol](P512-Protocol.md)). In `classes9.dex`:

- `EFBleAuthNoDialogHelper.bleAuthNormal` uses the authorizing person's ID plus
  the destination serial for the normal V3 path. `com.blankj.utilcode.util.c0.V`
  calls `X`, which applies MD5 and then `v1.k` / `x.l` / `x.m`. The default flag
  selects the uppercase `0123456789ABCDEF` array, producing 32 ASCII hex bytes.
  Another older `EFAuthHelper` path uses a different formatter; it is not used
  as a fallback or justification for trying alternate tokens.
- `BleAuthNormalHelper.bleAuth` calls `BleAuthCommand.checkAuthentication` for
  existing authentication. The separate `setAuthentication` operation is excluded.
- `checkAuthentication` uses app source `0x21`, normal destination `0x35`, device
  routing `1/1`, command set `0x35`, command `0x86`, and inner version 3.
- `BleAuthNormalHelper.checkOrSetAuthResultHandle` rejects empty replies and
  converts the first payload byte with `conversionNormalResultCode`: zero maps
  to success; nonzero maps to an error. Trailing bytes are not exposed.

Somnoire chooses sequence **2** for this check; sequence is a request correlation
value, not part of credential derivation. It accepts only the reversed `35→21`,
`1/1`, `35/86`, sequence-2 application reply after issuing a check in that session.
All normal V3 padding, size, CRC and routing validation remains mandatory.
The request's inner packet has a 32-byte body and a 52-byte total length; AES-CBC
with PKCS#7 produces 64 ciphertext bytes. A GATT acknowledgement cannot confirm
authentication. Neither can the earlier `35/89` status response.

After the check's write acknowledgement and successful application reply, the
probe sends the existing `21→02`, `FE/11`, sequence-1 full-display request with
only body `B8 04 01`. Only allowlisted `FE/15` uploads reach the P512 decoder.
Telemetry before authentication is discarded; telemetry during the report write
is bounded and held until that write is acknowledged. Protocol-field rows retain
reported values across this experiment and are labeled historical and unverified.
Omitted fields, unknown values and explicit zero remain distinct.

## Identity setup and privacy

Sign in on EcoFlow's official site with the bank's authorizing account and matching
country/region. Website profile IDs are candidates until the bank accepts the
derived credential; a shop-only account ID must not be assumed correct. The
[community setup guide](https://github.com/rabits/ha-ef-ble/wiki) describes this
one-time identity setup; Somnoire has no cloud-login code or network entitlement.

Enter only the numeric authorizing ID in Diagnostics, then choose the selected
bank's dedicated **Authenticated telemetry check** button. The serial comes
only from that same bank's validated P512 advertisement. IDs must be 1–32 ASCII
digits and serials must match the verified 16-character P512 format.
An inline readiness message confirms valid input. The dedicated action remains
clickable while idle so invalid input produces an explanation; the manager
rejects invalid input before opening a connection.

The secure field clears on probe start, Clear, and view disappearance. Only an
opaque derived token survives connection setup. C explicitly wipes that token,
hash intermediates and session material. SwiftUI/String input buffers cannot
promise memory zeroization; clearing a field is not a secure-memory guarantee.
No identity or token is written to preferences, Keychain, diagnostics or fixtures.
Diagnostics export only typed credential acceptance and telemetry counts, never
the account ID, serial, token, raw packets or readings. Clear removes historical
probe results while idle. No credential retry or alternate-format attempt occurs.

## Bounds and validation

The probe requires normal mode and check-existing-credential status. Set-credential,
unknown and OMOS states terminate without authentication writes. There are at most
five application writes: public key, key-info, status, credential check, display
request. Setup stages have three-second limits and a sixteen-second connected
setup cap. Observation lasts thirty seconds, with a forty-six-second connected
overall cap. Connection establishment retains its separate twenty-second cap.
Cancellation/disconnect clears pending secrets and ends the attempt; normal scan
reconciliation restores enabled passive monitoring.

Independent public synthetic fixtures use Python hashlib/OpenSSL and fabricated
identity/serial values. They exercise exact credential-request ciphertext, uppercase
formatting, reply routing/sequence, accepted/rejected/empty results, unrelated
provisioning replies, malformed framing, padding and checksums. State-machine tests
cover early replies, fragmentation, write acknowledgements, pre-authentication
telemetry, status-only outcomes, deadlines, cancellation and cleanup.

On 27 October 2026 (Asia/Manila), the 0.5.4 hardware-free run passed **77 tests**,
with six unrelated opt-in hardware checks skipped and no failures
(`build/Phase2EV19Tests-R1.xcresult`). Debug and Release compile for arm64 and
x86_64. The universal Release signature validates; entitlements remain App Sandbox
and Bluetooth only. Intel/macOS 13 runtime and native visual QA remain unverified.

Native accessibility repeatedly returned timeout `-10005`, including after the
user opened Diagnostics. An official-site profile response supplied a numeric ID
without saving it or printing it in research logs. The first manual attempt could
not start because the authenticated menu item was disabled. The revised UI gives
explicit readiness feedback and delegates validation to the manager before any
connection. A subsequent user-supplied report contained an ordinary GATT inspection
and peer disconnect, without probe stages or authentication writes. That run is
not an authentication failure. To make the next action unambiguous, authentication
now has a dedicated row button and an immediate typed **Probe requested** event.
The initial browser clipboard did not populate the native field with a valid ID.
A temporary local-only field on the already signed-in official page allowed native
manual copy/paste. The 19-digit ID was serialized as a string and retained exactly;
neither that ID nor a generated token was printed or saved in research artifacts.

## User-assisted current-bank authentication result

A subsequent user-supplied diagnostic report establishes a successful existing-
credential check on the current bank. The sequence reached normal check-credential
status, then received a validated `35/01→21/01`, `35/86`, sequence-2 reply with a
one-byte success payload. Both write/reply barriers completed. The report records
**existing credential=accepted**, followed by the full-display request and its
GATT acknowledgement. Authentication is therefore established for this bank and
identity; it is no longer the immediate blocker.

The next encrypted notification failed the then-current strict V3 parser. The
probe intentionally disconnected after approximately 1.07 seconds, with **zero
decoded telemetry packets and zero port updates**. Passive scanning resumed.
This result proves credential acceptance, not port-power access or physical mapping.

The next diagnostic build retains fail-closed packet validation and adds only
sanitized failure categories: AES/PKCS#7, prefix/minimum size, header CRC8,
unsupported version (including a distinct V19 category), exact length, and CRC16.
No failed packet body or raw version byte is exported. Native parser selection
is corroborated by `EcoProtocolParseHelper` and `EcoProtocolParseTypeSession`,
which delegates to the installed app's `TreatyEngine.aesDecryptFrame`.
The next user-assisted attempt again accepted the credential, then identified
**V19 (`0x13`)** after successful AES/PKCS#7 and header CRC8 validation. It ended
after approximately 1.19 seconds with no decoded telemetry; passive scanning
resumed. This supplies the actual-bank evidence for extending the access parser.

Expanded independent fixtures exposed the platform decryptor's tolerance for a
zero padding count. All three decrypt paths now validate PKCS#7 explicitly after
un-padded CBC decryption: padding must be 1–16 equal bytes. Valid-prefix zero and
inconsistent padding fail before header or body interpretation. This strengthens
validation; it does not add a padding or protocol fallback.

## V19 investigation and native-derived correction (0.5.5)

The 0.5.4 reference-based candidate failed on the current bank with an exact
V19-length error after another accepted credential check. No telemetry was decoded.
Its assumption that the declared length included the sentinel was incorrect.

With the user's authorization, ADB retrieved only the installed app's ARM64 code
split, not account storage. `libnative-lib.so` SHA-256:
`90c3c13aaf47a5975ea23667b113b7bee5bd396ce92ab0ba222f4925fdaa30c1`.
The retained disassembly establishes:

- `unpack_data` dispatches both version 3 and 19 to `getV3Data`.
- `getV3Data` at `0x99470` requires `20 + declared payload length`; body bytes
  start at offset 18 and the two trailer bytes are outside the declared body.
- `getV3Data` at `0x99480–0x99498` separates two encoding bits (5–6) from
  three check bits (2–4). `process` at `0x9b988` retains the sequence, and
  `0x9bcdc–0x9bd14` XORs exactly the body with its first byte only for encoding 1.
- `v3CrcCheck` at `0x9c27c–0x9c2e8` accepts no-check selectors 0/1,
  CRC8 or CRC16 for selector 2, and CRC16 for selector 3. That JNI helper extracts
  four bits, overlapping encoding; the session parser separately exposes the
  three-bit check selector. Somnoire interprets the separate native fields and
  rejects unsupported encoding/check selectors. This combined interpretation
  still needs hardware confirmation; synthetic vectors cannot establish it.

The corrected decoder enforces header CRC8, exact size, a maximum 984-byte body,
selected checksum validation before transformation, and encoding 0/1 only.
No-check modes follow the app's explicit behavior; a BB trailer does not establish
packet integrity or credential acceptance. V3 validation remains unchanged.
V19 remains available only after an accepted V3 credential reply in the same
fresh context, and only existing allowlisted display routes expose a body.

Independent synthetic vectors cover plain/XOR payloads, keys 0/73/255, selected
checksums, malformed checksum/header/length, truncation/trailing data, the old
incorrect layout, unsupported modes, routing, buffer capacity, and refusal before
authentication. Typed failure diagnostics export only lengths and marker-match
categories, never packet contents, identities, tokens, or readings.

Telemetry decoding and physical-port mappings remain pending. Authentication
acceptance and actual port-power updates are reported separately. At least two
fresh decoded sessions and a confirmed load change are required to establish access;
each physical port/cable must then be compared before assigning user-facing labels.

## 0.5.5 verification

`Phase2EV19Native-R1.xcresult`: 84 tests executed, six opt-in hardware checks
skipped, zero failures (78 hardware-free passed). This includes typed failure
cleanup and the native-derived synthetic V19 cases. Universal Debug/Release build
logs are `build/TelemetryResearch/v19-native-{debug,release}-r1.log`; both passed
for arm64 and x86_64. Release signature verification passed and entitlements
remain App Sandbox plus Bluetooth only.
A new user-assisted bank run is still required; no live V19 decode or port mapping
is claimed from these tests.

## Current-bank V19 streaming result (0.5.5)

The user's next report validates V3 status and credential replies, then V19
`FE/12` (seven-byte body) and repeated `FE/15` uploads (166, 29 and 15-byte bodies).
Uploads arrive about once per second, including multiple frames per notification
and frames across notification boundaries. The observed upload route is
`02/01→21/00`; the prior allowlist covered only device routes 0/0 and 1/1.
Therefore framing/stream reception now works, but those uploads were classified
as unrelated before protobuf decoding. This does not yet prove wattage values.
The report ended during observation, before completion/disconnect could be checked.

Version 0.5.6 adds only that exact mixed device route for V19 FE/15 after an
accepted credential check in the same context. Existing V3/account-free route
rules remain unchanged. The app-derived `payLoadAllMap[21]` decoder independently
supports FE/15 as the display upload. FE/12 remains unclassified: receiving it
is not claimed as a validated report acknowledgement. No outgoing packet changes.
Independent fixtures cover the observed route, refusal before authentication,
V3 exclusion, the reverse mixed route, and FE/12 remaining unrelated.

The next hardware gate is actual protobuf decoding and a complete bounded session,
then a second fresh session with load changes and physical port comparisons.

0.5.6 hardware-free validation: `build/Phase2EV19Route-R1.xcresult`, 84 tests
executed, six opt-in hardware checks skipped, zero failures (78 passed).
Universal Debug and Release builds passed for arm64/x86_64; the Release signature
verified. Logs: `build/TelemetryResearch/v19-route-{debug,release}-r1.log`.
The tested 0.5.6 Release build was launched for the next user-assisted check.

## First complete authenticated telemetry session (0.5.6)

The user's complete report confirms a fresh credential check followed by
**87 decoded telemetry bodies and 29 port-power updates**. The probe completed
normally after 31.431 seconds, with 95 observed packets counted, requested
disconnection, received disconnection, and resumed passive scanning. GATT snapshots
were then stale/disconnected with notifications no longer subscribed.

Authentication success and telemetry decoding are both established for this
single session. The report excludes measurement values by design; physical port,
watts/volts/amps, load response, and bank-display comparison have not yet been
supplied. This is one completed telemetry session, not the required two fresh
sessions or a verified physical field mapping. FE/12 is still unclassified and
must not be claimed as a validated FE/11 reply. No code change is needed to proceed
with controlled loaded/unloaded comparisons using the current build.

## Repeated loaded and unloaded sessions (0.5.6)

The user supplied two further completed results:

| Condition | Credential | Decoded bodies | Port-power updates | Duration | Cleanup |
| --- | --- | ---: | ---: | ---: | --- |
| Output loaded | Accepted | 87 | 29 | 31.283 s | Disconnected; passive scan resumed |
| Outputs unloaded | Accepted | 87 | 0 | 31.374 s | Disconnected; passive scan resumed |

The loaded result displayed field 852 at **−22.9 W, 15.3 V, 1.5 A**; other
allowlisted port fields had no measurements. The unloaded result showed missing
W/V/A for all port fields. No identity, serial, token or raw payload was supplied
or retained in these observations. The user identified the loaded physical port as **C1, labelled “140W in/out.”**
This maps field 852 to C1 in the tested output condition. Bank-screen wattage
comparison and input-direction validation remain pending. The reported loaded values are consistent in
magnitude with V × A (22.95 W using rounded display values), but that arithmetic
does not independently verify sensor accuracy or physical mapping.

There are now at least two fresh completed authenticated sessions with decoded
telemetry, including repeat loaded port-power updates. Unloading is associated
with absence of port fields, not an explicit zero-watt measurement. A reconnect
comparison and each accessible port/cable still need physical labels, direction,
and bank/official-app display comparison before the mapping gate is complete.

0.5.7 refines only the outcome text/state: accepted authentication with decoded
display bodies but no port-power fields is distinct from receiving no decoded
telemetry. Missing values remain absent; no zero is synthesized. Commands,
credentials, routing, deadlines and passive monitoring are unchanged.

| Protocol field | Physical mapping | Hardware evidence | Remaining comparison |
| --- | --- | --- | --- |
| 852 | C1, 140W in/out | Loaded output: −22.9 W, 15.3 V, 1.5 A; unloaded absent | Bank-screen wattage; input direction |
| 856 | Unverified | No measurement in the supplied runs | Test individually |
| 853 | Unverified | No measurement in the supplied runs | Test individually |
| 854 | Unverified | No measurement in the supplied runs | Test individually |
| 857 | Unverified | No measurement in the supplied runs | Establish physical applicability |

The built-in cable has not yet been physically mapped. The app-derived port
names are not substituted for missing hardware evidence.

0.5.7 validation: `build/Phase2EOutcome-R1.xcresult`, 85 tests executed with six
opt-in hardware checks skipped and zero failures (79 hardware-free passed).
The new state-machine test distinguishes a decoded body with no embedded port
measurement from silence, and verifies absence is preserved through cleanup.
Universal Debug/Release builds passed for arm64 and x86_64, Release signature
verification passed, and 0.5.7 was launched. Logs:
`build/TelemetryResearch/outcome-{debug,release}-r1.log`.

## Resume checkpoint

Work stopped at the user's request after publishing the current implementation.
The tested local app is 0.5.7. Authentication and repeated decoded telemetry are
verified; field 852 maps to physical C1 (140W in/out) in an output test. All other
physical mappings remain experimental.

Next user-assisted checks:

1. Compare C1's reported output watts with the bank's own display.
2. Load each remaining accessible port and the built-in cable individually using
   the same charging device. Run a fresh authenticated check for each and record
   the printed port/cable label, protocol field, W/V/A, direction and bank-screen
   wattage. Missing values must remain distinct from zero.
3. Confirm each run completes, disconnects and restores passive monitoring.
4. Update the mapping table above with observed evidence. Continuous monitoring
   and everyday wattage rows remain a separate future milestone.

No account ID or derived credential is retained in the repository. Identity entry
is still volatile and must be supplied again for a new check. Private code-only
research inputs and build/test artifacts remain ignored under `build/`.

## C2 payload rejection and diagnostic build (0.5.8)

On 28 October 2026 (Asia/Manila), the user tested C2, labelled “140W in/out,”
charging one device with no other ports connected. Existing-credential acceptance
succeeded. A 166-byte V19 FE/15 upload on the established route passed frame
validation but failed protobuf/measurement validation. The probe ended after
2.281 seconds, with zero decoded telemetry bodies and port updates, disconnected
and resumed passive scanning. The cause is not established; C2-specific content
is only a hypothesis. Previous successful C1 sessions remain valid evidence.

Version 0.5.8 adds typed structural payload-failure diagnostics: reason, top-level
or nested recognized port, recognized field, zero-based absolute payload byte
offset at the failing field's key, and expected/observed wire types when known.
Malformed keys report an unknown field. Unknown field numbers and payload values
are never exported. Reasons distinguish malformed/truncated data, wrong wire type,
nonfinite floats, invalid battery percentage, integer range and size limits.
Validation behavior, commands, routes, authentication and deadlines are unchanged.
Rejected bodies commit no partial measurements or success counters. FE/12 remains
unclassified, independent of telemetry receipt.

Next hardware check: repeat the same C2-only output setup using 0.5.8, allow the
bounded probe to finish and share Copy Diagnostics. Determine the precise rejection
before changing acceptance rules or resuming port mapping. No live 0.5.8 result
is claimed by synthetic verification.

0.5.8 verification: `build/Phase2EC2Diagnostics-R2.xcresult` passed 87 tests
with six opt-in hardware checks skipped and zero failures (81 hardware-free
passed). Synthetic tests cover structural categories and C2 nested fields,
absolute offsets, no partial measurement/counter commit, secret cleanup and typed
export. The initial sandboxed run could not execute SwiftUI compiler plugins;
the subsequent Xcode run passed. Universal Debug and Release builds both contain
arm64 and x86_64. Release signature verification passed, with only App Sandbox
and Bluetooth entitlements. Logs: `build/TelemetryResearch/c2-{tests-r2,debug-r1,release-r1}.log`.
Actual-bank 0.5.8 decoding, disconnection and passive scan restoration remain
the next user-assisted hardware check; native visual QA was not performed.

## Battery field isolated from port decoding (0.5.9)

The next C2-only user report on 0.5.8 again accepted the credential, then identified
`invalidBattery`, top-level field 262, byte offset 22, expected/observed wire 5.
The first 166-byte FE/15 upload therefore reached the float decoder and failed
the application range check, rather than authentication or frame validation.
The run ended after 1.525 seconds, decoded no bodies, disconnected and resumed
passive scanning. The raw battery value remains unknown.

The retained official app decodes that float and clamps it only in the PB501
consumer. In 0.5.9 Somnoire preserves valid port telemetry while marking an
out-of-range finite SOC unavailable, clearing any earlier retained SOC, and
exporting a structural `Telemetry measurement unavailable` warning. It never
clamps, scales, substitutes zero or infers a sentinel. A body must still pass all
other validation before either warning or measurements are committed. Authentication,
commands, routes, limits and passive battery monitoring remain unchanged.
See [P512 Protocol](P512-Protocol.md) for source evidence and semantic details.

Next hardware check remains C2-only output with the same device. Run 0.5.9,
record protocol fields and W/V/A separately from Copy Diagnostics, and confirm
normal bounded completion, disconnect and passive scan restoration. A passing
synthetic test does not establish actual-bank C2 measurements or physical mapping.

0.5.9 verification: `build/Phase2EBatteryIsolation-R1.xcresult` passed 89 tests,
with six opt-in hardware checks skipped and zero failures (83 hardware-free
passed). Added synthetic coverage includes C2 power with invalid SOC, inclusive
0/100, repeated SOC fields, old-value invalidation and recovery, malformed port
rejection, write-acknowledgement barriers, bounded completion and private export.
Universal Debug/Release builds passed for arm64/x86_64. Release signature verified;
entitlements remain App Sandbox and Bluetooth only. Logs are under
`build/TelemetryResearch/battery-isolation-{tests,debug,release}-r1.log`.
The verified Release was launched for user-assisted hardware validation.

## Verified output mappings and 0.6.0 dashboard

The user supplied three completed 0.5.9 output sessions: C2 decoded 87 bodies
with 29 port updates in 31.227 s; C3 decoded 87/29 in 31.647 s; C4 decoded
90/30 in 31.584 s. All accepted credentials, disconnected and resumed scanning.
The user confirmed wattage agreement and identified C2=856, C3=853, C4=854,
complementing the earlier C1=852 mapping. Approximately -1 W with 9.1–9.2 V
and 0.1 A was expected because the connected device was full. C3 is labelled
65 W maximum. Field 857 is the bottom dock/pogo connection; the user has no dock.
These are output comparisons; input direction remains app-convention-derived.

Version 0.6.0 introduces a native five-card dashboard with a separate live-session
mode. It uses the existing commands/authentication and streams only while the
panel is visible, with a 15-second validated-display inactivity deadline. Diagnostic
probes retain their original limits. Each W/V/A sample expires independently
after five seconds; missing data never becomes zero or a claim of disconnection.
The battery card uses advertisement percentage with explicit retained-reading age.
PD/PPS is omitted because the inspected UsbRealDisplayInfo schema contains only
W/V/A. Settings retains battery monitoring, selection, Forget and Diagnostics.

The numeric ID clears after Connect. A derived bank-specific credential remains
only in memory until Quit/Forget/target change/rejection. Each session receives
a separately allocated copy that is wiped after use. No account ID/token is
written to preferences, diagnostics or Keychain. Closing the panel cancels its
session and restores enabled passive scanning after disconnect; diagnostic-window
closure cannot cancel a live owner. Sleep/Bluetooth loss ends a session, and
errors require explicit Retry rather than a reconnect loop.

Pending user-assisted acceptance: stream beyond 30 seconds on the bank, unload
and change ports, close/reopen the panel, test positive input direction, and
confirm passive scanning resumes. Synthetic streams do not establish these
hardware behaviors.

0.6.0 local validation: `build/Dashboard-Final.xcresult` passed 93 tests with six
opt-in hardware checks skipped (87 passed). Added tests cover a synthetic
90-second live session, 15-second silence termination, credential copy cleanup,
independent sample expiry/zero, and native normal/accessibility-size rendering.
The empty dashboard renders were inspected; connected/error/stale battery visual
states and real AppKit panel lifecycle remain pending live UI verification.
Debug and Release contain arm64/x86_64; Release signature verifies and retains
only App Sandbox and Bluetooth entitlements. Logs: `build/dashboard-tests-final.log`
and `build/dashboard-release-final.log`. The verified Release was launched.

## 0.7.0 Battery Information checkpoint

Battery card In/Out watts now use device aggregate fields 3/4 directly. Health,
cycles, signed Celsius temperature and device energy counters are decoded from
the existing allowlisted uploads and exposed in the local diagnostic preview.
The dashboard disclosure retains per-field in-memory receipt ages across
disconnect, clearing snapshots on Forget/target change/Quit. Auto/Wh/kWh and
°C/°F are display-only preferences. No charging-limit or other device-setting
writes were added. Field/unit provenance is in P512 Protocol; bank availability,
accuracy and counter reset semantics remain unverified.

`build/BatteryInfo-Units.xcresult`: 97 tests executed, six opt-in hardware checks
skipped, zero failures (91 hardware-free passed). Tests cover signed int32
extremes/negative encoding, UInt32 limits, health isolation and recovery,
incremental ages, explicit zero, aggregate expiry, counter decrease replacement,
energy/temperature conversion and filtered presence-only diagnostics. Native
collapsed/expanded, populated/unavailable/aged detail renders and the dashboard
normal/larger-text renders were inspected. These are synthetic render checks,
not a live hardware/UI session. Universal Debug/Release contain arm64/x86_64;
Release signature and App Sandbox/Bluetooth-only entitlements verify. Logs:
`build/battery-info-tests-units.log`, `build/battery-info-release-final.log`.

Next check: connect in the dashboard, expand Battery Information and separately
record displayed measurements and Copy Diagnostics. Compare aggregate W under
output/input and the battery details against the official app in separate BLE
sessions. Unreported fields must remain unavailable. No hardware result for
0.7.0 is claimed from these synthetic tests.

## 0.8.0 Healthy Charging checkpoint

Battery Information and Healthy Charging share the dashboard card style. The
user confirmed the 0.7.0 battery values against the official app (100% health,
35 cycles, 31°C, 2.730/2.124 kWh input/output). Received temperature updates
continue at their source cadence; only connected samples under five seconds
old are labelled Live. No polling/report-period settings were introduced.

Healthy Charging reads fields 848/270/271 and stages mode/ceiling/floor edits
locally until Apply. Complete recognized current-session reports and an active
authenticated owner are required. Mode is verified first, followed by changed
limits only. Acknowledgement alone cannot produce Applied. A fresh complete
recognized post-refresh snapshot must match requested values and expected mode.
Timeout/cancellation results require refresh/review and explicit retry; confirmed
mode with unconfirmed limits is partial. No replay/rollback/restore is automatic.
See P512 Protocol for exact app provenance, field mapping and verification policy.

`build/Healthy-VisualGate.xcresult`: 99 tests, six opt-in hardware tests skipped,
zero failures (93 hardware-free passed). New coverage includes exact encrypted
requests against independent synthetic OpenSSL vectors, authentication refusal,
sequence/range refusal, known settings fields, pre-ack/stale readback refusal,
matching readback, mismatches/timeouts, cancellation without retries and unique
settings sequences. Unknown/editing card renders and Battery Information card
renders were inspected against a panel background; actual connected/applying/
failure interaction remains user-assisted UI validation. Debug/Release are
universal arm64/x86_64; Release signature verifies with only Bluetooth and
App Sandbox entitlements. Logs: `build/healthy-tests-visual.log`,
`build/healthy-release.log`.

No bank setting was changed during development. Next: compare reported healthy
mode/limits read-only with the official app in separate BLE sessions, then use
explicit Apply to verify mode and limits on the bank. Reconnect and compare
reported persistence. Restore original settings explicitly if desired. Physical
cutoff behavior remains unverified.

## 0.9.0 native settings checkpoint

The user confirmed Healthy Charging controls work. This is recorded as a
user-confirmed settings result, not independent physical cutoff validation.
Charging now uses five-percent limit/reserve sliders in a native settings window.
Existing intermediate values are retained until an explicit edit/Apply. A separate
Screen pane exposes the source-backed duration, brightness, art and clock scalars.
Window ownership preserves the authenticated session when the dashboard closes,
including owned image-picker sheets; final surface closure cancels pending work.

Local artwork selection/crop/zoom and original RGB565 packaging are implemented.
Upload is deliberately disabled pending lower-level native transfer acknowledgements,
resource identity and activation research. No transfer command is guessed. See
P512 Protocol for exact code provenance and remaining blockers. No app/account
storage, secrets or provisioning state was read or altered.

`build/Screen-ArtGate.xcresult`: 102 tests executed, six opt-in hardware checks
skipped, zero failures (96 hardware-free passed). Tests include independent
OpenSSL screen-write vectors, source-backed field/value restrictions, screen
readback without a Healthy Charging baseline, acknowledgement/stale/mismatch
handling, native light/dark pane renders, RGB565/header bytes, EXIF rotation,
square crop and alpha-to-black compositing. Unknown pane states were rendered;
connected controls, actual window/picker ownership and device interactions remain
user-assisted acceptance. Progress/error transfer states cannot be validated
because artwork transport remains gated. Universal Debug/Release and signing
checks accompany this checkpoint. Added entitlement: user-selected read-only files.
Logs: `build/screen-tests-art.log`, `build/screen-release-art.log`.

Next: read and compare the eight screen settings with the official app, then
explicitly Apply and compare supported durations, brightness, clock enable/format
and battery/charging durations on the bank, including reconnect persistence.
Artwork upload/activation remains an unfinished gated capability, with local
preview usable now. Hardware settings were not changed during development.

## 0.10.0 compact settings checkpoint

Charging and Screen are directly editable when recognized current-session data
is available. Each pane owns its draft, baseline and feedback, with a single
Apply/Revert area. Controls remain visible after verified success (Settings applied).
Drafts survive pane changes, preserve intermediate device values and detect
external conflicts. A pane-wide screen Apply uses sequential restricted writes,
verifying each and the final changed-field snapshot. No batch wire format or
untouched-field write was introduced. Charging keeps its mode-first sequence.

Closing settings cancels the settings queue independently of dashboard telemetry,
rejecting late acknowledgements and never replaying writes. Confirmed changes
are tracked for partial-completion feedback. Returning to settings after an
unconfirmed operation exposes Refresh/review rather than automatic retry.
Verified telemetry is merged before callbacks so subsequent writes see the
newly confirmed mode, rather than an earlier packet's state.

Default content sizes are 560×430 Charging and 560×570 Screen. Pane changes
resize the window while preserving its top edge, bounded by screen height;
telemetry does not resize it. Compact grouped rows replace repeated setting
cards, action areas and status labels. The artwork editor is a separate sheet
with a side-by-side crop preview and controls. Dashboard readout spacing and
Diagnostics' resizable log area were retained because they carry substantive
content rather than the settings window's unused fixed-height space.

Artwork upload remains incomplete and disabled. Additional static evidence on
A1/A2/A3 requests, acknowledgement payload checks and field-303 activation is
recorded in P512 Protocol. Negotiated chunk-limit semantics, independent packet
fixtures for the lower-level transfer and current-bank local-resource-ID
acceptance remain concrete research/hardware gates. No physical transfer or
settings write was attempted during this implementation.

`build/Compact-Panes.xcresult`: 104 tests executed, six opt-in hardware tests
skipped, zero failures (98 passed). Added tests exercise direct-draft initialization,
conflicts/Revert, pane feedback and settings-only cancellation while telemetry
remains active, including refusal of late acknowledgements. Existing protocol,
readback, image and unit regressions pass. Light/dark compact unknown-state panes
were rendered at actual default sizes and inspected; populated/working-bank
interaction, partial batch application and native sheet use remain user-assisted
acceptance. Upload progress/rejection/activation tests cannot establish a
nonexistent transfer implementation. Universal build and signature checks are
recorded with `build/compact-tests-panes.log`, `build/compact-release-final.log`.

## 0.11.0 onboarding checkpoint

Implemented General settings for selecting a bank and entering the existing numeric
ID fallback, plus native Launch at Login registration. A valid authenticated
telemetry upload gates local, non-synchronizing, device-only Keychain credential
storage. Quit clears the in-memory copy; Forget and rejection delete stored access.
The credential-store interface permits isolated testing without accessing Keychain.
Surface reopening and wake permit one connection attempt; failures require Retry.

The hardware-free suite passed 99 tests (105 total, six opt-in hardware tests skipped).
General settings was rendered in light/dark appearances. Actual Keychain persistence
across relaunch, login approval and larger accessibility sizing remain acceptance
items. No physical artwork upload or bank-binding change was performed. Artwork
transport remains incomplete and gated as detailed in P512-Protocol.md.
