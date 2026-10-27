# Phase 2C — account-free telemetry access research

This milestone adds a bounded **Connect & Probe → Account-free telemetry check**.
It is the verification gate for live per-port power, not a wattage feature.
The existing advertisement-based battery monitor and two original probes remain.

## What the experiment does

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

## Retained capture and reference findings

The ignored `build/rapid-pro-full.cfa` is a BTSnoop H4 capture. A local metadata-only
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

## Running the check

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

## Validation and remaining gate

On 27 October 2026 (Asia/Manila), four fresh sessions reached the observation
window on the nearby bank. Two attempts were repeated while the user confirmed
that the bank was actively charging a device. All four returned a strictly validated
V3 status reply with a two-byte payload and header `35/01 → 21/01`, command
`35/89`. **None returned another validated packet.** Two windows completed; two
ended with a peripheral disconnect during observation. All released the connection.

The two opt-in hardware test runs passed **as bounded experiments**:
`build/Phase2CTelemetryHardware-R4.xcresult` and
`build/Phase2CTelemetryHardware-Loaded.xcresult`. These are not port-power acceptance
tests. Earlier discovery attempts received no advertisements; discovery recovered
after closing the regular Somnoire instance. Run one instance at a time.

The final default suite (`build/Phase2CUnitTests-Final.xcresult`) passed
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

## Subsequent schema research

The installed official app now establishes an [app-derived P512 payload schema](P512-Protocol.md).
The original Swift decoder is tested on synthetic payloads. This resolves the
payload-schema research prerequisite at app-source confidence; the BLE request,
access behavior and hardware comparison gate remain open.
