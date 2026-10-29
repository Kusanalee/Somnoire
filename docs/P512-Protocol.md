# P512 telemetry: app-derived payload format

## Finding and confidence

The installed official EcoFlow Android app **6.17.4.14**, version code **11113**,
explicitly maps serial prefix **P512** to its **PB501** family. Its RapidStudio
interface decodes telemetry with the protobuf message `DisplayPropertyUpload`
and the nested message `UsbRealDisplayInfo`. This establishes an app-derived
payload schema for the P512 family; it does not establish live access in Somnoire.

The decoder and its tests in this repository are original Swift and public
synthetic data. No application bundle, generated vendor implementation, captured
packet, account value, device serial or credential is redistributed.

## Payload layout

The following is the **protobuf body after decryption and inner-packet validation**.
It is not a complete BLE request or encrypted envelope.

| Field number | App field | Wire representation |
| --- | --- | --- |
| 3 | `powInSumW` | float32, wire type 5 |
| 4 | `powOutSumW` | float32, wire type 5 |
| 262 | `cmsBattSoc` | float32, wire type 5 |
| 282 | `cmsChgDsgState` | uint32 varint, wire type 0 |
| 852 | `usbTypec1DisplayInfo` | nested message, wire type 2 |
| 856 | `usbTypec2DisplayInfo` | nested message, wire type 2 |
| 853 | `usbTypec3DisplayInfo` | nested message, wire type 2 |
| 854 | `usbTypec4DisplayInfo` | nested message, wire type 2 |
| 857 | `pogopin_1DisplayInfo` | nested message, wire type 2 |

**USB-C2 uses field 856**, rather than the adjacent field 853. The shared schema
also has USB-A at 855; that does not establish an additional physical port on P512.
USB-C protocol numbers above still need comparison with the bank's printed labels
and built-in cable before becoming user-facing port names.

Each `UsbRealDisplayInfo` submessage has:

| Field number | App field | Unit and representation |
| --- | --- | --- |
| 1 | `usbPow` | watts, little-endian IEEE-754 float32, wire type 5 |
| 2 | `usbVol` | volts, little-endian IEEE-754 float32, wire type 5 |
| 3 | `usbAmp` | amps, little-endian IEEE-754 float32, wire type 5 |

There is no integer `/10` or `/100` scaling in this app path. The app rounds
measurements to one decimal for display. Its chart logic classifies **positive
watts as input** and **negative watts as output**, plotting the output magnitude.
Zero and absent values remain distinct in Somnoire's decoder. The app defaults
some missing values to zero; Somnoire deliberately preserves field presence.

The app consumes multiple payloads from `payLoadAllMap[21]` (`0x15`), decodes each,
and merges the resulting fields into retained state. This is evidence for
incremental updates. It establishes the display-upload command ID/cache key,
not a complete verified BLE route or read request. A new update must not make
omitted port measurements fresh.

## Original decoder

`P512TelemetryDecoder.decodePayload` returns a typed `P512TelemetryDelta`.
It supports the fields above, merges repeated embedded messages, keeps explicit
zeroes, preserves signs and skips unknown varint/fixed64/length-delimited/fixed32
fields. Invalid lengths, overflowing varints, wrong wire types for known fields,
nonfinite floats, out-of-range battery percentages and oversized payloads fail.

Delta merging retains unreported measurements. A future live session must track
receipt/freshness per measurement independently. Explicit diagnostic access probes
can decode allowlisted uploads; production wattage UI remains gated. Synthetic
decoding is not hardware validation.

## Remaining access question

The known `35/89` request is authentication status, not the port-power query.
Four earlier Somnoire sessions received only its reply, including under load;
see [Phase 2C](Phase2C.md). Those replies did not prove an account requirement.

Static inspection of the app's normal authentication path shows a separate
account-derived MD5 authentication step involving `ConfigHelper.userId()` and
its destination serial argument. The status-handling code distinguishes starting
authentication from refreshing it. This makes authentication a concrete lead for
why a status-only session is silent. It is **not** a device experiment proving
that every possible P512 telemetry read requires an account.

Neither the P521 charger's placeholder authentication identity nor another model's
settings/read commands are verified for P512. No account data was read, no login
was attempted, and no new device requests were sent during this schema research.

Phase 2E subsequently established existing-credential acceptance and valid V19
frames on the current bank. A 0.5.5 report observed repeated FE/15 uploads via
`02/01→21/00` after authentication and the fixed display request. The report's
166/29/15-byte bodies were excluded by the old route allowlist, so this establishes
stream reception rather than decoded power. Version 0.5.6 permits that exact route
only in authenticated V19 sessions. The first complete 0.5.6 session then decoded
87 bodies with 29 port-power updates and resumed passive scanning after disconnect.
Measurement values and physical mapping still need comparison; see [Phase 2E](Phase2E.md).

Still to establish on the actual bank:

