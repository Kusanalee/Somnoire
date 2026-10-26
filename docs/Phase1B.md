# Phase 1B — encrypted session/status experiment

Somnoire 0.3.0 provides two explicit **Connect & Probe** menu choices:
**Key exchange only** (the unchanged Phase 1A boundary) and **Session + status**.
Both intentionally disconnect. Ordinary **Connect** performs GATT inspection and
standard manual subscriptions only; it sends no proprietary values.

## Evidence and limits

The user's 0.2.0 diagnostic export records successful probes lasting 724 ms and
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

## Protocol data provenance

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

## Native behavior

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

## Validation

On 26 October 2026, both explicitly requested native hardware attempts passed on
the nearby eligible RAPID Pro. They received strictly validated matching encrypted
status replies in **0.851 s** and **0.792 s** from connection establishment, then
intentionally disconnected. The selected XCTest passed in 11.024 s total including
scanning and teardown, with zero failures/skips (`build/Phase1BHardware.xcresult`).
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

- Final default suite: **36 passed**, one opt-in hardware test skipped, zero failures
  (`build/Phase1BTests-Final.xcresult`).
- Debug and Release compile for **arm64 and x86_64**, deployment target **macOS 13**.
- Release excludes DEBUG crypto hooks and OpenSSL linkage; its protocol resource
  and notices are checked against source. Release signing disables Xcode's injected
  debugger entitlement, retaining only App Sandbox and Bluetooth access.
- The native panel sizing regression passes. Direct inspection of the new menu
  choices, Intel runtime, and macOS 13 runtime remain unperformed; compilation and
  hosting-view tests do not establish those checks.

The local runnable artifact is `build/Somnoire.app` (0.3.0). Ordinary test execution
does not enable hardware probing. Raw Android captures remain ignored under build/.
