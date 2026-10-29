# installing Somnoire

a small setup now, a quieter menu bar afterward.

## before you begin

- a Mac running **macOS 13 or later**, with Bluetooth available. the app is built for both Apple silicon and Intel; not every supported macOS version has been hardware-tested.
- a supported power bank: the tested model is the **EcoFlow RAPID Pro 27,650 mAh (P512)**. other models and firmware are unverified.
- for full readings and device settings, access to the bank’s existing authorizing EcoFlow account. percentage-only monitoring needs no account.

**current release:** [Somnoire 1.0.0](https://github.com/Kusanalee/Somnoire/releases/tag/v1.0.0). the older `v0.11.0` prerelease remains available for reference; its interface and feature set differ.

## 1. download the app

open [Somnoire’s GitHub Releases](https://github.com/Kusanalee/Somnoire/releases) and choose a published release. under assets, download its macOS universal app ZIP—not the automatically generated source-code archive.

for 1.0.0, the file is `somnoire-1.0.0-macos-universal.zip`. a universal app contains both Apple silicon and Intel versions; there is no separate download to choose between them.

if checksums are supplied, you can optionally check the downloaded file in Terminal:

```sh
cd ~/Downloads
shasum -a 256 somnoire-1.0.0-macos-universal.zip
```

compare the result with that release’s `sha256sums.txt`. for future releases, use their actual ZIP filename and checksums rather than the example above.

## 2. move Somnoire into Applications

1. double-click the ZIP in Finder to extract it.
2. move `Somnoire.app` into Applications. for a per-user installation, use your home folder’s `Applications` folder (`~/Applications`) to keep one stable installation location.
3. open the copy in Applications. avoid running additional copies from Downloads or Xcode at the same time.

Somnoire normally lives in the menu bar. its Dock icon appears while onboarding, settings, or diagnostics windows are open; closing those windows leaves monitoring running.

## 3. first launch and macOS checks

Somnoire is **not Apple-notarized**. version 1.0.0 uses a reusable local signing certificate. local signing is not Developer ID signing and does not guarantee Gatekeeper approval.

### if Apple cannot verify Somnoire

macOS may say that Apple could not verify Somnoire is free of malware, or that its developer cannot be verified. Somnoire is locally signed but has not been submitted to Apple for notarization.

> **only follow these steps for a copy downloaded directly from [Kusanalee/Somnoire Releases](https://github.com/Kusanalee/Somnoire/releases), and only if you trust it. do not use this guide for third-party reuploads, mirrors, or files sent by someone else.** you can compare the ZIP’s SHA-256 with the checksum on that same release page before opening it.

1. in Finder, try opening `Somnoire.app` once. if macOS blocks it, dismiss the warning without moving the app to Trash.
2. open **System Settings → Privacy & Security**.
3. scroll to the security section and find the notice about Somnoire being blocked. click **Open Anyway** for **Somnoire**.
4. review the next confirmation, then choose **Open** if you still want to proceed. macOS may ask you to authenticate with your Mac password or Touch ID; do that in the system prompt, not in Somnoire or a message to anyone else.

this creates an exception for this app; it does **not** notarize Somnoire or prove that a file is safe. it does not require turning off Gatekeeper for the rest of your Mac. the wording and available controls vary by macOS version and device-management policy.

if Open Anyway is absent, try opening the app once more and check Privacy & Security again. on a managed Mac, ask your administrator if exceptions are restricted. do not disable Gatekeeper system-wide or use quarantine-removal commands as a routine workaround.

**stop if macOS reports malware, damage, tampering, or a checksum mismatch.** this guide is for the unidentified-developer/notarization warning, not those alerts. download a fresh copy from this repository or report the exact message if you are unsure.

see [Apple’s guide to opening apps safely](https://support.apple.com/en-us/102445). if no supported opening option is offered, consult the [source-build guide](building.md); the maintainer’s signing key is not included.

## 4. allow Bluetooth and choose your bank

1. keep the bank awake and nearby, and turn on Bluetooth on your Mac.
2. open Somnoire and follow the welcome guide. the older `v0.11.0` prerelease uses settings → general instead.
3. allow Bluetooth when macOS asks. if you previously denied it, check System Settings → Privacy & Security → Bluetooth and enable Somnoire there.
4. find and select your bank. if the official EcoFlow app is holding its Bluetooth connection, close that connection first.

Somnoire remembers the selected bank and does not silently switch to another. “searching” can mean the bank is asleep, out of range, or not broadcasting; it does not by itself mean permission is missing.

## 5. choose how much you want to see

**battery percentage only** is the default. it needs no EcoFlow account and uses nearby battery advertisements. you can enable optional low-battery alerts separately in settings → alerts; macOS notification permission is requested when you enable them.

choose **full readings** for wattage, battery details, and charging/screen settings. this currently requires a one-time numeric EcoFlow account ID. use the bank’s existing authorizing account if already linked; do not reset or unbind it just to use Somnoire.

follow the [first-time setup guide](first-time-setup.md) to obtain the ID and connect. enter only the numeric ID, never your email, password, or login tokens. after connection succeeds, quit and reopen Somnoire to check remembered access. the derived credential is stored locally in Keychain.

## updating an existing installation

1. quit Somnoire with the dashboard’s Quit button. closing settings alone does not quit it.
2. back up the existing app if you want a rollback copy, then replace the app at the same Applications location with the new version.
3. open the replacement and check settings → about for its version.

for the maintainer’s personal upgrade, the identifier changed from `org.somnoire.Somnoire` to `io.github.kusanalee.Somnoire`. this creates a new macOS permission identity and may require initial Bluetooth/notification grants, a normal Keychain access confirmation, or one-time setup again. do not send anyone your Mac password; handle system Keychain prompts yourself.

old data is retained if migration is blocked. the local preference-migration helper is personal upgrade tooling, not a required installation step for new users. if you used Launch at Login in the old app, check that only the new installation is enabled.

Bluetooth permission survived unchanged-build relaunches and a changed-build upgrade with the same local signing identity on the test Mac. this does not guarantee retention after changing signer, replacing the key, or moving between unrelated builds.

## if something seems quiet

- **no percentage yet:** wake the bank, keep it nearby, check Bluetooth access, and make sure Monitor Battery is enabled in general settings.
- **percentage looks dim:** it is the last verified reading. Somnoire has not received a fresh report yet.
- **full readings will not connect:** release the official app’s Bluetooth connection and check the authorizing account ID through the setup guide. try Retry in general settings.
- **no notification:** check Somnoire’s alerts setting and macOS notification/Focus settings. Somnoire must be running, monitoring enabled, and the bank nearby. monitoring pauses during sleep.

forget bank deletes remembered access on this Mac; it does not change ownership or reset the bank. artwork changes, time setup, sharing, and firmware updates use the official EcoFlow app.

[back to the README](../README.md) · [account-ID setup](first-time-setup.md) · [build from source](building.md)