- A second fresh decoded session and physical measurement/load comparisons.
- Whether the same uploads would begin without the fixed display request.
- The permitted account-free path, if one exists.
- Physical mapping of the four USB-C protocol fields and built-in cable.
- Agreement of signs, units and updates with each loaded/unloaded port.

## Reproducible local evidence

The user connected the previously used Android phone through its authorized debug
connection. Only the installed `com.ecoflow` package files and package version
metadata were read. Application code was inspected statically; no app/account
storage, logs, session secrets or credentials were read. APKs and extracted assets
remain ignored under `build/TelemetryResearch/`.

- Base APK SHA-256: `3deca87e4348b390e181e4d1407907adf7982d88feb0dda808cb4975832cfea1`.
- `assets/bundle/RapidStudio.bundle` SHA-256:
  `8ae3d66eb02c0b268670219613bcb00ca17cfa018f567920bd8c7d489673eed3`.
- Bundle module suffix `35000617`: P512/P511 to PB501 mapping.
- `35000683`: generated `DisplayPropertyUpload` and `UsbRealDisplayInfo` schema.
- `35000689`: port-value conversion and one-decimal display rounding.
- `35000691`: payload cache key 21 and incremental message merging.
- `35000652`: positive-input/negative-output chart classification.
- `classes9.dex`: `EFAuthHelper.startAuthNormal`, `refreshAuthNormal` and
  `EFAuthHelper$startDeviceAuth$1` contain the authentication lead described above.

The [public pinned shared schema](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/proto/dev_apl_comm.proto)
corroborates these field numbers. The important new evidence is the installed
app's explicit P512 family mapping and its decoder/data flow, rather than an
assumption that another RAPID product shares the same behavior.

## Validation

Six new hardware-free tests cover an independently constructed multi-port
float32 payload, nonsequential port tags, signs, missing versus zero values,
incremental/repeated-message merging, unknown fields, slices, truncation,
varint/length limits, wrong wire types and invalid scalar values.

Full suite: **59 passed**, five opt-in hardware checks skipped, zero failures
(`build/P512SchemaTests.xcresult`). Live telemetry and physical port comparisons
remain unverified. The older capture may come from a different app version; the
schema provenance above is specifically the installed 6.17.4.14 build.

## Subsequent access experiment

[Phase 2D](Phase2D.md) now documents a fixed one-shot display-report request and
typed status interpretation. It was tested twice without login or credential
changes; neither attempt returned telemetry. The shared authentication-status
summary selected checking an existing credential in normal mode. First-use local
provisioning remains a research design with no never-linked hardware validation.

Phase 2E later confirmed repeated authenticated decoded sessions, including field
852 at −22.9 W / 15.3 V / 1.5 A while charging from physical C1 (140W in/out),
as identified by the user. Unloaded port fields were absent rather than explicitly
zero. Other ports, the built-in cable, input direction and bank-screen comparison
remain unverified; the current results are in [Phase 2E](Phase2E.md).

## Out-of-range SOC handling (0.5.9)

The 0.5.8 current-bank report isolated the rejection to finite field 262 outside
0–100, with matching float wire type, at payload byte offset 22. The value itself
was not exported and is unknown; no sentinel, scaling or C2-specific cause is
established. Reinspection of the retained official 6.17.4.14 RapidStudio bundle
shows `DisplayPropertyUpload` decodes `cmsBattSoc` as float without a range check.
The PB501 `handlePayload` consumer clamps it using `Math.max(0, Math.min(..., 100))`
after decoding, rather than rejecting unrelated port data.

Somnoire 0.5.9 instead marks an out-of-range finite SOC unavailable and exports
a typed structural warning. It does not clamp or reinterpret the value. Other
valid fields in the fully validated body may be committed. Such an update clears
a previously retained SOC; omission preserves the current state and a later valid
SOC recovers it. Repeated SOC fields use the last occurrence. Wrong wire types,
malformed/truncated protobuf, integer overflow and nonfinite floats still fail
the entire body without partial commits. This intentionally supersedes the older
whole-body rejection of finite out-of-range battery percentages described above.
Passive advertisement battery validation remains unchanged.

## Battery Information (0.7.0; source-derived, bank comparison pending)

The same retained official 6.17.4.14 RapidStudio bundle provides:

| Field | Meaning | Wire type / base unit |
|---|---|---|
| 3 / 4 | Aggregate input / output power | float32 / W |
| 263 | Battery health | float32 / percent |
| 1251 | Battery cycles | uint32 / count |
| 102 | Battery temperature | int32 / °C |
| 1275 / 1274 | Total energy in / out | uint32 / Wh |

Module 35000683 defines the protobuf types; Battery Information screen 35000749
reads these values from the current data cache. Utility module 35000645 passes
Celsius through or converts to Fahrenheit, and `handleKWH` uses Wh below 1000
and divides by 1000 for kWh. This establishes representation and display units,
not actual-bank availability, accuracy, counter reset policy or lifetime semantics.
No additional device commands are added. The counters are not integrated from
watts, accumulated by Somnoire, or interpreted as lifetime/session totals.

