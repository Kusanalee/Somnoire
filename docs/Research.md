# Somnoire: Bluetooth protocol research and implementation

Somnoire communicates locally with the EcoFlow RAPID Pro 27,650 mAh power bank,
identified by the P512 model prefix. This paper explains the evidence behind its
Bluetooth implementation, the distinction between passive monitoring and
authenticated access, and the limits of the available hardware validation.

The findings apply to the tested model and firmware. They are not a universal
EcoFlow specification. Personal identifiers, installation details, observation
dates, and device-history readings are omitted.

## Abstract

P512 exposes two useful sources of information: Bluetooth advertisements and an
encrypted application session. Advertisements support account-free battery
percentage monitoring. An authenticated session provides incremental telemetry
and selected device settings. Static analysis of the official application's
P512 implementation established the payload schema; controlled hardware checks
then established live decoding and the four USB-C output mappings.

Full access to the tested linked bank requires an existing authorizing credential.
No account-free full-access path has been established. Custom artwork transfer and
automatic clock synchronization remain unavailable because their end-to-end
behavior has not been sufficiently validated.

## Evidence and method

Three kinds of evidence underpin the implementation:

- **Reference implementations** describe candidate discovery markers, framing,
  cryptography, and authentication behavior. Their behavior on other products
  does not by itself establish P512 support.
- **Static application analysis** identifies P512-specific model mapping, payload
  fields, units, and settings serialization in official Android application
  version 6.17.4.14, version code 11113.
- **Hardware comparisons** establish that a candidate works on the tested bank.
  Successful decryption, successful authentication, decoded telemetry, physical
  port mapping, and physical charging cutoff are separate acceptance criteria.

Application code was inspected without reading account storage or credentials.
Private captures, application packages, and validation artifacts are excluded
from the repository. The Swift implementation and synthetic test fixtures are
original work; generated proprietary application code is not redistributed.

<a id="phase-2a"></a>

## Discovery and passive battery monitoring

Somnoire scans without a service-UUID filter because advertised services vary
across EcoFlow protocol families. Manufacturer markers and names are discovery
hints, not authenticated device identities. CoreBluetooth includes the two-byte
manufacturer identifier in its data; offsets from libraries that separate this
identifier cannot be reused unchanged.

For the supported P512 advertisement profile, the battery candidate is byte 19
of CoreBluetooth manufacturer data. Acceptance also requires the expected
manufacturer marker, profile byte, model prefix, serial-field structure,
encryption-type hint, and sufficient length. Values outside 0–100 are rejected.
Physical comparisons at full and partial charge established the percentage
mapping for the tested bank.

This path requires neither a GATT connection nor account authentication. It
reports whole percentages. Fractional display precision cannot create precision
that the advertisement does not supply.

A selected bank remains explicit: monitoring does not silently switch devices.
Freshness uses monotonic elapsed time, with a 30-second battery freshness limit.
Stale values remain visibly stale; opening a connection does not refresh a cached
measurement. Monitoring pauses during sleep and Bluetooth unavailability.

## Encrypted sessions and authentication

A Bluetooth connection establishes transport, not application authorization.
The implemented session begins with a bounded ECDH/key-information exchange,
followed by session-key derivation and encrypted protocol messages. The native
cryptographic bridge uses secp160r1 and AES-CBC with validated padding. Public,
synthetic fixtures independently exercise key derivation and encrypted requests.
Dependency provenance and licensing remain in the vendor notices.

The authentication-status command (`35/89`) reports access state; it is not a
port-power request. The official application's normal authentication path derives
an authorization value from an account identifier and destination serial. The
existing-credential check (`35/86`) is distinct from provisioning (`35/85`).
Somnoire uses the existing authorizing credential and does not provision, unbind,
or reset the tested linked bank.

A bounded display-report request without credential acceptance produced no
decoded telemetry. This rules out that tested candidate, not every possible
account-free route. The inspected alternate authentication helper also depends
on account tokens; no applicable physical-presence route was established.

Full-reading setup therefore uses the bank's authorizing numeric account ID.
After authenticated telemetry confirms access, the derived credential can be
stored in a local, non-synchronizing Keychain entry. Forget removes saved access
from the Mac without changing the bank's binding. See the
[first-time setup guide](first-time-setup.md) for practical instructions.

## Packet framing and validated telemetry routing

The encrypted transport carries inner packets with version-dependent layouts.
Reference V3 assumptions were insufficient for the bank's V19 (`0x13`) uploads.
Static analysis of the official native parser established the relevant layout:

