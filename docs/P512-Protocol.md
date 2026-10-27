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