The decoder preserves field presence, unsigned counter precision and signed
protobuf int32 temperatures, including sign-extended negative varints. Finite
health outside 0–100 becomes unavailable with a typed warning; structural errors
and existing nonfinite-power failures remain fatal. No health estimate or SOC
clamping is introduced. Diagnostics export only allowlisted field presence and
structural warnings, never measurement values. The local historical diagnostic
preview displays the new measurements for user-assisted comparison.

The dashboard uses device aggregate power directly with independent five-second
expiry. Battery Information retains each field's own receipt time in memory for
the selected bank, including after disconnect. Forget, target change and Quit
clear snapshots. Display preferences Auto/Wh/kWh and °C/°F alone persist locally.
Auto uses Wh below 1000 and kWh above; three kWh decimal places preserve Wh
resolution. Counter decreases replace the prior reading without wrap/reset inference.

Hardware acceptance remains pending: compare aggregate W under input/output,
then compare health, cycles, temperature and counters against the official app
in separate BLE sessions. Missing fields remain unavailable; they do not justify
guessing extra requests. Charging limits and all settings writes remain excluded.

## Healthy Charging (0.8.0; write/readback hardware gate pending)

Retained official RapidStudio module 35000697 exposes healthy mode (1 enabled,
2 disabled), charge ceiling 80–100 and discharge floor 0–20 in 1% steps.
Module 35000698 establishes slider defaults 0/100 and the restricted ranges.
Modules 35000679/35000681 serialize ConfigWrite using COMMAND_CONFIG
21→02 FE/11; schema module 35000683 defines uint32 fields 188 (mode),
33 (ceiling), 34 (floor). Reported uint32 fields are 848, 270 and 271.
Unknown/missing mode or limits disable editing rather than assuming defaults.

The new C constructor accepts only those three fields, validated ranges and
a request sequence >=3 after same-context credential acceptance. It provides
no arbitrary payload, command or destination interface. Settings requests use
distinct session sequences, validated framing and existing encryption. Mode is
written and verified before changed limits; untouched fields are omitted.
Disabling in the editor discards unsent limit edits. Native encryption is
compared with independent Python/OpenSSL synthetic vectors, reproduced by
`scripts/generate_probe_vectors.py`. No bank/account data is in fixtures.

After each settings GATT acknowledgement, the existing fixed full-display
request is sent. Its acknowledgement opens a five-second readback window; only
subsequent validated FE/15 bodies can confirm a complete recognized settings
snapshot matching the requested changes and expected mode. FE/12 remains
unclassified. Write/refresh acknowledgements have three-second deadlines.
Timeouts, failures or cancellation never retry, roll back or restore settings.
A confirmed mode followed by unconfirmed limits is reported as partial. Refresh
and explicit review/retry are required after an unconfirmed result.

Actual bank mode/limit reads and writes, persistence after reconnect, and
physical cutoff behavior remain unverified. First compare read-only reports
with the official app in separate BLE sessions; then perform explicitly chosen
Apply actions and readback comparisons. Only explicitly restore original values.
No provisioning, reset, reporting-period changes or unrelated settings are added.

The user confirmed the 0.7.0 Battery Information values against the official app:
100% health, 35 cycles, 31°C, 2.730 kWh input and 2.124 kWh output. The log
shows field 102/263 updates about once per second; each is applied as received.
Temperature is labelled live only while connected with a sample under five
seconds old. Retained/stale values remain explicitly last-reported.

## Screen settings and artwork readiness (0.9.0)

Official retained screen-settings module 35000703 defines information duration
30/60/300/600/1800/3600 seconds and P512 brightness 0–100. Clock module
35000713 defines enable=1/disable=2, format=1 for 12h/2 for 24h, separate
battery/charging durations, and charging-only Never=4294967295. Schema module
35000683 maps reported→ConfigWrite fields as follows:

| Setting | Reported | Write |
|---|---:|---:|
| Information duration | 18 | 12 |
| Brightness | 5 | 14 |
| Art enabled/duration | 822/823 | 301/302 |
| Clock enabled/duration/format | 825/826/827 | 304/305/306 |
| Charging clock duration | 1259 | 554 |

The native constructor allowlists only these eight ConfigWrite fields and
app-derived values, requires authenticated context and sequence >=3, and zeroes
output on refusal. One explicit row Apply sends one changed field; no brightness
writes occur while dragging. Fresh matching post-refresh FE/15 reports verify
changes through the existing settings acknowledgement/readback state machine.
Unknown reported values disable the relevant row. Current charging behavior is
user-confirmed; physical charge cutoff is still not independently established.

Artwork module 35000731 establishes a P512 240×240 still-image format: rounded
and saturated RGB565, little-endian pixels, a four-byte packed image descriptor,
and a 72-byte big-endian resource header (version 2, type/subtype 4, type-3 file,
index 1, offset 72, body size 115204, trailer constant 1442735868). The original
codec and synthetic tests implement that layout. Local PNG/JPEG selection uses
ImageIO orientation normalization and bounded 2048px decoding, square crop/zoom
and black compositing. No image bytes or file paths enter diagnostics. No
converted temporary file is created; image data remains in editor memory.

