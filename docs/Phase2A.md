# Phase 2A — advertisement battery snapshots

Somnoire 0.4.0 adds a bounded candidate decoder and hardware-gated battery UI.
Scanning remains manual, unfiltered, duplicate-suppressed and limited to 30 seconds.
Battery sampling makes no connection, subscription, cryptographic exchange or
proprietary write. Existing Connect and both explicit probes retain their behavior.

## Evidence and gate

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

## Snapshot behavior and privacy

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

## Future encrypted telemetry evidence

Read-only inspection of the installed Android app **6.17.4.14**, version code
11113, found `assets/bundle/PowerBank.bundle` (2,884,318 bytes), SHA-256
`ef8c0d64dc82ab52b7564137b6a40dcf998bbf12d784ad0045256a5d088249fe`.
Its shared power-bank decoder describes integer `soc` at payload offset 11 and
little-endian Float32 `socF` at offset 12; its UI data handler accepts command set
`0x0C`, ID `0x01`. The bundle maps the broader P51 serial family to PB501. This
is a candidate shared layout, not P512-specific hardware proof. No app bundle,
source excerpt, encrypted telemetry request or decoder is included in Somnoire.
The APK was inspected as installed code, without accessing account data, launching
the app, or changing phone settings.

## Validation

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

### Physical comparisons — 26 October 2026

- Full charge: the earlier local manufacturer payload contained `0x64` at index 19
  and the user confirmed **100%** on the physical display.
- Lower charge: the passive native hardware sample read **96**. The user then
  confirmed **96% now** on the physical display. The preceding 99% report was older;
  it was not used as a mismatched simultaneous comparison or silently treated as
  a passing result.
- The passive test passed in 0.111 seconds with no connection/probe/subscription
  events (`build/Phase2ABatterySample-R3.xcresult`). Two earlier scans returned zero
  peripherals while an older Xcode-run Somnoire instance was present; discovery
  resumed after that instance was closed. Those unsuccessful scans are retained
  as environmental observations, not protocol-validation passes.

The numeric label is enabled for the restricted observed P512/type-7 profile.
This establishes the initial practical mapping on this bank, not every firmware,
flag combination or other EcoFlow model. The full byte remains range-checked;
unsupported status-bit combinations continue to produce Battery unavailable.

### Build and regression results

- Final default suite: **42 hardware-free tests passed**, two opt-in hardware tests
  skipped, zero failures (`build/Phase2ATests-Final.xcresult`). This includes native
  panel sizing and both prior probe modes' synthetic regressions.
- Debug and Release compile for **arm64 and x86_64**, deployment target macOS 13.
- The Release bundle at `build/Somnoire.app` is version **0.4.0**, locally ad-hoc
  signed and verified. Entitlements remain only App Sandbox and Bluetooth access;
  `LSUIElement` remains true. Dependency resources/notices match source; no DEBUG
  crypto test hooks or OpenSSL libraries enter Release.
- Direct inspection of the new battery row, Intel runtime, and macOS 13 runtime
  remain unperformed. The native hosting-view panel-size regression passed.

One older Somnoire instance was closed for hardware sampling. Run a single instance
and use **Scan** to obtain a new battery snapshot; simply opening the panel does
not scan or reconnect.
