# Phase 1A — bounded key-exchange probe (historical)

For current behavior and results, see [Phase 1B](Phase1B.md).

Somnoire 0.2.0 adds **Connect & Probe** for the observed RAPID Pro profile.
Ordinary **Connect** remains a GATT-only inspection operation.

## Verified behavior

On 26 October 2026 (Asia/Manila), the opt-in native hardware test completed
**two consecutive probes** on the user's RAPID Pro. Each generated fresh keys,
validated the peer point, decrypted the 32-byte key-info ciphertext with valid
PKCS#7 padding and an 18-byte plaintext result, discarded it, and intentionally
disconnected. The selected test passed in 5.568 seconds total, including scanning
and both disconnects. CoreBluetooth `.withResponse` writes worked on this device.

Result text: **Key exchange verified — authentication not attempted.**
This does not establish authentication, a persistent session, telemetry decoding,
or whether a later authentication stage requires an account identifier.

## Evidence and protocol

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

## Native implementation and dependencies

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

## Tests

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

- Unit tests: `build/Phase1Tests-Final.xcresult` — 31 passed, hardware test skipped.
- Hardware: `build/Phase1Hardware.xcresult` — both probe attempts passed.
- Debug and Release compile for arm64 and x86_64 with deployment target macOS 13.

Intel runtime, macOS 13 runtime, and the new button's live menu-panel appearance
have not been directly checked. Native sizing tests pass. The next protocol phase
must investigate final session-key derivation and authentication independently.