Upload remains disabled. Static inspection found FileTransmitManager in
classes54.dex delegating transfer setup/data/completion to ha0/a (methods d/b/c).
Exact lower-level packet/checksum/acknowledgement interpretation, resource
identity and verified activation remain unresolved. The React path also uploads
artwork to cloud services; Somnoire does not reproduce that path. These are
concrete remaining research gates, not proof that local BLE upload is impossible.
No speculative transfer packets, cloud/network entitlement, automatic retry,
resource replacement or deletion are introduced.

Session ownership is the union of dashboard visibility and the dedicated settings
window. Closing one owner preserves the other; minimizing/hiding the settings
window releases its owner, while owned picker sheets do not. Final closure, sleep
or Bluetooth loss cancels pending operations. Only the user-selected read-only
file entitlement is added. Artwork transfer progress, cancellation protocol and
activation/readback acceptance cannot be tested until the transfer gate is resolved.

## Artwork trace refinement (0.10.0; transport still disabled)

Further static inspection of retained classes54.dex establishes that ha0/a
constructs authenticated-packet candidates with source 0x21, destination 0x02,
command set 0x01 and commands A1/A2/A3 for setup/data/end. FileTransmitManager
uses separate callbacks: setup requires a payload of at least seven bytes and
a zero status at byte 1, then interprets bytes 3..<7 using ByteUtils.bytesToInt.
The data callback requires at least three bytes and zero status at byte 1.
These are source-level findings, not current-bank transfer evidence.

The setup builder carries a 50-byte UTF-8 filename, file type, transfer options,
size and checksum. The chunk builder appends two four-byte values. q.U emits
little-endian integers; q.B returns a two-byte CRC result that setup pads to
four bytes. The meaning of the negotiated setup limit, its relationship to
chunk size/index arithmetic, and exact byte helpers must be independently
reproduced before live transfer. Packet constructor overloads/routing must be
verified against synthetic vectors, rather than guessed from constants alone.

React artwork module 35000721 applies ConfigWrite field 303 with nested
ScreenFileIndexInfo.fileId (protobuf string field 1), then compares reported
selected-file identity from field 824. The current app obtains identities via
its server library. Acceptance/collision behavior for a locally generated ID
and cancellation/resource-capacity semantics have not been established on this
bank. No unsupported deletion/replacement, cloud upload or speculative packet
is used to bypass those gaps. Local preview is available, but upload remains
unavailable and must not be described as complete.

## 0.11.0 research checkpoint

Reinspection of classes54.dex FileTransmitManager.n/p resolves the setup reply's
positive integer as packSize: totalPackets = ceil(fileLength / packSize), with
one-based currentPacket. The data slice starts at (currentPacket-1)*packSize,
ends at min(currentPacket*packSize,fileLength), and Arrays.copyOf pads it to
packSize. ha0/a.b appends two little-endian uint32 values to the version-1-prefixed
data. q.B returns CRC low byte followed by high byte; setup pads that to four bytes.
The CRC helper b0.b starts at zero and uses a table recurrence. These findings
remain static evidence; no transfer packets have been sent by Somnoire.

The linked-bank auth-status callback still delegates normal authentication to
bleAuthNormal. No verified anonymous or physical-presence route preserving its
existing binding was found in the inspected path. Somnoire retains the existing
credential fallback and adds local Keychain storage after valid telemetry.

Artwork upload is not complete: the server-issued file-ID format/acceptance and
collision rules, plus reply-to-request correlation through the native task layer,
remain unestablished. The crop editor stays available, Upload stays disabled,
and no resource or credential replacement is attempted. A full transfer coordinator
and live acceptance remain outstanding rather than being represented as working.

## 0.12.0 investigation (not released)

The user confirms remembered access works across relaunch. The remaining account
objective is first-time setup without an EcoFlow account ID.

| Candidate | P512 evidence / required state | Authentication change | Outcome |
|---|---|---|---|
| Existing normal credential check, 35/86 | Linked current bank; validated | No | Working fallback; depends on initial account-derived credential |
| Anonymous display request, FE/11 | Earlier bounded current-bank experiment | No | No decoded telemetry; only this candidate ruled out |
| Normal setAuthentication, 35/85 | App helper's unprovisioned branch | Yes | Excluded on the current linked bank |
| OMOS authentication | Status-selected alternate helper; uses user token and refresh API | Potentially | Not an established account-free P512 route |
| Physical-presence access | No applicable path established in inspected helpers | Unknown | Requires further evidence; no packet guessed |

