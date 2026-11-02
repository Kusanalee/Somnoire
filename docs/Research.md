# Somnoire research

Consolidated protocol research, source provenance, experiments, and validation
records for the EcoFlow RAPID Pro 27,650 mAh (P512).

## Current status

As of the repository's 1.0.0 release record:

- Account-free battery percentage monitoring works from advertisements. Full
  readings and settings use the existing authorizing account ID for initial
  setup, then local Keychain access. No account-free full-access route has been
  established for the tested linked bank.
- Authenticated telemetry is decoded. The verified USB-C output mapping is
  C1 = 852, C2 = 856, C3 = 853, C4 = 854. Input-direction behavior and dock
  readings still have hardware-validation gaps.
- Battery Information values were compared with the official app. Healthy
  Charging and screen controls use reported settings and fresh readback. The
  80% charge cutoff was verified; other ceilings and discharge-reserve cutoffs
  remain unverified.
- Custom artwork transfer and automatic clock sync are unavailable. Use the
  official app for time setup, artwork, sharing, and firmware updates.
- Release validation recorded 114 passing tests, seven opt-in hardware checks
  skipped, and two passing Python migration checks. Live acceptance observations
  came from builds 23–24. The universal app is locally signed and not notarized.

For everyday use, see [installation](installation.md),
[first-time setup](first-time-setup.md), and [building](building.md).

## Reading the record

Personal namespaces, installation paths, observation dates, exact clock times,
and device-history readings have been omitted or generalized. Public protocol
identifiers, model names, software versions, and third-party citations remain
where needed to interpret the findings.

The sections below preserve the original technical findings, pinned references,
experiment boundaries and validation results. They are a historical
record, not a list of current product promises. Statements such as “unimplemented,”
“pending,” or “release remains 0.11.0” describe their original checkpoint; later
entries and the current-status summary take precedence. Test counts belong to
the named revision and are not cumulative. Private captures and ignored build
artifacts are not redistributed here.

The protocol record leads with payload details and continues through the 1.0.0
release. The phase records then follow development order, preserving detailed
observations that support those later conclusions.

## Contents

