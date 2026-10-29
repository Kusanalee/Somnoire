# installing Somnoire

a small setup now, a quieter menu bar afterward.

## before you begin

- a Mac running **macOS 13 or later**, with Bluetooth available. the app is built for both Apple silicon and Intel; not every supported macOS version has been hardware-tested.
- a supported power bank: the tested model is the **EcoFlow RAPID Pro 27,650 mAh (P512)**. other models and firmware are unverified.
- for full readings and device settings, access to the bank’s existing authorizing EcoFlow account. percentage-only monitoring in the upcoming version needs no account.

**release status:** `v0.11.0` is currently the published prerelease. `1.0.0` is the planned release of the newer version described by the README; it is not available to download yet. use each release’s notes to check which features it includes.

## 1. download the app

open [Somnoire’s GitHub Releases](https://github.com/Kusanalee/Somnoire/releases) and choose a published release. under assets, download its macOS universal app ZIP—not the automatically generated source-code archive.

for the current prerelease, the file is `somnoire-0.11.0-macos-universal.zip`. a universal app contains both Apple silicon and Intel versions; there is no separate download to choose between them.

if checksums are supplied, you can optionally check the downloaded file in Terminal:

```sh
cd ~/Downloads
shasum -a 256 somnoire-0.11.0-macos-universal.zip
```

compare the result with that release’s `sha256sums.txt`. for future releases, use their actual ZIP filename and checksums rather than the example above.

## 2. move Somnoire into Applications

1. double-click the ZIP in Finder to extract it.
2. move `Somnoire.app` into Applications. for the current personal build, use your home folder’s `Applications` folder (`~/Applications`) to keep one stable installation location.
3. open the copy in Applications. avoid running additional copies from Downloads or Xcode at the same time.

Somnoire normally lives in the menu bar. in the development version, its Dock icon appears while onboarding, settings, or diagnostics windows are open; closing those windows leaves monitoring running.

## 3. first launch and macOS checks

Somnoire is **not Apple-notarized**. the published prerelease is ad-hoc signed; the current personal build uses a reusable local certificate. local signing is not Developer ID signing and does not guarantee Gatekeeper approval.

if macOS blocks the app, verify that you downloaded it from this repository’s release page. if you trust that copy and macOS offers an **Open Anyway** option in System Settings → Privacy & Security, review and complete that confirmation yourself. the exact wording varies by macOS version. do not disable Gatekeeper system-wide or remove quarantine as a routine installation step. stop if the warning reports malware, a damaged app, or the file does not match the expected download.

if no supported opening option is offered, use the [source-build guide](building.md) or report the exact warning rather than bypassing it. the current source-build script requires a local signing identity; the maintainer’s private key is not included.

## 4. allow Bluetooth and choose your bank

1. keep the bank awake and nearby, and turn on Bluetooth on your Mac.
2. open Somnoire and follow the welcome guide in the upcoming version. the older `v0.11.0` prerelease uses settings → general instead.
3. allow Bluetooth when macOS asks. if you previously denied it, check System Settings → Privacy & Security → Bluetooth and enable Somnoire there.
4. find and select your bank. if the official EcoFlow app is holding its Bluetooth connection, close that connection first.

Somnoire remembers the selected bank and does not silently switch to another. “searching” can mean the bank is asleep, out of range, or not broadcasting; it does not by itself mean permission is missing.

## 5. choose how much you want to see

in the upcoming version, **battery percentage only** is the default. it needs no EcoFlow account and uses nearby battery advertisements. you can enable optional low-battery alerts separately in settings → alerts; macOS notification permission is requested when you enable them.

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