Further inspection of FileTransmitManager callbacks confirms that chunk and end
callbacks consume already-dispatched Packet objects, distinguish transport errors
from payload rejection, and decode a device error at byte 2 on rejection.
They do not establish request correlation themselves; tracing must continue in
the protocol dispatch layer. The setup callback uses a seven-byte minimum and
extracts its negotiated value from bytes 3..<7. These are static findings only.

Android observation feasibility: one authorized Android 17 device is connected.
The installed com.ecoflow package is not debuggable (run-as refused). The Bluetooth
snoop directory is inaccessible to shell; no legacy shared-storage snoop file was
present. A broad bugreport was not collected. The app's FileTransmitManager log
calls delegate through t0 to an eq/a logger; whether that release logger exposes
usable scoped plaintext evidence is not yet established. No artwork upload has
been requested or performed during this investigation. Release remains 0.11.0.

### User-observed official-app Bluetooth restriction

The user reports that the official app does not support its artwork feature while
the bank is connected through Bluetooth. The planned official-app upload therefore
did not occur. The scoped observation recorded zero structural transfer events;
it was cancelled and the temporary debug.app.xlog.enable property restored to its
original unset value. This establishes an official-app Bluetooth-mode restriction,
not a verified firmware-level impossibility of BLE transfer. The generic native
A1/A2/A3 implementation is not sufficient evidence of P512 BLE artwork support.

For the current BLE-only product, custom artwork upload is deferred. Existing
verified screen settings remain in scope. No 0.12.0 artwork release or transfer
success is claimed; the working 0.11.0 release is retained.


## Clock sync and Bluetooth-only UI revision

Revalidated installed Android 6.17.4.14 base APK against the retained SHA-256.
The normal helper still obtains an authorizing identity/secret and selects
checkAuthentication for linked devices; the unprovisioned branch selects
setAuthentication. No new P512 anonymous or physical-presence candidate was
established. No additional hardware probe, credential change, or account guessing
was performed. The one-time account-ID fallback remains necessary for currently
verified first-time access; Keychain reconnect remains unchanged.

RapidStudio module 35000713 obtains CLOCK_THEME through app/screen/theme/list,
blocks selection in Bluetooth mode, and transfers nondefault theme resources
before selecting ConfigWrite 190 (reported nested string identity 770).
Artwork uses field 303 and reported identity 824. Generic native A1/A2/A3
support still does not establish P512 resource-ID collision, capacity, cancellation,
or activation behavior. No safe live resource trial was established; no transfer
was attempted. The preview-only editor was removed from the UI; artwork enable
and duration remain. Resource identities are decoded as bounded UTF-8 strings,
without exposing an unverified selector or adding a resource-write constructor.

Timezone source: module 35000643 sends cfgUtcTime (6, uint32 Unix seconds),
cfgUtcTimezone (7, int32), cfgUtcTimezoneId (135, string), cfgUtcSetMode
(136, bool). Display fields 133/134/135 report offset/ID/mode. Native
EFNativeModule.appGetTimeZone delegates to h4$a.g: it adds current DST savings
to the raw Java timezone offset, divides milliseconds by 1000, divides seconds
by 3600, then multiplies by 100. This establishes east-positive whole hours *100;
its fractional-hour truncation is deliberately refused by Somnoire.

The new bounded C constructor permits only these four clock fields after
existing-credential acceptance, uses capacity 256, signs negative protobuf int32
values correctly, and rejects invalid timezone IDs and unsupported offsets.
Clock writes share the existing serialized acknowledgement/full-report/fresh
readback flow. Separate sync status confirms only offset, ID and automatic mode;
UTC time has no established report echo, so UI says clock time sent. No physical
clock comparison or live timezone write was performed in this revision.
Automatic sync defaults on, is saved locally, coalesces events, and never starts
a background connection. Failed attempts do not retry without another explicit
system event or normal reconnection. Existing settings Apply remains separate.

Validation: final hardware-free suite executed 107 tests, six hardware checks
skipped, zero failures (101 passed), including native clock constructor bounds,
negative offset acceptance, sequence refusal, fractional-offset refusal, missing
fields, malformed resource identities and fresh readback serialization.
Logs: build/clock-tests-native.log and build/clock-release.log. Universal Release
contains arm64/x86_64 and passes codesign --verify --deep --strict. Screen settings
were rendered and inspected in light/dark appearances at 560x570. Physical time,
resource transfer, and account-free hardware success remain unverified.


## Local-only scope revision (supersedes clock/artwork product claims above)

Removed Screen Art enable/duration, the image codec, resource identity decoding,
artwork write fields 301/302, and user-selected-file entitlement. Fields 303/190
remain refused. The clock keeps its installed artwork; Somnoire does not select
or replace it. Display and ordinary clock controls remain supported.

The prior automatic sync error did not establish device rejection. The path
collapsed request refusal, transport failure, cancellation and missing/mismatched
readback into Bool. Confirmation required fresh 133/134/135 fields; Bluetooth
write callbacks only established transport completion. Clock diagnostic outcomes
now distinguish these cases and export only field-presence/matching masks.
Clock readback is a small dedicated type, separate from charging values. Closing
settings cancels pane settings but does not cancel an active clock diagnostic.
Independent OpenSSL fixtures now compare the complete encrypted four-field UTC
request for east-positive and negative offsets. Fractional offsets remain refused.