- The declared payload length excludes the 20 bytes of framing overhead.
- The payload begins at byte 18, followed by a two-byte trailer.
- Encoding and checksum selectors occupy distinct header bit fields.
- Encoding 1 applies the native parser's payload XOR transformation.

Somnoire validates decryption padding, header CRC8, declared size, supported
encoding, checksum policy, and routing before decoding a body. Payloads are
bounded to 984 bytes. Unsupported layouts and malformed frames fail explicitly.

The verified authenticated upload route is `02/01 → 21/00`, command `FE/15`.
Acceptance of this route is limited to authenticated V19 sessions. Notifications
may contain multiple frames or fragments of a frame; notification boundaries do
not define protocol packet boundaries. An unrelated reply is not treated as
acknowledgement of the display request.

Repeated fresh sessions established credential acceptance followed by decoded
telemetry, including loaded port updates. Completion and disconnection restored
passive monitoring. These observations establish the implemented access path;
they do not establish whether uploads would begin without the display request.

<a id="p512-protocol"></a>

## Telemetry schema and interpretation

The official application maps P512 to its PB501 family. RapidStudio decodes
`DisplayPropertyUpload`, including nested `UsbRealDisplayInfo` messages. The
schema describes the decrypted protobuf body, not a complete BLE packet.

| Field | Meaning | Representation |
| --- | --- | --- |
| 3 / 4 | Aggregate input / output power | float32, watts |
| 262 | Battery state of charge | float32, percent |
| 282 | Charge/discharge state | uint32 |
| 852 / 856 / 853 / 854 | USB-C1 / C2 / C3 / C4 | Nested port message |
| 857 | Dock/pogo measurement | Nested port message; hardware unverified |
| 263 | Battery health | float32, percent |
| 1251 | Battery cycles | uint32 |
| 102 | Battery temperature | signed int32, °C |
| 1275 / 1274 | Reported energy in / out | uint32, Wh |

Each port message contains float32 watts, volts, and amps in fields 1, 2, and 3.
There is no integer scaling in this application path. Positive port watts denote
input and negative watts denote output in the official application's chart logic.
Physical output comparisons confirmed C1=852, C2=856, C3=853, and C4=854,
including the nonsequential C2 field. Input-direction behavior remains less
thoroughly validated. A shared-schema USB-A field does not establish an extra
physical port on P512.

Updates are incremental. Missing fields preserve prior values and their original
sample times; explicit zero is a new measurement. Unloaded ports were observed
to disappear from updates rather than report explicit zero. Refreshing one field
must not make another field fresh.

The decoder rejects malformed lengths, overflowing varints, incorrect wire types,
nonfinite measurements, and unsupported structures without partial commits.
Finite out-of-range state of charge or health is handled separately: the affected
measurement becomes unavailable with a structural warning while other valid
fields remain usable. Such values are neither clamped nor reinterpreted as
undocumented sentinels. A later valid reading restores availability.

Battery Information fields were compared with the official application. Their
representation is established, but counter reset policies and lifetime semantics
are not. Somnoire displays reported energy counters rather than integrating power
or inventing session totals. Each measurement retains its own sample age.

## Device settings and confirmation

Settings requests use authenticated ConfigWrite messages (`21→02`, `FE/11`).
Only supported fields and values are constructible. Editing creates a local
draft; Apply initiates a serialized operation. Transport completion alone does
not establish that the bank accepted or retained a setting.

Confirmation requires the appropriate acknowledgement and fresh matching reported
values. Missing, stale, unknown, or mismatched reports leave the result
unconfirmed. Cancellation and failure do not trigger automatic retries, rollback,
or restoration of earlier settings.

| Setting | Write field | Reported field | Supported interpretation |
| --- | --- | --- | --- |
| Healthy Charging | 188 | 848 | 1 enabled, 2 disabled |
| Charge ceiling | 33 | 270 | 80–100% |
| Discharge reserve | 34 | 271 | 0–20% |
| Information display duration | 12 | 18 | Source-defined duration choices |
| Display brightness | 14 | 5 | 0–100 |
| Clock enabled | 304 | 825 | Source-defined enable/disable values |
| Clock duration | 305 | 826 | Source-defined duration choices |
| Clock format | 306 | 827 | 12-hour / 24-hour |
| Charging clock duration | 554 | 1259 | Includes source-defined Never value |

Charging and screen controls have reported-value/readback evidence. Physical
charging cessation at an 80% ceiling was also verified. Other ceilings and
physical discharge-reserve cutoffs remain unverified; matching a configuration
report does not substitute for those physical checks.

