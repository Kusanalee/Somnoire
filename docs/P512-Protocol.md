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
