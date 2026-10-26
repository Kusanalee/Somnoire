# BLE research — Phase 0 (historical)

Reviewed 26 October 2026. These are observations about other software and products,
not a verified specification for the EcoFlow RAPID Pro 27,650mAh (300W).
This note records the Phase 0 research boundary. Phase 1A now implements only the
two captured session requests; see [the Phase 1A report](Phase1A.md). Account
authentication and telemetry decoding are still unimplemented.

## Sources and licensing

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

## Discovery and GATT

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

## Authentication and packet formats — research only

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

## Phase 1 evidence needed

Capture the actual power bank's advertisements, GATT tree, property flags,
connection behavior and unsolicited notification availability using Phase 0.
Review any raw data locally before sharing; opaque data may contain identifiers
or other sensitive information. Only then determine which protocol, if any,
applies. Account-free discovery does not promise account-free proprietary auth.

The current bounded session/status experiment and table provenance are documented
in [Phase 1B](Phase1B.md); historical nonimplementation statements above describe
their original phase. No login or telemetry implementation has been added.