## Unavailable capabilities

### Automatic clock synchronization

Static analysis identifies UTC time, offset, timezone ID, and automatic-mode
write fields. Independent encrypted fixtures exercise the bounded constructor,
including negative offsets. The official offset conversion uses whole hours
multiplied by 100; fractional-hour offsets are refused rather than truncated.

Reliable end-to-end clock setting remains unestablished. Reported offset, timezone,
and mode do not provide a verified echo of the UTC time itself. A clock that
happens to match the host does not identify which operation set it. Automatic
clock writes and observers are disabled in Release; time setup remains in the
official application.

### Custom artwork transfer

Static analysis describes a 240×240 RGB565 resource format and generic native
A1/A2/A3 setup, chunk, and completion commands. It also identifies resource
selection fields. These findings establish candidate mechanics, not a verified
P512 BLE transfer path.

The official application's artwork feature was unavailable in Bluetooth mode.
Local resource-ID acceptance, collision handling, request/reply correlation,
cancellation, capacity, and activation remain unresolved. No transfer success is
claimed. The preview-only editor and artwork-write surface were removed;
Somnoire uses artwork already installed on the bank.

## Validation and limitations

The 1.0.0 release record contains 114 passing hardware-free tests, seven skipped
opt-in hardware checks, and two passing Python migration checks. Universal Debug
and Release architectures, signature verification, packaged icon metadata, and
sandbox/Bluetooth-only entitlements were checked. The app is locally signed,
without Developer ID distribution signing or Apple notarization.

Synthetic tests cover protocol framing, independent encrypted vectors, protobuf
bounds, incremental merging, settings confirmation, session cleanup, freshness,
and credential-storage seams. They establish implementation behavior under known
inputs; they do not establish hardware availability or acceptance.

Hardware evidence supports passive percentage decoding, authenticated telemetry,
four USB-C output mappings, Battery Information comparisons, selected settings,
the 80% charge cutoff, and remembered access. Permission retention and notification
artwork were verified for the tested installation and signing identity. They are
not guarantees for other systems.

Remaining gaps include other firmware and models, input-direction comparisons,
dock readings, other physical charging cutoffs, never-linked account-free full
access, reliable clock synchronization, and artwork transfer. Intel binaries and
the minimum deployment target do not establish runtime testing on every supported
Mac or macOS version.

## Sources and licensing

The following pinned reference snapshots informed the research. Their product
coverage and license terms must be evaluated independently of Somnoire's own MIT
implementation.

| Reference | License at reviewed snapshot | Relevance |
| --- | --- | --- |
| [re-ecoflow](https://github.com/chukfinley/re-ecoflow/tree/eb2feb4820e3d313d582d76ecd78f8b4a2dea931) | MIT | Discovery and Android protocol research |
| [ef-ble-reverse](https://github.com/rabits/ef-ble-reverse/tree/9fdc35654c3c89f3382af6a2c81bf568734a678f) | Apache-2.0 | Session and transport experiments on other products |
| [ha-ef-ble](https://github.com/rabits/ha-ef-ble/tree/817620c38d04b55ee4b5d094269dfe0080355b6d) | Apache-2.0 | Authentication families, packet framing, and shared schemas |
| [efctl](https://github.com/zettamax/efctl/tree/8315bcde4238eda468619e6405eee04b565318a8) | Apache-2.0 | Discovery and authenticated BLE implementation |
| [Advertisement parser](https://github.com/npike/ha-ecoflow-ble/blob/0726ed4b20abfdb1b5da38df06f79fe66d6dbfe3/custom_components/ecoflow-ble/ecoflow_ble/protocol.py) | Consult source repository | Candidate advertisement layout |

The official application's RapidStudio modules establish the P512/PB501 mapping,
protobuf schema, incremental merging, port sign convention, Battery Information
units, and supported settings. The native library establishes the V19 parsing
behavior. The [public shared schema](https://github.com/rabits/ha-ef-ble/blob/817620c38d04b55ee4b5d094269dfe0080355b6d/proto/dev_apl_comm.proto)
corroborates field numbers; it is not the sole basis for assigning P512 behavior.

The similarly named P521 RAPID Pro charger is a different product. Its placeholder
authentication behavior and model-specific commands do not establish support for
the P512 power bank. Vendored dependency provenance and license text are retained
in [third-party notices](../ThirdPartyNotices.txt) and the vendor directory.

For reproducible builds and tests, see [building](building.md). For usage and
installation, see [installation](installation.md) and the [project overview](../README.md).