- [P512 protocol and implementation record](#p512-protocol)
- [Initial BLE research](#ble-research)
- [Phase 0 validation](#phase-0-validation)
- [Phase 1A: key exchange](#phase-1a)
- [Phase 1B: encrypted session and status](#phase-1b)
- [Phase 2A: advertisement battery snapshots](#phase-2a)
- [Phase 2B: continuous monitoring](#phase-2b)
- [Phase 2C: account-free telemetry research](#phase-2c)
- [Phase 2D: account-free access experiment](#phase-2d)
- [Phase 2E: authenticated telemetry and hardware checks](#phase-2e)

<a id="p512-protocol"></a>

## P512 protocol and implementation record

### Finding and confidence

The installed official EcoFlow Android app **6.17.4.14**, version code **11113**,
explicitly maps serial prefix **P512** to its **PB501** family. Its RapidStudio
interface decodes telemetry with the protobuf message `DisplayPropertyUpload`
and the nested message `UsbRealDisplayInfo`. This establishes an app-derived
payload schema for the P512 family; it does not establish live access in Somnoire.

The decoder and its tests in this repository are original Swift and public
synthetic data. No application bundle, generated vendor implementation, captured
packet, account value, device serial or credential is redistributed.

### Payload layout

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

### Original decoder

`P512TelemetryDecoder.decodePayload` returns a typed `P512TelemetryDelta`.
It supports the fields above, merges repeated embedded messages, keeps explicit
zeroes, preserves signs and skips unknown varint/fixed64/length-delimited/fixed32
fields. Invalid lengths, overflowing varints, wrong wire types for known fields,
nonfinite floats, out-of-range battery percentages and oversized payloads fail.

Delta merging retains unreported measurements. A future live session must track
receipt/freshness per measurement independently. Explicit diagnostic access probes
can decode allowlisted uploads; production wattage UI remains gated. Synthetic
decoding is not hardware validation.

### Remaining access question

The known `35/89` request is authentication status, not the port-power query.
Four earlier Somnoire sessions received only its reply, including under load;
see [Phase 2C](#phase-2c). Those replies did not prove an account requirement.

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
Measurement values and physical mapping still need comparison; see [Phase 2E](#phase-2e).

Still to establish on the actual bank:

- A second fresh decoded session and physical measurement/load comparisons.
- Whether the same uploads would begin without the fixed display request.
- The permitted account-free path, if one exists.
- Physical mapping of the four USB-C protocol fields and built-in cable.
- Agreement of signs, units and updates with each loaded/unloaded port.

### Static source evidence

Static inspection covered official application code and package version metadata.
No account storage, logs, session secrets, or credentials were read. Application
packages and extracted assets are not redistributed with this research.

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

### Validation

Six new hardware-free tests cover an independently constructed multi-port
float32 payload, nonsequential port tags, signs, missing versus zero values,
incremental/repeated-message merging, unknown fields, slices, truncation,
varint/length limits, wrong wire types and invalid scalar values.

Full suite: **59 passed**, five opt-in hardware checks skipped, zero failures. Live telemetry and physical port comparisons
remain unverified. The older capture may come from a different app version; the
schema provenance above is specifically the installed 6.17.4.14 build.

### Subsequent access experiment

[Phase 2D](#phase-2d) now documents a fixed one-shot display-report request and
typed status interpretation. It was tested twice without login or credential
changes; neither attempt returned telemetry. The shared authentication-status
summary selected checking an existing credential in normal mode. First-use local
provisioning remains a research design with no never-linked hardware validation.

Phase 2E later confirmed repeated authenticated decoded sessions, including field
852 at −22.9 W / 15.3 V / 1.5 A while charging from physical C1 (140W in/out),
as identified by the test operator. Unloaded port fields were absent rather than explicitly
zero. Other ports, the built-in cable, input direction and bank-screen comparison
remain unverified; the current results are in [Phase 2E](#phase-2e).

### Out-of-range SOC handling (0.5.9)

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

### Battery Information (0.7.0; source-derived, bank comparison pending)

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
preview displays the new measurements for operator-assisted comparison.

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

### Healthy Charging (0.8.0; write/readback hardware gate pending)

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

The 0.7.0 Battery Information health, cycle count, temperature, and energy
counters were confirmed against the official app. The log
shows field 102/263 updates about once per second; each is applied as received.
Temperature is labelled live only while connected with a sample under five
seconds old. Retained/stale values remain explicitly last-reported.

### Screen settings and artwork readiness (0.9.0)

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
operator-confirmed; physical charge cutoff is still not independently established.

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

### Artwork trace refinement (0.10.0; transport still disabled)

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

### 0.11.0 research checkpoint

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

### 0.12.0 investigation (not released)

The test operator confirms remembered access works across relaunch. The remaining account
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

Android observation feasibility: the official application was not debuggable
(run-as refused). The Bluetooth
snoop directory is inaccessible to shell; no legacy shared-storage snoop file was
present. A broad bugreport was not collected. The app's FileTransmitManager log
calls delegate through t0 to an eq/a logger; whether that release logger exposes
usable scoped plaintext evidence is not yet established. No artwork upload has
been requested or performed during this investigation. Release remains 0.11.0.

#### Operator-observed official-app Bluetooth restriction

The test operator reports that the official app does not support its artwork feature while
the bank is connected through Bluetooth. The planned official-app upload therefore
did not occur. The scoped observation recorded zero structural transfer events;
it was cancelled and the temporary debug.app.xlog.enable property restored to its
original unset value. This establishes an official-app Bluetooth-mode restriction,
not a verified firmware-level impossibility of BLE transfer. The generic native
A1/A2/A3 implementation is not sufficient evidence of P512 BLE artwork support.

For the current BLE-only product, custom artwork upload is deferred. Existing
verified screen settings remain in scope. No 0.12.0 artwork release or transfer
success is claimed; the working 0.11.0 release is retained.

### Clock sync and Bluetooth-only UI revision

Revalidated the official Android 6.17.4.14 application code.
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
 Universal Release
contains arm64/x86_64 and passes codesign --verify --deep --strict. Screen settings
were rendered and inspected in light/dark appearances at 560x570. Physical time,
resource transfer, and account-free hardware success remain unverified.

### Local-only scope revision (supersedes clock/artwork product claims above)

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

Hardware observation in this round: the bank clock matched the host clock. This verifies the observed display time, not which earlier
operation set it or reliable automatic sync. One opt-in diagnostic attempted to
establish a saved-bank session for 30 seconds and skipped because no live session
was established; it sent no clock request. No further attempt was made because
there was no new transport/readback evidence. Release sync remains disabled.

Final validation recorded 109 tests, seven opt-in
hardware checks skipped, zero failures (102 passed). Exact native UTC vectors,
removed-field refusal, missing readback, pane-independent clock ownership,
transport/cancellation distinctions, disabled-preference migration and numeric
setup validation pass. Separate validation recorded the
no-session skip and no clock write. Universal Debug/Release build, codesign
verification and arm64/x86_64 checks passed. Release entitlements are now only
App Sandbox and Bluetooth. Screen and bundled setup were rendered in both
appearances; regional authenticated browser retrieval was not exercised.

### Basic mode, shared percentage, native settings and local alerts

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
Validation recorded authorization=true and one delivered
notification; the test operator also confirmed receiving it. No paid signing, Developer ID,
notarization, push entitlement or network service was used. The temporary probe
entrypoint was removed. Alerts are opt-in, default 20% with 10/15/20/25/30 choices,
silent, with per-bank/threshold persisted episode latches. Fresh recovery to
threshold+5 rearms; stale data, duplicate samples and relaunch do not re-alert.
Permission is requested only on enable and checked before delivery. A test action
and permission status are included. No monitoring is promised during sleep/quit.

Validation: 113 tests, seven hardware checks skipped, zero failures
(106 passed). Added tests cover basic mode persistence/no live attempt, percentage
expiry/invalid data/zero, alert hysteresis and latch preference persistence.
Settings (all sections), basic dashboard and battery details were rendered and
inspected in light/dark. Validation recorded universal Release;
codesign verification and arm64/x86_64 checks passed, with only App Sandbox and
Bluetooth entitlements. Broader onboarding and GitHub Pages remain deferred.

Passive hardware acceptance was attempted using the explicit Continuous Monitoring
scheme. CoreBluetooth remained "Waiting for Bluetooth" with zero advertisements;
therefore the initial assertions could not be satisfied. This is not a verified
live percentage result. The opt-in test now skips if Bluetooth never becomes ready,
while retaining its assertions when hardware is available. No GATT or device-setting
writes were issued by this attempt. Native notification delivery was independently
verified as described above. Hardware-free final suite still reports 106 passed.

### Onboarding and identity polish

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
Two bounded diagnostic sessions ran. The first could not authenticate while using
basic-mode preferences; the second used isolated full-readings preferences and
reached Bluetooth ready but established no live session within 30 seconds.
Neither sent a clock request. The test operator cannot currently observe the bank's clock;
the earlier matching-time observation therefore cannot establish this revision's
clock behavior. No further attempts were made. Automatic writes/observers remain
disabled, including migration of older enabled preferences. Screen settings now
says to set time in the official EcoFlow app. Binding and resource data were not
changed.

Validation for this revision: the test run executed 118 tests,
seven opt-in hardware checks skipped, zero failures (111 passed). The suite
includes setup route/resume gates, coarse-age boundaries, thirteen-click unlock,
asset loading/template states and rendered setup/About panes, alongside existing
mode, authentication, readback and clock-vector coverage. Light/dark rendered
Welcome, full-access setup, About, settings and awake/sleepy template marks were
inspected. Validation recorded a universal x86_64/arm64 Release build;
codesign strict verification passed and entitlements remain sandbox + Bluetooth.
Dock policy and appearance switching are implemented; interactive window-lifecycle
acceptance on a running Release instance is not recorded by these render tests.

### Dashboard consolidation and fractional display

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

Validation: the test run executed 120 tests with seven
opt-in hardware checks skipped, zero failures (113 passed). Includes fractional
rounding, whole advertisements, invalid/nonfinite rejection, age/source retention,
alert conversion independence, and both color image representations. Rendered
General/About and color icons were inspected. Universal Release succeeded. Automated desktop access timed out twice,
so the final Release notification banner icon has not been visually confirmed;
The test operator was asked to test it through Alerts. No system-wide icon-cache reset or
notification authorization reset was performed. Clock sync remains disabled.

#### Notification icon follow-up

The test operator confirmed the refinement Release test still displayed a generic banner
icon. Launch Services inspection found multiple registered development copies.
NSWorkspace.urlForApplication resolved the shared identifier to an older
iconless Debug bundle; the running app was a different Xcode DerivedData Debug
copy. This establishes an application-resolution conflict, but does not prove
that it is the only cause of the Notification Center placeholder.

Incremented CFBundleVersion from 20 to 21, built universal Debug/Release, and
refreshed only the current Release registration with the public LSRegisterURL API.
The system now resolves the identifier to the current Debug bundle
(build 21, which includes the icon). NSWorkspace's resolved file-icon lookup was
rendered and inspected: it returns the supplied Somnoire artwork. Both builds
succeeded
and strict Release signature verification passed. No permission resets, bundle-ID
changes, global cache resets or old build deletion occurred. A fresh build-21
notification banner remains pending user verification; this is not yet a confirmed
notification-icon fix.

#### Compiled icon catalog candidate (build 22)

The test operator confirmed build 21 still showed the generic notification icon, despite
correcting application lookup. The registration conflict was therefore not a
sufficient explanation or fix. Build 22 replaces the manually copied ICNS resource
with Xcode's standard macOS app-icon asset catalog, compiled from the supplied
source at all standard/Retina icon sizes. actool now generates Assets.car,
AppIcon.icns, CFBundleIconName=AppIcon and CFBundleIconFile=AppIcon. The identifier,
permission flow and notification content are unchanged.

Validation recorded a successful universal Release build;
strict signature verification passed. The test run executed 120
tests, seven opt-in hardware checks skipped, zero failures (113 passed), including
new integration assertions for generated icon metadata and resources. Desktop UI
access succeeded for the build-21 Settings window, allowing a normal Quit; build
22 was then launched. NSRunningApplication confirms the running bundle is
the tested application bundle. UI automation cannot obtain
its menu-only state, so the test operator was asked to send a fresh test from build 22.
Notification-banner appearance remains unconfirmed, rather than claimed fixed.

#### Build 22 live result

The test operator confirmed build 22 also displays the generic notification icon.
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

### Stable application identity and signing

A persistent local code-signing identity was used for Debug and Release. Private
key material is not included in the repository. The application namespace and
Keychain service were migrated while preserving legacy access for rollback.
Container protection was respected; guided setup remained the fallback when
preference import was unavailable.

Hardware acceptance confirmed live telemetry, remembered access across relaunch,
Bluetooth permission retention across a changed build, and notification artwork.
These results apply to the tested installation and signing identity; they do
not establish the cause of the icon fix or guarantee behavior on other systems.

Validation recorded 121 tests, seven hardware checks skipped, zero failures
(114 passed), plus two passing Python migration tests. Tests cover Keychain
lookup, legacy migration, denied or locked access, malformed credentials,
failed-save preservation, and removal from both credential services. Universal
Release signing and sandbox/Bluetooth entitlements were checked. No startup
registration was changed automatically. Clock sync remained disabled.

### 1.0.0 release validation

Version 1.0.0, build 25 packages the previously verified app behavior under the
persistent local signing identity. Validation recorded 121
executed tests, seven opt-in hardware checks skipped, zero failures (114 passed).
Two Python preference-migration checks also pass. Universal Debug and Release
architectures are arm64/x86_64. Validation recorded the Release
build. The universal ZIP was extracted and verified with codesign --deep --strict;
version, build, identifier, compiled icon metadata and sandbox/Bluetooth-only
entitlements were checked. No private key material is included. The app remains
locally certificate-signed, without Developer ID or Apple notarization.
Live Bluetooth/notification/Keychain observations remain those of builds 23–24;
no new device writes or hardware claims were introduced by this release step.

<a id="ble-research"></a>

## Initial BLE research

These are observations about other software and products,
not a verified specification for the EcoFlow RAPID Pro 27,650mAh (300W).
This note records the Phase 0 research boundary. Phase 1A now implements only the
two captured session requests; see [the Phase 1A report](#phase-1a). Account
authentication and telemetry decoding are still unimplemented.

### Sources and licensing

Somnoire's implementation is original Swift under the repository's MIT license.
No reference source, cryptographic key material, generated protobuf, or packet
implementation is included. External license labels below describe the checked
repository snapshots, not a blanket license for all material they may reference.

| Reference snapshot | Checked license | Observations |
| --- | --- | --- |
| [chukfinley/re-ecoflow](https://github.com/chukfinley/re-ecoflow/tree/eb2feb4820e3d313d582d76ecd78f8b4a2dea931) | [MIT](https://github.com/chukfinley/re-ecoflow/blob/eb2feb4820e3d313d582d76ecd78f8b4a2dea931/LICENSE) | Android-app research; manufacturer-based detection; multiple protocol families. |
| [rabits/ef-ble-reverse](https://github.com/rabits/ef-ble-reverse/tree/9fdc35654c3c89f3382af6a2c81bf568734a678f) | [Apache-2.0](https://github.com/rabits/ef-ble-reverse/blob/9fdc35654c3c89f3382af6a2c81bf568734a678f/LICENSE) | Experiments on Smart Home Panel 2 and Delta Pro Ultra. |
| [rabits/ha-ef-ble](https://github.com/rabits/ha-ef-ble/tree/817620c38d04b55ee4b5d094269dfe0080355b6d) | [Apache-2.0](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/LICENSE) | Larger set of model-specific implementations and authentication variants. |
| [zettamax/efctl](https://github.com/zettamax/efctl/tree/8315bcde4238eda468619e6405eee04b565318a8) | [Apache-2.0](https://github.com/zettamax/efctl/blob/8315bcde4238eda468619e6405eee04b565318a8/LICENSE) | Terminal client with manufacturer-based discovery and an authenticated BLE library. |

### Discovery and GATT

[re-ecoflow discovery notes](https://github.com/chukfinley/re-ecoflow/blob/eb2feb4820e3d313d582d76ecd78f8b4a2dea931/docs/device-discovery.md)
report marker `0xA4A8` (bytes `A8 A4` in manufacturer data). The
[reverse-engineering script](https://github.com/rabits/ef-ble-reverse/blob/9fdc35654c3c89f3382af6a2c81bf568734a678f/connect.py)
and [HA device base](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/devicebase.py)
use `0xB5B5`. These are reported matching markers, not claims about SIG company
registration or universal device identity. Names and markers can collide or be
spoofed. Manufacturer data can include a serial number; do not publish it.

CoreBluetooth manufacturer `Data` includes its two-byte little-endian identifier.
Bleak's manufacturer dictionary separates that identifier from the remaining
bytes; do not reuse Bleak payload offsets against CoreBluetooth data.

[re-ecoflow BLE notes](https://github.com/chukfinley/re-ecoflow/blob/eb2feb4820e3d313d582d76ecd78f8b4a2dea931/docs/ble-protocol.md)
report this Bluetooth-base UUID family:

- Service `00000005-0000-1000-8000-00805F9B34FB`.
- Write characteristic `00000006-0000-1000-8000-00805F9B34FB`.
- Read/notify characteristic `00000007-0000-1000-8000-00805F9B34FB`.

The [HA connection implementation](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/connection.py)
and [efctl connection implementation](https://github.com/zettamax/efctl/blob/8315bcde4238eda468619e6405eee04b565318a8/efctl/eflib/connection.py)
instead select between:

- Write `00000002-0000-1000-8000-00805F9B34FB`, notify `00000003-0000-1000-8000-00805F9B34FB`.
- Nordic UART write `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`, notify `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`.

Nordic UART's service is `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` and is not specific
to EcoFlow. Somnoire scans without a UUID filter and enumerates every exposed
service. Reported service UUIDs contribute only a weak discovery hint. Actual
characteristic properties determine whether a manual Subscribe control appears.

### Authentication and packet formats — research only

The references describe `AA`-prefixed internal packets with version-dependent
length, routing, command and checksum fields. The reverse script describes an
outer `5A5A` envelope with frame type, length, optional AES-CBC payload and CRC16.
HA's packet implementation distinguishes V2/V3, sentinel-style V19 and a separate
V4 layout. These differences prevent treating one sample packet as universal.

HA and efctl include encryption-type-dependent sessions: plaintext, serial-derived
AES material, or ECDH followed by a session-key exchange. Their authentication
paths construct a digest from a user identifier and device serial. The Android
research also describes secure-auth and ODM variants. Phase 1A implements the initial ECDH/key-info exchange only. It does not extract
serials for authentication or contain key tables. A successful CoreBluetooth connection is not evidence that proprietary
authentication succeeded or that telemetry will flow.

The [HA RAPID Pro implementation](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/devices/rapid_pro_320.py)
labels itself a **320W GaN charger**, with a P521 prefix and model-specific auth
behavior. It does not establish support for this project's **27,650mAh 300W power
bank**. No associated command, control, model mapping, or authentication behavior
has been copied into Somnoire.

### Phase 1 evidence needed

Capture the actual power bank's advertisements, GATT tree, property flags,
connection behavior and unsolicited notification availability using Phase 0.
Review any raw data locally before sharing; opaque data may contain identifiers
or other sensitive information. Only then determine which protocol, if any,
applies. Account-free discovery does not promise account-free proprietary auth.

The current bounded session/status experiment and table provenance are documented
in [Phase 1B](#phase-1b); historical nonimplementation statements above describe
their original phase. No login or telemetry implementation has been added.

<a id="phase-0-validation"></a>

## Phase 0 validation

For current key-exchange and hardware results, see [Phase 1A](#phase-1a).
This record describes the earlier Phase 0 build and its validation limits.

### Passed

- Native macOS Debug and Release builds with Xcode and Swift.
- Both `arm64` and `x86_64` slices present in Debug and Release application binaries,
  verified using `lipo -archs`. Deployment target is macOS 13.0.
- 18 XCTest cases executed on the local Apple silicon Mac: **0 failures**.
- Test coverage includes malformed/CoreBluetooth advertisement conversion,
  manufacturer bounds and byte order, non-name hints, metadata merging, missing
  RSSI, repeated UUID identities, complete property flags, connection gating,
  cancellation/late events, log bounds, payload preview truncation, and export privacy.
- The manager starts idle and rejects unseen-device connections without creating
  a Bluetooth central. Tests do not scan, connect, pair, or request Bluetooth access.
- Release application packaged in the build output and ad-hoc signed with only
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

### Build artifacts

Build outputs and private validation logs are excluded from the repository.
See [building](building.md) for current build, signing, and test instructions.

### Not verified

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

### Menu-panel layout correction

The initial panel's ScrollView specified only a maximum height. MenuBarExtra's
intrinsic-size measurement collapsed that scroll area, hiding Scan and all body
controls. The panel now gives the scroll area an explicit 480-point height.
A native NSHostingView regression test checks the panel's measured width and
usable height. Bluetooth permission is still requested on Scan, not at launch.
The universal Release app in the build output was rebuilt and signed after
this correction. The live menu-bar panel and Bluetooth permission flow still
require interactive validation; native sizing tests do not establish those flows.

<a id="phase-1a"></a>

## Phase 1A: key exchange

For current behavior and results, see [Phase 1B](#phase-1b).

Somnoire 0.2.0 adds **Connect & Probe** for the observed RAPID Pro profile.
Ordinary **Connect** remains a GATT-only inspection operation.

### Verified behavior

the opt-in native hardware test completed
**two consecutive probes** on the test power bank. Each generated fresh keys,
validated the peer point, decrypted the 32-byte key-info ciphertext with valid
PKCS#7 padding and an 18-byte plaintext result, discarded it, and intentionally
disconnected. The selected test passed in 5.568 seconds total, including scanning
and both disconnects. CoreBluetooth `.withResponse` writes worked on this device.

Result text: **Key exchange verified — authentication not attempted.**
This does not establish authentication, a persistent session, telemetry decoding,
or whether a later authentication stage requires an account identifier.

### Evidence and protocol

The locally retained Android HCI capture contains 411 complete ACL packets and
507 valid CRC-checked outer frames. It shows service `0001`, write characteristic
`0002`, notify characteristic `0003`, a `secp160r1` point exchange, then command
`02` and encrypted protocol traffic. The `0005` service was discovered but unused.
The capture remains ignored under `build/`; no captured keys or raw fixtures are
included in source control.

The bounded native probe:

1. Requires manufacturer marker `B5B5`, advertisement layout marker `13`, ASCII
   model prefix `P512`, and candidate encryption type 7, with checked data lengths.
   These fields select an experimental profile; they do not authenticate identity.
2. Requires exactly one `0001` service with one writable `0002` and notifying `0003`.
3. Waits for the subscription callback, then sends an unencrypted `5A5A` command
   envelope containing `01 00` and a fresh 40-byte public point.
4. Requires a valid CRC and the observed `01 00 00` reply header plus a valid peer
   point. Computes a 20-byte ECDH secret, uses its first 16 bytes as the initial
   AES key and MD5 of the complete secret as IV, matching the reference procedure.
5. Sends command `02`. Requires a CRC-valid response with that command and exactly
   32 ciphertext bytes. Strictly validates AES-CBC/PKCS#7 decryption and plaintext
   length 18. No plaintext is returned to Swift or displayed.
6. Destroys sensitive owned buffers and disconnects, retaining only safe metadata.

No final session-key derivation, key table, authentication-status query, login,
identity guessing, telemetry query, settings command or firmware operation exists.
The reference for comparison is the commit-pinned
[HA connection implementation](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/connection.py).
The Swift framing/state-machine and C bridge are original Somnoire code.

### Native implementation and dependencies

Apple Security rejected a 160-bit ephemeral key while its P-256 control succeeded
in a local feasibility test. Somnoire therefore vendors micro-ecc at commit
`541b3a78026420a3e369c4c9281c396b5e531113`, under BSD-2-Clause. Only secp160r1 curve
support is compiled. Files are unmodified, with SHA-256 provenance in the vendor
directory. The binary bundles `ThirdPartyNotices.txt`; original Somnoire code
remains MIT licensed. No OpenSSL, Python, package download or subprocess is used
by the application at runtime.

The narrow C bridge uses `SecRandomCopyBytes`, the curve library, CommonCrypto
AES-CBC and protocol-required MD5, and `memset_s` for owned secret buffers.
It handles the curve's 21-byte private scalar, 40-byte public point and fixed-width
20-byte shared secret, including leading zeros. The pinned library rejects the
synthetic scalar-one multiplication edge case; this is covered as a fail-closed
case. Production key generation already retries rejected generated points within
the library, while the application never retries a hardware exchange.

Probe stages are separate from CoreBluetooth. Only the explicit probe write path
can call `writeValue`, and it uses `.withResponse` exclusively. A result is not
accepted until the corresponding write acknowledgement and reply have both
arrived, in either order. Stage deadlines are three seconds, with an eight-second
overall limit starting at connection establishment. Receive buffers are capped
at 4 KiB and individual frames at 1 KiB. Cancellation, malformed data, RNG failure,
Bluetooth loss and transport rejection stop the attempt without fallback.

Raw previews are suppressed for probe traffic. Diagnostics contain only fixed
stage/outcome labels, durations, lengths, UUIDs and sanitized error codes. No
private/public key bytes, shared secrets, decrypted key-info or serials are logged.
After disconnect, the last GATT snapshot is marked stale and controls are disabled.

### Tests

The default suite passes 31 hardware-free tests; the opt-in hardware test is
skipped by default. Coverage includes the original menu sizing regression and
Phase 0 tests, framing/CRC, every fragmentation boundary, coalescing, malformed
frames and limits, profile selection, early replies, stale callbacks, write and
subscription rejection, deadlines, cancellation, random-source failure, invalid
points and independently generated OpenSSL ECDH/AES vectors with leading-zero
shared-secret encoding and strict padding/length validation.

Reproduce synthetic vectors with `python3 scripts/generate_probe_vectors.py` on a
development machine with OpenSSL. All vector scalars and plaintext are deliberately
public synthetic data; this script never reads device captures or application keys.

Run normal tests with the **Somnoire** scheme. The explicit **Somnoire Hardware
Probe** scheme enables only `ProbeTests/testHardwareKeyExchangeTwice`, which scans
for exactly one eligible device and runs two probes. It never guesses between
multiple matching peripherals. Keep the bank awake and force-stop the official
app before running it.

Local results:

- Unit tests: 31 passed, hardware test skipped.
- Hardware: both probe attempts passed.
- Debug and Release compile for arm64 and x86_64 with deployment target macOS 13.

Intel runtime, macOS 13 runtime, and the new button's live menu-panel appearance
have not been directly checked. Native sizing tests pass. The next protocol phase
must investigate final session-key derivation and authentication independently.

<a id="phase-1b"></a>

## Phase 1B: encrypted session and status

Somnoire 0.3.0 provides two explicit **Connect & Probe** menu choices:
**Key exchange only** (the unchanged Phase 1A boundary) and **Session + status**.
Both intentionally disconnect. Ordinary **Connect** performs GATT inspection and
standard manual subscriptions only; it sends no proprietary values.

### Evidence and limits

The 0.2.0 diagnostic export records successful probes lasting 724 ms and
785 ms, each followed by a local disconnect request. Between them an ordinary
GATT-only connection lasted approximately 8.2 seconds before CBErrorDomain/7.
That code reports peripheral disconnection; it does not establish a firmware
authentication deadline or any particular account requirement.

The Android capture proves the initial exchange and subsequent encrypted outer
traffic. It does **not** disclose the Android ephemeral private key or prove the
plaintext of those later packets. This milestone treats the V3 status request as
a reference-derived experimental candidate, not a captured RAPID Pro command.

References pinned to ha-ef-ble commit
`817620c38d04b55ee4b5d094269dfe0080355b6d`:

- [Session derivation and status command](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/connection.py)
- [Inner packet format](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/packet.py)
- [Envelope format](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/encpacket.py)
- [CRC definitions](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/crc.py)

Somnoire intentionally requires strict padding, lengths, checksums, and matching
reply routing/command/sequence. It does not inherit the reference's permissive
padding fallback, broad auth-reply matching, retries, or automatic login.

### Protocol data provenance

The only new redistributed reference material is the published static lookup
table, decoded without changing bytes from `eflib/keydata.py`. It is 65,280 bytes,
SHA-256 `3d1ba59b40c46bc86ba35fa231a3db196b448bbdfb1635c88ddd42f24abd4b2a`.
The pinned repository publishes Apache-2.0, with no file-specific license override
in that file and no NOTICE file in its tree. File history identifies its introduction
at `e12089de239c6a2b827d61b703b158c7586b6758` and later representation change at
`51a26b291e7da29f3f72b93beb31b6109daac051`. This records the upstream publication
and license basis; it does not claim that Somnoire independently created the table.

The source commit/blob, transformation, length, hash and history are retained in
`Vendor/EcoFlowProtocol/PROVENANCE.json`. The upstream license is retained there
and reproduced with attribution in the application's `ThirdPartyNotices.txt`.
Somnoire's original Swift/C code remains MIT; micro-ecc remains BSD-2-Clause.
No upstream Python implementation, device capture, account credential, or
device-specific key is bundled. There are no runtime downloads or OpenSSL calls.

### Native behavior

After the existing fresh point exchange and command 02, the C context validates
the table hash and decrypts the key-info internally. For seed bytes a/b it selects
16 bytes at `a * 16 + ((b - 1) & 255) * 256`, rejecting out-of-range offsets.
The session key is MD5(table selection followed by the 16 random bytes); the IV
remains MD5 of the complete initial shared secret. Intermediates are erased.

The single V3 request is `src=21, dst=35, dsrc=01, ddst=01, cmdSet=35, cmdID=89`,
empty payload and zero sequence. Header CRC8 uses polynomial 07, initial zero,
non-reflected; packet/envelope CRC16 uses ARC. AES-CBC/PKCS#7 encrypts the inner
packet, wrapped with `5A5A 10 01`. There is no version, address, or transport fallback.

The reply must decrypt strictly, have the exact V3 inner length and valid checksums,
reverse the routing, and match device routing, command and zero sequence. Valid
unrelated V3 packets are discarded without payload inspection, acknowledgement,
or resetting deadlines. Malformed packets fail the attempt. No plaintext enters
Swift; C returns only malformed/unrelated/matching classification.

The eight-second overall and three-second stage deadlines remain. The manager
forwards subscription/write/receive events without exposing CoreBluetooth to the
probe engine. Matching replies and write completion must both arrive, in either
order. Every terminal path erases owned crypto state and disconnects. Probe traffic
has no raw preview. Historical results are labeled separately from current notices;
a new attempt clears the old error banner while retaining diagnostic history.

Success text is **Encrypted session verified — status reply received; login not
attempted.** A status reply is not proof of authenticated access. Status payload
values are not interpreted. No login, account ID, telemetry query/decoder, device
control, heartbeat, retry, or reconnect is implemented.

### Validation

both explicitly requested native hardware attempts passed on
the nearby eligible RAPID Pro. They received strictly validated matching encrypted
status replies in **0.851 s** and **0.792 s** from connection establishment, then
intentionally disconnected. The selected XCTest passed in 11.024 s total including
scanning and teardown, with zero failures/skips.
This verifies the candidate query and final session derivation on this device.
It does not verify login, status-payload semantics, persistent access, or an
account-identifier requirement.

The default suite is hardware-free; the **Somnoire Session Status Probe** scheme
explicitly enables two hardware attempts, each with fresh keys and cleanup. The
original **Somnoire Hardware Probe** scheme remains key-exchange-only.

Synthetic tests use independent OpenSSL ECDH/AES vectors and Python packet/checksum
construction. They check all 65,536 seed combinations, altered/truncated tables,
out-of-range seeds, strict padding/length validation, exact request encryption,
wrong routing/command/sequence, invalid packet checksums, unsupported inner version,
unrelated replies, fragmented/coalesced frames, early replies, rejected writes,
cancellation/deadline cleanup, diagnostics, and the existing native panel-size test.
No captures or device secrets are test fixtures.

- Final default suite: **36 passed**, one opt-in hardware test skipped, zero failures.
- Debug and Release compile for **arm64 and x86_64**, deployment target **macOS 13**.
- Release excludes DEBUG crypto hooks and OpenSSL linkage; its protocol resource
  and notices are checked against source. Release signing disables Xcode's injected
  debugger entitlement, retaining only App Sandbox and Bluetooth access.
- The native panel sizing regression passes. Direct inspection of the new menu
  choices, Intel runtime, and macOS 13 runtime remain unperformed; compilation and
  hosting-view tests do not establish those checks.

The local runnable artifact is the built application (0.3.0). Ordinary test execution
does not enable hardware probing. Raw Android captures remain ignored outside version control.

<a id="phase-2a"></a>

## Phase 2A: advertisement battery snapshots

Somnoire 0.4.0 adds a bounded candidate decoder and hardware-gated battery UI.
Scanning remains manual, unfiltered, duplicate-suppressed and limited to 30 seconds.
Battery sampling makes no connection, subscription, cryptographic exchange or
proprietary write. Existing Connect and both explicit probes retain their behavior.

### Evidence and gate

The [reference parser](https://github.com/npike/ha-ecoflow-ble/blob/0726ed4b20abfdb1b5da38df06f79fe66d6dbfe3/custom_components/ecoflow-ble/ecoflow_ble/protocol.py)
uses byte 17 of Bleak's manufacturer payload as percentage. CoreBluetooth retains
the two manufacturer-ID bytes, making the candidate byte offset **19** here.
The reference covers other EcoFlow products; it does not establish P512 support.
Somnoire's original decoder copies no reference implementation or generated data.

Earlier local RAPID Pro advertisements contained `0x64` at that position, and the
user reported **100%** on the power bank's own screen. This single full-charge
agreement does not prove that the field changes with battery state. A physical
comparison at a lower level is required before enabling the numeric label.

The production gate is `AdvertisedBatteryReading.hardwareValidated`, now **true**
after the physical comparisons below. While false the device row shows **Battery unavailable** and **Advertised
battery support awaiting hardware validation.** The candidate stays internal;
there is no setting that bypasses the evidence gate. If the lower-level comparison
fails or cannot be completed, the gate stays false and no battery support is claimed.

Only the observed complete profile is accepted: manufacturer `0xB5B5`, marker
`0x13`, P512 prefix, checked ASCII serial field, candidate encryption type 7, at
least 25 manufacturer bytes. The decoder accepts whole-byte values 0–100. It
does not mask flags, clamp values, infer zero from missing data, or extrapolate
other model layouts. The shared profile predicate preserves the probe's guards.

### Snapshot behavior and privacy

`AdvertisedBatteryReading` contains a percentage and local observation time.
`DiscoveredDevice.updateAdvertisement` merges metadata and updates the candidate
only from a newly received manufacturer payload. Name/RSSI-only callbacks retain
the prior sample and timestamp. A received invalid manufacturer value clears it,
including a malformed CoreBluetooth value of the wrong type. A new scan clears
the old device list as before, preventing reuse of a previous scan's sample.

After the hardware gate is satisfied, a valid reading is labeled **Battery 100% ·
advertised**, **Scan snapshot**, its observation age, and **Scan to refresh**. An
unavailable reading is explicit. Snapshot age uses native SwiftUI relative-time
text, not a new polling or scan timer. There is no background monitoring.

Diagnostics record fixed outcomes (candidate decoded, invalid value, unsupported
profile) and the advertisement source only. Percentage, observation time, raw
advertisements and identifiers are excluded from clipboard exports. The internal
candidate is not serialized, persisted or sent to the OS logger. The opt-in local
hardware XCTest prints only the candidate integer, without identities or raw data;
its results remain under ignored build/ and are separate from clipboard exports.

### Future encrypted telemetry evidence

Read-only inspection of official Android app **6.17.4.14**, version code
11113, found `assets/bundle/PowerBank.bundle`.
Its shared power-bank decoder describes integer `soc` at payload offset 11 and
little-endian Float32 `socF` at offset 12; its UI data handler accepts command set
`0x0C`, ID `0x01`. The bundle maps the broader P51 serial family to PB501. This
is a candidate shared layout, not P512-specific hardware proof. No app bundle,
source excerpt, encrypted telemetry request or decoder is included in Somnoire.
The APK was inspected as installed code, without accessing account data, launching
the app, or changing phone settings.

### Validation

Hardware-free tests cover every truncated manufacturer length, supported-profile
selection, all 256 candidate values, Data slice indexing, manufacturer byte order,
merging, valid refresh, malformed invalidation, timestamps, UI gating, export
privacy and the existing native panel-size regression. Existing crypto/probe and
Phase 0 tests remain in the default suite.

The **Somnoire Advertisement Battery Check** scheme explicitly enables a passive
hardware test. It scans for exactly one matching device, samples the candidate,
stops, and asserts that no connection, probe or subscription was initiated. Set
`SOMNOIRE_BATTERY_EXPECTED_PERCENT` in that scheme's test environment to compare
against a contemporaneous reading from the physical screen. Normal tests skip it.

Intel
and macOS 13 runtime checks remain separate from cross-compilation; native panel
sizing tests do not replace direct inspection of the new battery row.

#### Physical comparisons

- Full charge: the earlier local manufacturer payload contained `0x64` at index 19
  and the test operator confirmed **100%** on the physical display.
- Lower charge: the passive native hardware sample read **96**. The test operator then
  confirmed **96% now** on the physical display. The preceding 99% report was older;
  it was not used as a mismatched simultaneous comparison or silently treated as
  a passing result.
- The passive test passed in 0.111 seconds with no connection/probe/subscription
  events. Two earlier scans returned zero
  peripherals while an older Xcode-run Somnoire instance was present; discovery
  resumed after that instance was closed. Those unsuccessful scans are retained
  as environmental observations, not protocol-validation passes.

The numeric label is enabled for the restricted observed P512/type-7 profile.
This establishes the initial practical mapping on this bank, not every firmware,
flag combination or other EcoFlow model. The full byte remains range-checked;
unsupported status-bit combinations continue to produce Battery unavailable.

#### Build and regression results

- Final default suite: **42 hardware-free tests passed**, two opt-in hardware tests
  skipped, zero failures. This includes native
  panel sizing and both prior probe modes' synthetic regressions.
- Debug and Release compile for **arm64 and x86_64**, deployment target macOS 13.
- The Release bundle in the build output is version **0.4.0**, locally ad-hoc
  signed and verified. Entitlements remain only App Sandbox and Bluetooth access;
  `LSUIElement` remains true. Dependency resources/notices match source; no DEBUG
  crypto test hooks or OpenSSL libraries enter Release.
- Direct inspection of the new battery row, Intel runtime, and macOS 13 runtime
  remain unperformed. The native hosting-view panel-size regression passed.

One older Somnoire instance was closed for hardware sampling. Run a single instance
and use **Scan** to obtain a new battery snapshot; simply opening the panel does
not scan or reconnect.

<a id="phase-2b"></a>

## Phase 2B: continuous monitoring

Somnoire 0.5.0 monitors the verified P512/type-7 battery advertisements continuously
after the user enables **Monitor Battery**. This is automatic discovery/monitoring,
not a persistent GATT connection. There is no automatic connection, subscription,
probe, login, telemetry request, device control, or reconnect loop.

### Everyday behavior

The native menu shows the selected bank, battery and monitoring status. The menu
bar uses Somnoire's template symbol plus a fresh percentage, or a dash when no
fresh percentage is available. Accessibility identifies it as power-bank data.
Paused, stale, sleeping, Bluetooth-unavailable and diagnostic states do not claim
to be connected or freshly monitored. A retained reading is labeled last reported.

On first use, turn on **Monitor Battery**. Later launches restore the preference;
launch at login is not installed. The app remembers only that preference and the
selected CoreBluetooth peripheral UUID in local UserDefaults. There is no saved
serial, account information, diagnostic history or raw advertisement data.

With no remembered device, association collects eligible candidates for three
seconds and chooses only a sole candidate. Multiple candidates require explicit
selection. A remembered target is never silently replaced by another nearby bank.
**Choose Power Bank…** opens the diagnostics utility with eligible choices;
**Forget Power Bank** clears the stored binding. Candidate storage is bounded to
eight devices, with expiry of unselected candidates. Ordinary monitoring ignores
unrelated peripherals before creating full advertisement snapshots or publishing UI.

Monitoring uses one service-unfiltered CoreBluetooth scan because the observed bank
does not advertise a useful service filter. Duplicate callbacks are enabled for
repeated samples. This intentionally uses more radio activity than a one-shot scan;
users can pause it. It continues with the menu closed, suspends during sleep or
Bluetooth loss, and resumes only if enabled. This is not a promise that the OS will
deliver every advertisement.

Battery freshness uses monotonic time and expires after 30 seconds without a valid
manufacturer payload. Name/RSSI-only callbacks cannot refresh it. Invalid payloads
invalidate the sample. Presentation is coalesced to at most once per second; there
is a single pending publication and an earliest maintenance deadline, rather than
a timer per packet. Native UI text uses wall-clock time only for display.

### Diagnostics and lifecycle

The menu's **Diagnostics…** action opens one resizable, non-restoring native window
with SwiftUI content. Opening it alone does not scan, connect or probe. Explicit
diagnostic discovery retains the original 30-second limit and duplicate filtering.
Explicit GATT inspection and the two probe choices retain their transport boundaries.
They suspend ordinary monitoring, which resumes after cleanup when enabled.

Closing the utility cancels active inspection/probing and resumes monitoring when
enabled. Scan transitions retain the last GATT value snapshot as stale; live
CoreBluetooth service/characteristic objects and subscriptions are discarded on
teardown. Previous probe results and operation errors stay in diagnostics, separate
from the menu's monitoring status.

The application delegate owns the shared manager from launch and stops tasks and
Bluetooth work at termination. Saved preferences cannot activate Bluetooth merely
by constructing a manager; normal XCTest hosts suppress app-level auto-restoration.
Reopening reuses the running application. A duplicate executable launch yields to
the earliest running instance, with a deterministic process-ID tie break.

The supplied 0.4.0 export contained 36 identical battery decoding events over about
five seconds. The new outcome tracker emits only category transitions. Packet
receipt and coalescing totals are aggregated, not appended per packet. Export still
excludes names, UUID identities, percentages, observation times, raw advertisements,
packets, keys and unsanitized errors. The 1,000-event in-memory limit remains.

### Native design basis

Apple HIG references:

- [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
  — native menu for simple extras, template symbols and familiar behavior.
- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
  — important actions first, concise labels, logical groups and sparing icons;
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
  — system components adopt platform appearance; no custom glass layers are added.
- [Duplicate advertisement option](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerscanoptionallowduplicateskey)
  — continuous samples require disabling duplicate filtering, with a power tradeoff.

The app retains macOS 13 support, a hidden Dock icon and system typography/colors.
The utility is a technical-tools window, not the future standalone monitoring UI.

### Validation

The final default suite passed **51 hardware-free tests**, with four opt-in
hardware tests skipped. Tests cover association,
ambiguity, remembered-target behavior, expiry, invalidation, pause/Bluetooth/sleep
presentation, candidate bounds, burst coalescing, diagnostic deduplication,
preferences, test-host restoration, window lifecycle and light/dark intrinsic size.
Existing Phase 0, advertisement decoding and cryptographic tests remain.

The **Somnoire Continuous Monitoring Check** hardware test passed in **45.296 s**. It accepted **38 advertisements**, retained a
fresh reading after more than 30 seconds with no menu open, and refreshed after
pause/resume. It observed no GATT connection, subscription or probe activity.

The separate **Somnoire Diagnostic Lifecycle Check** makes one explicitly requested
read-only GATT connection to test suspension, close/teardown, retained stale services
and monitoring resumption. It sends no proprietary packets or subscriptions.
It passed in **7.929 s**, confirming
monitoring resumed after closure and the nonempty GATT snapshot remained stale.

Debug and Release compile for **arm64 and x86_64** with deployment target macOS 13.
The packaged **0.5.0** Release in the build output is locally ad-hoc signed and
verified, with only App Sandbox/Bluetooth entitlements. Its protocol resource and
third-party notices match source; DEBUG crypto hooks and OpenSSL linkage are absent.
An explicit duplicate launch left the original Release process as the sole instance.

Native light/dark hosting-view sizing checks passed. Direct live visual, keyboard,
and accessibility inspection remains unperformed: the computer-use service returned
`-10005: timeoutReached` when selecting the running Release app. Process/signature
checks do not replace that UI review. The diagnostics utility is created only by
its explicit action, not restored or shown at launch.

Actual system sleep/wake, physically removing/returning the bank, permission changes,
Intel runtime and macOS 13 runtime remain manual checks. A changing percentage during
continuous operation is not claimed solely from repeated receipt of an unchanged
value; Phase 2A independently validated the mapping at 100% and 96%.

<a id="phase-2c"></a>

## Phase 2C: account-free telemetry research

This milestone adds a bounded **Connect & Probe → Account-free telemetry check**.
It is the verification gate for live per-port power, not a wattage feature.
The existing advertisement-based battery monitor and two original probes remain.

### What the experiment does

For the already observed RAPID Pro P512/type-7 advertisement profile, the probe
uses the verified `0001` service, writable `0002` and notifying `0003` characteristics.
It performs the existing fresh ECDH/key-info/session derivation and sends the same
empty V3 `35/89` status request. Matching routing, sequence, checksums and strict
AES-CBC/PKCS#7 decryption are required. It then observes notifications for up to
eight seconds and intentionally disconnects. Setup stages retain three-second
limits; the entire connected experiment is limited to sixteen seconds.

There are exactly three application writes: public-key exchange, key-info request,
and encrypted status request. No login, account identifier, serial-derived login
token, guessed telemetry query, heartbeat, acknowledgement of unsolicited packets,
settings change, reconnect loop or device-control command is added.

The C bridge exposes only validated V3 header metadata: routing, command,
sequence and payload length. It never returns decrypted payloads or session keys.
Diagnostics omit sequence values and retain at most 32 distinct header summaries
per probe, plus a count of non-status packets. Observations are limited to 1,000
non-status packets. The existing frame/buffer limits and terminal cleanup apply.
Raw probe traffic has no preview. Observed packet bodies, device names, serials,
peripheral IDs, credentials and keys are not exported or added to test fixtures.

A completed observation does **not** mean telemetry access succeeded. Likewise,
zero notifications or a disconnect does not establish an account requirement.
Physical port mapping, wattage scaling, direction, request/subscription behavior,
and access requirements must be verified before adding production power rows.

### Retained capture and reference findings

The private capture is in BTSnoop H4 format. A local metadata-only
inspection found 507 CRC-valid outer envelopes over an approximately 158-second
ACL capture span: **503 encrypted envelopes and four unencrypted exchange envelopes**. The encrypted
packet bodies cannot be interpreted from that capture alone: the phone's ephemeral
private key is not present. No device payloads were copied into source control.

The [pinned HA connection implementation](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/connection.py)
uses `35/89` as an authentication-status/wake-up request and follows it with a
separate `35/86` login derived from a user identifier and device serial. This is
reference behavior, not proof that this bank requires an account.

The [pinned RAPID Pro implementation](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/custom_components/ef_ble/eflib/devices/rapid_pro_320.py)
is for the **P521 320W charger**, not the **P512 300W power bank**. Its protobuf
port fields, output sign convention, authentication identifier, and settings
commands are not treated as verified behavior for this bank. Reference files and
the local capture-summary script remain ignored development artifacts.

### Running the check

Keep the bank awake and near the Mac, and close the official EcoFlow app. In
Diagnostics, discover devices and choose **Connect & Probe → Account-free
telemetry check**. The retained result shows the number of other validated
packets; **Copy Diagnostics** includes only their sanitized header summaries.

The opt-in **Somnoire Telemetry Access Check** Xcode scheme runs two consecutive
attempts, refuses ambiguous hardware selection and confirms connection teardown.
It uses isolated test preferences. Ordinary tests neither enable the hardware
check nor restore monitoring. A completed observation or peer disconnect during
the observation window is a valid experimental outcome, not a telemetry success.
Failure before that window fails the hardware check.

### Validation and remaining gate

four fresh sessions reached the observation
window on the nearby bank. Two attempts were repeated while the test operator confirmed
that the bank was actively charging a device. All four returned a strictly validated
V3 status reply with a two-byte payload and header `35/01 → 21/01`, command
`35/89`. **None returned another validated packet.** Two windows completed; two
ended with a peripheral disconnect during observation. All released the connection.

The two opt-in hardware test runs passed **as bounded experiments**:
These are not port-power acceptance
tests. Earlier discovery attempts received no advertisements; discovery recovered
after closing the regular Somnoire instance. Run one instance at a time.

The final default suite passed
**53 hardware-free tests**, with five hardware checks skipped and zero failures. It includes observation timing, fragmentation, header
deduplication, write/reply ordering, cancellation, disconnect/invalid-packet cleanup,
and generic metadata validation against independent synthetic encrypted vectors.
The original key-exchange and session/status regression tests remain included.
An initial test-helper exclusivity conflict was fixed before the passing run.

Debug and Release compile for arm64 and x86_64. The Release binary's universal
architectures and local signature were verified; its entitlements remain App
Sandbox and Bluetooth only. Automated native UI inspection failed with Computer
Use timeout `-10005`; live appearance is unverified. Existing native sizing tests
pass, which does not establish visual verification or Intel/macOS 13 runtime.

**Gate not passed:** account-free port telemetry is still unverified. This does
not prove that account credentials are required; an additional model-specific
read/subscription request may be needed. The retained encrypted capture and the
P521 charger implementation do not establish that request for P512. Do not guess
it or reuse another model's controls or login identifier.

Live per-port readings, production telemetry state, AppKit menu lifecycle changes,
wattage/direction/physical-port mapping, and comparisons across ports remain
unimplemented behind this gate. The next prerequisite is a verified P512 read-only
telemetry request/schema and access behavior. If that establishes an account
requirement, account integration remains outside the agreed milestone.

### Subsequent schema research

The installed official app now establishes an [app-derived P512 payload schema](#p512-protocol).
The original Swift decoder is tested on synthetic payloads. This resolves the
payload-schema research prerequisite at app-source confidence; the BLE request,
access behavior and hardware comparison gate remain open.

<a id="phase-2d"></a>

## Phase 2D: account-free access experiment

### Result

Somnoire 0.5.2 adds **Connect & Probe → Account-free access check**. It reads a
validated authentication-status summary, then requests one display report using a
fixed app-derived payload. It does not log in, provision credentials, change
ownership, unbind, reset, change report periods, or alter charging/port settings.

two independent fresh sessions on the
loaded P512 returned **app would check an existing credential · normal mode**.
Both sent the one-shot report request and received its GATT write acknowledgement.
Neither received a matching application reply or a display upload. The bank
initiated disconnection after approximately **9.70 s** and **9.48 s** from connection.
The test verified that battery scanning resumed after each attempt.

The dedicated hardware test passed **as an experiment**, not as account-free
telemetry acceptance. Both attempts decoded
zero telemetry packets and zero port-power updates. No physical port comparison
was therefore possible. Two independent decoded streams plus a confirmed load
change remain required before claiming a working path.

**Precise remaining blocker:** the tested pre-authentication display-report action
produced no response in this bank's existing credential state. The app would next
check its existing credential; that step was deliberately not attempted. This is
not proof that every firmware/read path needs an EcoFlow account, nor a result
for a never-linked bank.

### Source trace and operation classification

Evidence comes from static inspection of the official EcoFlow app
6.17.4.14/11113. The static source and P512-to-PB501 mapping are recorded in
[P512 Protocol](#p512-protocol). No app storage, account values or logs were read.

| Operation | Wire form / evidence | Classification and implementation |
| --- | --- | --- |
| Authentication status | `21→35`, `35/89`, empty V3 payload; existing hardware-verified exchange | Read-only; implemented |
| One full display report | `21→02`, `FE/11`, sequence 1, body `B8 04 01` | App-derived one-shot reporting action; implemented as the sole new candidate |
| Check an existing credential | `35/86`; `BleAuthCommand.checkAuthentication` | Credential check; no constructor or send API implemented |
| Set authentication permissions | `35/85`; `BleAuthCommand.setAuthentication` | Credential provisioning; excluded from current-bank experiments |
| Unbind | `35/84` in app command definitions | Excluded |
| Reset, port settings, charging limits, report periods | Other fields/actions in shared configuration messages | Excluded |

The P512 interface's `RapidStudio` module suffix **35000681** exports the
`active_display_property_full_upload` operation. Its command helper encodes a
`ConfigWrite` containing only the caller's requested field, using the model's
command configuration **src=33, dst=2, cmdSet=254, cmdId=17** (module **35000009**,
re-exported through **35000008**). Module **35000683** encodes the action as protobuf
**field 71**, bool, key 568: the complete body is exactly `B8 04 01`.

Although carried in a configuration-message container, this candidate contains
only the full-display-report action. It omits every `cfg_*`, period, credential,
port-control and reset field. The fixed C API accepts no command/payload arguments,
so a caller cannot use it to substitute those fields. Firmware acceptance and
reporting behavior were experimental; no broader configuration API was added.

The app's `DefaultEcoPacketMatcher.isMatchDefault` uses the request's
`resultCmdId`; `EcoPacket` defaults that to its own command ID. The probe therefore
recognizes a `02→21`, `FE/11`, sequence-1, `1/1` device-route reply. A reply is
reported as received, not automatically accepted; its body is never exposed.

### Authentication summary

The app's `EFBleAuthNoDialogHelper$checkAuthStatus$1` examines the status payload:

- First byte 0 selects setting a credential; first byte 1 selects checking an
  existing credential. Other values remain unknown in Somnoire.
- Second byte 0 selects normal mode; byte 1 selects the OMOS branch. Other values
  remain unknown. Missing or extra bytes yield an unknown summary.
- These are app-derived next actions, not statements about cloud ownership or
  successful session authorization. Somnoire stops before requesting a report
  when the action is unknown or the mode is not normal.

`BleAuthNormalHelper.bleAuth` separates `checkAuthentication` from
`setAuthentication`. The local bank was never passed to either. The legacy scan
parser also has separate advertised support/configuration hints and encryption
bits; encryption type 7 alone does not establish an account requirement. The
new experiment uses the validated status reply rather than those advertising hints.

An initial hardware run exposed an incorrect extra requirement that the reply's
control byte equal the request's `0D`. It stopped before issuing any report.
That assumption was removed; the existing V3 padding, length, header CRC, packet
CRC and reply-routing checks remain. Independent synthetic vectors now exercise
a response with a different control byte. No permissive padding/version fallback
was introduced.

### Probe and crypto boundaries

The three existing probes keep their earlier request sequences and deadlines.
The new probe sends exactly four application writes on a supported status:
fresh public key, key-info request, status request, and the fixed display request.
There is one candidate per connection and no retry/reconnect/heartbeat loop.
Connection timeout remains 20 seconds, setup stages have three-second limits and
a 16-second connected setup cap; observation lasts at most 30 seconds, with a
46-second connected overall cap. Peer disconnection ends the attempt immediately.

The crypto bridge returns typed status or header metadata. It releases a body
only for strictly validated V3 `02→21`, `FE/15` display uploads with device routing
`0/0` or `1/1`. That route is an app-derived candidate, not hardware-verified here.
Unknown routing/version/commands cannot reach `P512TelemetryDecoder`.

Decoded telemetry arriving before the request's write acknowledgement is bounded
and held privately. It is published only after that acknowledgement. A status or
application reply alone cannot produce a telemetry-success outcome. Latest deltas
are volatile experimental results; production power rows and freshness integration
remain gated. Exported diagnostics include only typed status, headers and counts.

### Never-linked onboarding research

A **possible**, still unverified account-free onboarding design is:

1. On a never-linked bank that reports the app's set-credential state, create a
   cryptographically random local identifier. The inspected app path formats a
   numeric user identifier with the destination serial before an MD5-based token;
   a random positive 63-bit decimal identifier is a plausible local substitute.
2. Derive the device's exact expected ASCII token and use its local provisioning
   operation, without cloud registration. Hexadecimal casing and the P512-selected
   auth path must be resolved/verified before any implementation or hardware write;
   the app contains more than one authentication helper/formatting path.
3. Store the local identity/credential only in macOS Keychain, scoped to this bank.
   No actual identity, token, serial or provisioning packet was generated or saved
   by this milestone; this is an onboarding design, not an enabled feature.
4. Establish credential replacement/reset and recovery behavior before shipping.
   Losing Keychain data may prevent reconnection. Official-app use after local
   provisioning may require replacing authentication state; compatibility is unknown.
   Never silently reset or replace credentials to recover access.

This suggests a device-local pairing opportunity rather than proof of a workable
onboarding flow. Only the current bank is available. Synthetic tests exercise its
set-credential status and verify that the current-bank probe still sends only the
same report request, never a provisioning command. No never-linked hardware was
provisioned or tested, and the current bank must not be reset to manufacture one.

### Validation and remaining work

Hardware-free coverage includes native encrypted request bytes and payload
allowlisting, unknown/unsupported status, unrelated authentication replies,
status-only outcomes, fragmented/coalesced frames, early replies, pending writes,
malformed telemetry, deadlines, cancellation, disconnect and late-event cleanup,
partial protobuf updates and diagnostics privacy. Public synthetic fixtures contain
no device/account material. Current-bank APIs cannot construct credential, unbind,
reset or arbitrary settings writes.

**Final hardware-free suite:** 67 passed, six opt-in hardware checks skipped, zero
failures. Debug and Release compile for
arm64 and x86_64; both universal binaries and the Release signature were verified.
Release retains App Sandbox/Bluetooth-only entitlements. Intel/macOS 13 runtime
and live UI appearance remain unverified; native sizing tests are not visual QA.
The next supported step requires either another evidence-backed anonymous read
path or dedicated never-linked hardware to validate a fully local onboarding flow.
The existing bank's credentials will remain unchanged.

<a id="phase-2e"></a>

## Phase 2E: authenticated telemetry and hardware checks

### Operation and source evidence

This explicit experiment checks the current bank's existing credential. It cannot
set a credential, replace pairing, unbind, reset, change charging settings, or
configure reporting periods. Normal monitoring remains advertisement-only.

The retained official Android app 6.17.4.14/11113 is the static source (source details are in [P512 Protocol](#p512-protocol)). In `classes9.dex`:

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

### Identity setup and privacy

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

### Bounds and validation

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

the 0.5.4 hardware-free run passed **77 tests**,
with six unrelated opt-in hardware checks skipped and no failures. Debug and Release compile for arm64 and
x86_64. The universal Release signature validates; entitlements remain App Sandbox
and Bluetooth only. Intel/macOS 13 runtime and native visual QA remain unverified.

Native accessibility repeatedly returned timeout `-10005`, including after the
user opened Diagnostics. An official-site profile response supplied a numeric ID
without saving it or printing it in research logs. The first manual attempt could
not start because the authenticated menu item was disabled. The revised UI gives
explicit readiness feedback and delegates validation to the manager before any
connection. A subsequent operator-supplied report contained an ordinary GATT inspection
and peer disconnect, without probe stages or authentication writes. That run is
not an authentication failure. To make the next action unambiguous, authentication
now has a dedicated row button and an immediate typed **Probe requested** event.
Account identifiers were handled as strings to preserve exact input; no identifier
or generated token was printed or saved in research artifacts.

### Operator-assisted current-bank authentication result

A subsequent operator-supplied diagnostic report establishes a successful existing-
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
The next operator-assisted attempt again accepted the credential, then identified
**V19 (`0x13`)** after successful AES/PKCS#7 and header CRC8 validation. It ended
after approximately 1.19 seconds with no decoded telemetry; passive scanning
resumed. This supplies the actual-bank evidence for extending the access parser.

Expanded independent fixtures exposed the platform decryptor's tolerance for a
zero padding count. All three decrypt paths now validate PKCS#7 explicitly after
un-padded CBC decryption: padding must be 1–16 equal bytes. Valid-prefix zero and
inconsistent padding fail before header or body interpretation. This strengthens
validation; it does not add a padding or protocol fallback.

### V19 investigation and native-derived correction (0.5.5)

The 0.5.4 reference-based candidate failed on the current bank with an exact
V19-length error after another accepted credential check. No telemetry was decoded.
Its assumption that the declared length included the sentinel was incorrect.

Static inspection of the official app's ARM64 native library,
`libnative-lib.so`, establishes:

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

### 0.5.5 verification

Validation: 84 tests executed, six opt-in hardware checks
skipped, zero failures (78 hardware-free passed). This includes typed failure
cleanup and the native-derived synthetic V19 cases. Universal Debug/Release build
checks both passed
for arm64 and x86_64. Release signature verification passed and entitlements
remain App Sandbox plus Bluetooth only.
A new operator-assisted bank run is still required; no live V19 decode or port mapping
is claimed from these tests.

### Current-bank V19 streaming result (0.5.5)

The next report validates V3 status and credential replies, then V19
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

0.5.6 hardware-free validation: 84 tests
executed, six opt-in hardware checks skipped, zero failures (78 passed).
Universal Debug and Release builds passed for arm64/x86_64; the Release signature
verified.
The tested 0.5.6 Release build was launched for the next operator-assisted check.

### First complete authenticated telemetry session (0.5.6)

The complete report confirms a fresh credential check followed by
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

### Repeated loaded and unloaded sessions (0.5.6)

The test operator supplied two further completed results:

| Condition | Credential | Decoded bodies | Port-power updates | Duration | Cleanup |
| --- | --- | ---: | ---: | ---: | --- |
| Output loaded | Accepted | 87 | 29 | 31.283 s | Disconnected; passive scan resumed |
| Outputs unloaded | Accepted | 87 | 0 | 31.374 s | Disconnected; passive scan resumed |

The loaded result displayed field 852 at **−22.9 W, 15.3 V, 1.5 A**; other
allowlisted port fields had no measurements. The unloaded result showed missing
W/V/A for all port fields. No identity, serial, token or raw payload was supplied
or retained in these observations. The test operator identified the loaded physical port as **C1, labelled “140W in/out.”**
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

0.5.7 validation: 85 tests executed with six
opt-in hardware checks skipped and zero failures (79 hardware-free passed).
The new state-machine test distinguishes a decoded body with no embedded port
measurement from silence, and verifies absence is preserved through cleanup.
Universal Debug/Release builds passed for arm64 and x86_64, Release signature
verification passed, and 0.5.7 was launched.

### Resume checkpoint

Work stopped at the request after publishing the current implementation.
The tested local app is 0.5.7. Authentication and repeated decoded telemetry are
verified; field 852 maps to physical C1 (140W in/out) in an output test. All other
physical mappings remain experimental.

Next operator-assisted checks:

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
research inputs and private build artifacts remain ignored under `build/`.

### C2 payload rejection and diagnostic build (0.5.8)

The test operator tested C2, labelled “140W in/out,”
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

0.5.8 verification: the test run passed 87 tests
with six opt-in hardware checks skipped and zero failures (81 hardware-free
passed). Synthetic tests cover structural categories and C2 nested fields,
absolute offsets, no partial measurement/counter commit, secret cleanup and typed
export. The initial sandboxed run could not execute SwiftUI compiler plugins;
the subsequent Xcode run passed. Universal Debug and Release builds both contain
arm64 and x86_64. Release signature verification passed, with only App Sandbox
and Bluetooth entitlements.
Actual-bank 0.5.8 decoding, disconnection and passive scan restoration remain
the next operator-assisted hardware check; native visual QA was not performed.

### Battery field isolated from port decoding (0.5.9)

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
See [P512 Protocol](#p512-protocol) for source evidence and semantic details.

Next hardware check remains C2-only output with the same device. Run 0.5.9,
record protocol fields and W/V/A separately from Copy Diagnostics, and confirm
normal bounded completion, disconnect and passive scan restoration. A passing
synthetic test does not establish actual-bank C2 measurements or physical mapping.

0.5.9 verification: the test run passed 89 tests,
with six opt-in hardware checks skipped and zero failures (83 hardware-free
passed). Added synthetic coverage includes C2 power with invalid SOC, inclusive
0/100, repeated SOC fields, old-value invalidation and recovery, malformed port
rejection, write-acknowledgement barriers, bounded completion and private export.
Universal Debug/Release builds passed for arm64/x86_64. Release signature verified;
entitlements remain App Sandbox and Bluetooth only.
The verified Release was launched for operator-assisted hardware validation.

### Verified output mappings and 0.6.0 dashboard

The test operator supplied three completed 0.5.9 output sessions: C2 decoded 87 bodies
with 29 port updates in 31.227 s; C3 decoded 87/29 in 31.647 s; C4 decoded
90/30 in 31.584 s. All accepted credentials, disconnected and resumed scanning.
The test operator confirmed wattage agreement and identified C2=856, C3=853, C4=854,
complementing the earlier C1=852 mapping. Approximately -1 W with 9.1–9.2 V
and 0.1 A was expected because the connected device was full. C3 is labelled
65 W maximum. Field 857 is the bottom dock/pogo connection; dock hardware was unavailable for testing.
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

Pending operator-assisted acceptance: stream beyond 30 seconds on the bank, unload
and change ports, close/reopen the panel, test positive input direction, and
confirm passive scanning resumes. Synthetic streams do not establish these
hardware behaviors.

0.6.0 local validation: the test run passed 93 tests with six
opt-in hardware checks skipped (87 passed). Added tests cover a synthetic
90-second live session, 15-second silence termination, credential copy cleanup,
independent sample expiry/zero, and native normal/accessibility-size rendering.
The empty dashboard renders were inspected; connected/error/stale battery visual
states and real AppKit panel lifecycle remain pending live UI verification.
Debug and Release contain arm64/x86_64; Release signature verifies and retains
only App Sandbox and Bluetooth entitlements.  The verified Release was launched.

### 0.7.0 Battery Information checkpoint

Battery card In/Out watts now use device aggregate fields 3/4 directly. Health,
cycles, signed Celsius temperature and device energy counters are decoded from
the existing allowlisted uploads and exposed in the local diagnostic preview.
The dashboard disclosure retains per-field in-memory receipt ages across
disconnect, clearing snapshots on Forget/target change/Quit. Auto/Wh/kWh and
°C/°F are display-only preferences. No charging-limit or other device-setting
writes were added. Field/unit provenance is in P512 Protocol; bank availability,
accuracy and counter reset semantics remain unverified.

Validation: 97 tests executed, six opt-in hardware checks
skipped, zero failures (91 hardware-free passed). Tests cover signed int32
extremes/negative encoding, UInt32 limits, health isolation and recovery,
incremental ages, explicit zero, aggregate expiry, counter decrease replacement,
energy/temperature conversion and filtered presence-only diagnostics. Native
collapsed/expanded, populated/unavailable/aged detail renders and the dashboard
normal/larger-text renders were inspected. These are synthetic render checks,
not a live hardware/UI session. Universal Debug/Release contain arm64/x86_64;
Release signature and App Sandbox/Bluetooth-only entitlements verify.

Next check: connect in the dashboard, expand Battery Information and separately
record displayed measurements and Copy Diagnostics. Compare aggregate W under
output/input and the battery details against the official app in separate BLE
sessions. Unreported fields must remain unavailable. No hardware result for
0.7.0 is claimed from these synthetic tests.

### 0.8.0 Healthy Charging checkpoint

Battery Information and Healthy Charging share the dashboard card style. The
0.7.0 battery values were confirmed against the official app. Received temperature updates
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

Validation: 99 tests, six opt-in hardware tests skipped,
zero failures (93 hardware-free passed). New coverage includes exact encrypted
requests against independent synthetic OpenSSL vectors, authentication refusal,
sequence/range refusal, known settings fields, pre-ack/stale readback refusal,
matching readback, mismatches/timeouts, cancellation without retries and unique
settings sequences. Unknown/editing card renders and Battery Information card
renders were inspected against a panel background; actual connected/applying/
failure interaction remains operator-assisted UI validation. Debug/Release are
universal arm64/x86_64; Release signature verifies with only Bluetooth and
App Sandbox entitlements.

No bank setting was changed during development. Next: compare reported healthy
mode/limits read-only with the official app in separate BLE sessions, then use
explicit Apply to verify mode and limits on the bank. Reconnect and compare
reported persistence. Restore original settings explicitly if desired. Physical
cutoff behavior remains unverified.

### 0.9.0 native settings checkpoint

The test operator confirmed Healthy Charging controls work. This is recorded as an
operator-confirmed settings result, not independent physical cutoff validation.
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

Validation: 102 tests executed, six opt-in hardware checks
skipped, zero failures (96 hardware-free passed). Tests include independent
OpenSSL screen-write vectors, source-backed field/value restrictions, screen
readback without a Healthy Charging baseline, acknowledgement/stale/mismatch
handling, native light/dark pane renders, RGB565/header bytes, EXIF rotation,
square crop and alpha-to-black compositing. Unknown pane states were rendered;
connected controls, actual window/picker ownership and device interactions remain
operator-assisted acceptance. Progress/error transfer states cannot be validated
because artwork transport remains gated. Universal Debug/Release and signing
checks accompany this checkpoint. Added entitlement: user-selected read-only files.

Next: read and compare the eight screen settings with the official app, then
explicitly Apply and compare supported durations, brightness, clock enable/format
and battery/charging durations on the bank, including reconnect persistence.
Artwork upload/activation remains an unfinished gated capability, with local
preview usable now. Hardware settings were not changed during development.

### 0.10.0 compact settings checkpoint

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
fixtures for the lower-level transfer and current-bank resource-ID
acceptance remain concrete research/hardware gates. No physical transfer or
settings write was attempted during this implementation.

Validation: 104 tests executed, six opt-in hardware tests
skipped, zero failures (98 passed). Added tests exercise direct-draft initialization,
conflicts/Revert, pane feedback and settings-only cancellation while telemetry
remains active, including refusal of late acknowledgements. Existing protocol,
readback, image and unit regressions pass. Light/dark compact unknown-state panes
were rendered at actual default sizes and inspected; populated/working-bank
interaction, partial batch application and native sheet use remain operator-assisted
acceptance. Upload progress/rejection/activation tests cannot establish a
nonexistent transfer implementation. Universal build and signature checks are
recorded in private validation logs.

### 0.11.0 onboarding checkpoint

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
transport remains incomplete and gated as detailed in the P512 protocol and implementation record section.
