# Phase 2D — account-free access experiment

## Result

Somnoire 0.5.2 adds **Connect & Probe → Account-free access check**. It reads a
validated authentication-status summary, then requests one display report using a
fixed app-derived payload. It does not log in, provision credentials, change
ownership, unbind, reset, change report periods, or alter charging/port settings.

On 27 October 2026 (Asia/Manila), two independent fresh sessions on the user's
loaded P512 returned **app would check an existing credential · normal mode**.
Both sent the one-shot report request and received its GATT write acknowledgement.
Neither received a matching application reply or a display upload. The bank
initiated disconnection after approximately **9.70 s** and **9.48 s** from connection.
The test verified that battery scanning resumed after each attempt.

The dedicated hardware test passed **as an experiment**, not as account-free
telemetry acceptance (`build/Phase2DHardware-R2.xcresult`). Both attempts decoded
zero telemetry packets and zero port-power updates. No physical port comparison
was therefore possible. Two independent decoded streams plus a confirmed load
change remain required before claiming a working path.

**Precise remaining blocker:** the tested pre-authentication display-report action
produced no response in this bank's existing credential state. The app would next
check its existing credential; that step was deliberately not attempted. This is
not proof that every firmware/read path needs an EcoFlow account, nor a result
for a never-linked bank.

## Source trace and operation classification

Evidence comes from static inspection of the user's installed EcoFlow app
6.17.4.14/11113. APK/bundle hashes and the P512-to-PB501 mapping are recorded in
[P512 Protocol](P512-Protocol.md). No app storage, account values or logs were read.

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

## Authentication summary

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

## Probe and crypto boundaries

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

## Never-linked onboarding research

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

## Validation and remaining work

Hardware-free coverage includes native encrypted request bytes and payload
allowlisting, unknown/unsupported status, unrelated authentication replies,
status-only outcomes, fragmented/coalesced frames, early replies, pending writes,
malformed telemetry, deadlines, cancellation, disconnect and late-event cleanup,
partial protobuf updates and diagnostics privacy. Public synthetic fixtures contain
no device/account material. Current-bank APIs cannot construct credential, unbind,
reset or arbitrary settings writes.

**Final hardware-free suite:** 67 passed, six opt-in hardware checks skipped, zero
failures (`build/Phase2DTests-Final.xcresult`). Debug and Release compile for
arm64 and x86_64; both universal binaries and the Release signature were verified.
Release retains App Sandbox/Bluetooth-only entitlements. Intel/macOS 13 runtime
and live UI appearance remain unverified; native sizing tests are not visual QA.
The next supported step requires either another evidence-backed anonymous read
path or dedicated never-linked hardware to validate a fully local onboarding flow.
The existing bank's credentials will remain unchanged.