Automatic clock sync is disabled in all Release paths: no preference reads,
notification observers, scheduling, or automatic writes remain. An internal Debug
entrypoint is reserved for explicit bounded hardware tests. Old saved true values
cannot activate it. The feature can return only after physical clock comparison
and reliable fresh readback; a transport callback is not sufficient evidence.

Focused authentication re-review: normal-check uses the account-derived secret,
normal-set is provisioning (excluded), and the alternate OMOS helper depends on
account tokens. No applicable P512 physical-presence command was established.
The upstream implementation also derives auth from user ID plus serial. No new
anonymous candidate justified a live probe, and the failed FE/11 candidate was
not repeated. Current verified access still needs one-time authorizing account
setup; this is not a universal impossibility claim.

Bundled first-time setup and README describe official phone-app onboarding,
existing-account preservation, regional browser ID retrieval, connection handoff,
and Keychain relaunch verification. Source: https://github.com/rabits/ha-ef-ble/issues/130
The older wiki login-response method is flagged as outdated. Regional browser
steps are community-reported, not a new authenticated end-to-end test here.
No passwords or web login tokens enter Somnoire. Notifications remain deferred.


Hardware observation in this round: the user reports the bank displays 11:37 PM,
matching the Mac. This verifies the observed display time, not which earlier
operation set it or reliable automatic sync. One opt-in diagnostic attempted to
establish a saved-bank session for 30 seconds and skipped because no live session
was established; it sent no clock request. No further attempt was made because
there was no new transport/readback evidence. Release sync remains disabled.

Final validation: build/local-only-verified.log records 109 tests, seven opt-in
hardware checks skipped, zero failures (102 passed). Exact native UTC vectors,
removed-field refusal, missing readback, pane-independent clock ownership,
transport/cancellation distinctions, disabled-preference migration and numeric
setup validation pass. build/local-only-clock-hardware.log records the separate
no-session skip and no clock write. Universal Debug/Release build, codesign
verification and arm64/x86_64 checks passed. Release entitlements are now only
App Sandbox and Bluetooth. Screen and bundled setup were rendered in both
appearances; regional authenticated browser retrieval was not exercised.

## Basic mode, shared percentage, native settings and local alerts

Percentage-only is the default for new installs; existing selected-bank Keychain
access migrates to full readings unless an explicit mode was already saved.
Basic selection completes setup without an ID; surface opening and startLive
cannot initiate authenticated access in basic mode. Switching mode ends the live
session and drops in-memory drafts/access, preserving the stored bank credential.
Forget keeps its removal semantics and clears local notification episode latches.

Both menu label and dashboard now consume BatteryPresentation, recording only
validated advertisement or authenticated SOC values for the selected bank.
Freshness uses monotonic sample time with a 30-second limit; wall-clock Date is
for the displayed age only. Connecting never promotes a cached value to fresh.
Stale percentages remain dimmed and labelled last seen; absent readings use a dash.
Alerts require enabled monitoring and a fresh selected-bank percentage.

Settings uses a stable native sidebar window and grouped content. Basic mode
hides charging/screen and unit preferences. Full mode retains staged drafts across
pane navigation. Entire limit/reserve rows dim and disable from the draft mode.
Battery details stay expandable; unit selectors moved to General and duplicate
Settings action was removed. The only dashboard settings entry is the footer gear.

Native notification feasibility was tested in the actual ad-hoc Release bundle:
build/notification-feasibility.log records authorization=true and one delivered
notification; the user also confirmed receiving it. No paid signing, Developer ID,
notarization, push entitlement or network service was used. The temporary probe
entrypoint was removed. Alerts are opt-in, default 20% with 10/15/20/25/30 choices,
silent, with per-bank/threshold persisted episode latches. Fresh recovery to
threshold+5 rearms; stale data, duplicate samples and relaunch do not re-alert.
Permission is requested only on enable and checked before delivery. A test action
and permission status are included. No monitoring is promised during sleep/quit.

build/basic-final.log: 113 tests, seven hardware checks skipped, zero failures
(106 passed). Added tests cover basic mode persistence/no live attempt, percentage
expiry/invalid data/zero, alert hysteresis and latch preference persistence.
Settings (all sections), basic dashboard and battery details were rendered and
inspected in light/dark. build/basic-final-release.log records universal Release;
codesign verification and arm64/x86_64 checks passed, with only App Sandbox and
Bluetooth entitlements. Broader onboarding and GitHub Pages remain deferred.

Passive hardware acceptance was attempted using the explicit Continuous Monitoring
scheme. CoreBluetooth remained "Waiting for Bluetooth" with zero advertisements;
therefore the initial assertions could not be satisfied. This is not a verified
live percentage result. The opt-in test now skips if Bluetooth never becomes ready,
while retaining its assertions when hardware is available. No GATT or device-setting
writes were issued by this attempt. Native notification delivery was independently
verified as described above. Hardware-free final suite still reports 106 passed.

