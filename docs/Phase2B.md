# Phase 2B — continuous monitoring and native menu

Somnoire 0.5.0 monitors the verified P512/type-7 battery advertisements continuously
after the user enables **Monitor Battery**. This is automatic discovery/monitoring,
not a persistent GATT connection. There is no automatic connection, subscription,
probe, login, telemetry request, device control, or reconnect loop.

## Everyday behavior

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

## Diagnostics and lifecycle

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

## Native design basis

Reviewed Apple's current HIG on 26 October 2026:

- [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
  — native menu for simple extras, template symbols and familiar behavior.
- [Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
  — important actions first, concise labels, logical groups and sparing icons;
  the page records an icon-guidance update on 8 June 2026.
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
  — system components adopt platform appearance; no custom glass layers are added.
- [Duplicate advertisement option](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerscanoptionallowduplicateskey)
  — continuous samples require disabling duplicate filtering, with a power tradeoff.

The app retains macOS 13 support, a hidden Dock icon and system typography/colors.
The utility is a technical-tools window, not the future standalone monitoring UI.

## Validation

The final default suite passed **51 hardware-free tests**, with four opt-in
hardware tests skipped (`build/Phase2BTests-Delivery.xcresult`). Tests cover association,
ambiguity, remembered-target behavior, expiry, invalidation, pause/Bluetooth/sleep
presentation, candidate bounds, burst coalescing, diagnostic deduplication,
preferences, test-host restoration, window lifecycle and light/dark intrinsic size.
Existing Phase 0, advertisement decoding and cryptographic tests remain.

The **Somnoire Continuous Monitoring Check** hardware test passed in **45.296 s**
(`build/Phase2BHardware.xcresult`). It accepted **38 advertisements**, retained a
fresh reading after more than 30 seconds with no menu open, and refreshed after
pause/resume. It observed no GATT connection, subscription or probe activity.

The separate **Somnoire Diagnostic Lifecycle Check** makes one explicitly requested
read-only GATT connection to test suspension, close/teardown, retained stale services
and monitoring resumption. It sends no proprietary packets or subscriptions.
It passed in **7.929 s** (`build/Phase2BDiagnosticHardware.xcresult`), confirming
monitoring resumed after closure and the nonempty GATT snapshot remained stale.

Debug and Release compile for **arm64 and x86_64** with deployment target macOS 13.
The packaged **0.5.0** Release at `build/Somnoire.app` is locally ad-hoc signed and
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