## Onboarding and identity polish (2026-10-29)

Added a persisted welcome/setup route for account-free percentage monitoring or
optional full readings. Bank selection completes basic setup; full setup still
requires successful authenticated telemetry. Dismissed setup retains its step,
without retaining the account-ID field. Existing completed setups skip the guide.
The supplied app icon is bundled as a multi-resolution ICNS and reused in Welcome
and About. A running Dock item appears only while app windows are open.
System/Light/Dark and Default/NouNou icon preferences are local. The NouNou
mark is a sparse native template drawing inspired by the supplied awake/sleepy
references, rather than a reduction of all their fine artwork details.
Diagnostics menu entries were removed. About unlocks its separate Diagnostics
button after thirteen icon activations, for this process only.

Relative ages now say recently, five-minute buckets from 10 through 55 minutes,
or a long time ago after an hour. This is display-only: the monotonic 30-second
freshness limit, alert policy and source observation dates are unchanged.

Clock review retained the established four-field constructor, independent signed
packet vectors, acknowledgement correlation and fresh-report confirmation gate.
Two bounded diagnostic sessions ran (build/polish-clock-hardware.log and
build/polish-clock-hardware-2.log). The first could not authenticate while using
basic-mode preferences; the second used isolated full-readings preferences and
reached Bluetooth ready but established no live session within 30 seconds.
Neither sent a clock request. The user cannot currently observe the bank's clock;
the earlier matching-time observation therefore cannot establish this revision's
clock behavior. No further attempts were made. Automatic writes/observers remain
disabled, including migration of older enabled preferences. Screen settings now
says to set time in the official EcoFlow app. Binding and resource data were not
changed.

Validation for this revision: build/polish-final-tests.log executed 118 tests,
seven opt-in hardware checks skipped, zero failures (111 passed). The suite
includes setup route/resume gates, coarse-age boundaries, thirteen-click unlock,
asset loading/template states and rendered setup/About panes, alongside existing
mode, authentication, readback and clock-vector coverage. Light/dark rendered
Welcome, full-access setup, About, settings and awake/sleepy template marks were
inspected. build/polish-release.log records a universal x86_64/arm64 Release build;
codesign strict verification passed and entitlements remain sandbox + Bluetooth.
Dock policy and appearance switching are implemented; interactive window-lifecycle
acceptance on a running Release instance is not recorded by these render tests.

## Dashboard consolidation and fractional display (2026-10-29)

The dashboard now has only Quit and a direct Settings gear as its action buttons.
Monitoring, selection, Forget, setup and Retry are in General; connection status
appears only in General. About follows Screen (or Alerts in basic mode) and the
Check for Updates button opens GitHub releases without runtime update requests.

BatteryPresentation retains the validated Double conversion of reported Float SOC.
The 0/1/2/3-place preference is formatting only, trims trailing zeros, and caps
advertisements at whole percentages. No fractional readings are inferred. The
original integer-rounding conversion remains independent for alert evaluation;
source selection, sample dates, freshness and hysteresis remain unchanged.

Supplied color NouNou images are bundled at 20/40 pixels; Xcode combines the PNG
pairs into TIFF representations loaded as original-color NSImages. Removed the
hand-drawn template marks. AppIcon.icns is named explicitly in CFBundleIconFile.
The bundle identity and notification authorization mechanism were preserved.

Validation: build/refinement-verified-tests.log executed 120 tests with seven
opt-in hardware checks skipped, zero failures (113 passed). Includes fractional
rounding, whole advertisements, invalid/nonfinite rejection, age/source retention,
alert conversion independence, and both color image representations. Rendered
General/About and color icons were inspected. Universal Release succeeded in
build/refinement-verified-release.log. Automated desktop access timed out twice,
so the final Release notification banner icon has not been visually confirmed;
the user was asked to test it through Alerts. No system-wide icon-cache reset or
notification authorization reset was performed. Clock sync remains disabled.

### Notification icon follow-up

The user confirmed the refinement Release test still displayed a generic banner
icon. Launch Services inspection found 32 registered Somnoire development copies.
NSWorkspace.urlForApplication resolved the shared identifier to build/Basic's
iconless Debug bundle; the running app was a different Xcode DerivedData Debug
copy. This establishes an application-resolution conflict, but does not prove
that it is the only cause of the Notification Center placeholder.

Incremented CFBundleVersion from 20 to 21, built universal Debug/Release, and
refreshed only the current Release registration with the public LSRegisterURL API.
The system now resolves the identifier to the current build/Polish Debug bundle
(build 21, which includes the icon). NSWorkspace's resolved file-icon lookup was
rendered and inspected: it returns the supplied Somnoire artwork. Both builds
succeeded (build/notification-icon-debug.log, build/notification-icon-release.log)
and strict Release signature verification passed. No permission resets, bundle-ID
changes, global cache resets or old build deletion occurred. A fresh build-21
notification banner remains pending user verification; this is not yet a confirmed
notification-icon fix.

### Compiled icon catalog candidate (build 22)

The user confirmed build 21 still showed the generic notification icon, despite
correcting application lookup. The registration conflict was therefore not a
sufficient explanation or fix. Build 22 replaces the manually copied ICNS resource
with Xcode's standard macOS app-icon asset catalog, compiled from the supplied
source at all standard/Retina icon sizes. actool now generates Assets.car,
AppIcon.icns, CFBundleIconName=AppIcon and CFBundleIconFile=AppIcon. The identifier,
permission flow and notification content are unchanged.

build/icon-catalog-release.log records a successful universal Release build;
strict signature verification passed. build/icon-catalog-tests.log executed 120
tests, seven opt-in hardware checks skipped, zero failures (113 passed), including
new integration assertions for generated icon metadata and resources. Desktop UI
access succeeded for the build-21 Settings window, allowing a normal Quit; build
22 was then launched. NSRunningApplication confirms the running bundle is
build/IconCatalog/Build/Products/Release/Somnoire.app. UI automation cannot obtain
its menu-only state, so the user was asked to send a fresh test from build 22.
Notification-banner appearance remains unconfirmed, rather than claimed fixed.

### Build 22 live result

The user confirmed build 22 also displays the generic notification icon.
Consequently neither registration repair nor the compiled app-icon catalog is a
verified banner fix. Somnoire-specific usernoted/NotificationCenter logs show the
fresh test notification accepted and presented as a banner/list without sound;
the inspected output contains no signing rejection or specific icon error.
This does not establish the icon failure's root cause.

Apple's notarization documentation describes distribution/Gatekeeper security,
not a requirement for local-notification artwork:
https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
A separate vendor reports notification-icon refresh failures on recent macOS:
https://github.com/Jamf-Concepts/Notifier/issues/34
That report uses runtime icon replacement and is not proof of Somnoire's cause.
No evidence currently justifies paid signing/notarization as a remedy. Retain
working local alerts and standard compiled icon packaging; document the generic
banner icon as a cosmetic limitation. No notification database edits, permission
resets, private API icon overrides or system-wide cache changes were attempted.

## Kusanalee stable-identity upgrade (builds 23–24)

The personal installation now uses io.github.kusanalee.Somnoire, organization
kusanalee, and io.github.kusanalee.Somnoire.bank-credential. A persistent local
code-signing certificate in the login Keychain signs Debug and Release. Its
private key is not in the repository; temporary generation/export files were
removed. Code-signing trust was configured in the user domain only, not system
trust stores. No paid account, notarization, fabricated Team ID or weakened
identifier-only designated requirement was used.

Installed at ~/Applications/Somnoire.app, preserving prior installations and
legacy data for rollback. Direct preference import encountered macOS container
protection. The original preferences were privately backed up; no protection was
bypassed, and guided setup was used. Basic monitoring selected the nearby bank;
full mode subsequently used normal Keychain authorization to copy the legacy
credential into the new service. The user handled the Keychain prompt and
confirmed live data, and Settings showed Connected to your EcoFlow. Legacy
credentials were retained. No credential bytes were exported or logged.

The user confirmed no Bluetooth prompts on two unchanged-build relaunches and
again after replacing build 23 with build 24 at the same path. Binary SHA-256
changed; codesign reports the identical certificate-root + bundle-identifier
designated requirement. Fresh advertisement monitoring was independently visible
in Settings. The user also confirmed the supplied artwork in the new identity's
notification banner. This verifies this Mac and this signing identity; it does
not isolate whether the namespace/cache change or signer change fixed artwork,
and does not establish behavior on other Macs.

build/kusanalee-verified-tests.log executed 121 tests, seven hardware checks
skipped, zero failures (114 passed). Synthetic native Keychain seams exercise
new-first lookup, successful legacy migration, denied/locked access, malformed
credentials, failed-save preservation, and both-namespace Forget. Two additional
Python preference migration tests passed. Final universal Release is recorded in
build/kusanalee-verified-release.log; signature verification with login-Keychain
access passes. Entitlements remain sandbox + Bluetooth. The local build helper
fails when its signing identity is missing rather than silently using ad-hoc.
Relaunching the app from Finder now opens Settings if no windows exist. The old
startup registration was not changed automatically; Launch at Login is off in
the new installation and can be re-enabled after checking the old app's entry.
Clock sync remains disabled.
A further quit/relaunch after migration returned to Connected to your EcoFlow
without re-entering the account ID, confirming remembered access in the new
namespace. Direct preference migration remains a guided fallback, not a claimed
successful container import.
The accessible sfltool startup-registration output contained no Somnoire entry;
the new installation's Launch at Login checkbox was off. No startup item was
registered or removed during this upgrade.
