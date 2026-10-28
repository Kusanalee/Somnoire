# somnoire

a small macos menu bar app for the ecoflow rapid pro 27,650mah power bank.

check your battery, see what each usb-c port is doing, and adjust charging and screen settings without keeping the official app open.

named after the location in wuthering waves. an independent project, unaffiliated with ecoflow.

## what it does

- shows the battery percentage in your menu bar
- displays live input and output power for all four usb-c ports
- shows battery health, cycles, temperature, and total energy in and out
- lets you adjust healthy charging, charge limits, and discharge reserve
- controls screen brightness, display duration, and clock settings
- remembers your power bank securely and can launch at login

## getting started

1. open somnoire and allow bluetooth access when prompted.
2. open settings, choose general, and find your nearby power bank.
3. select your bank and enter its numeric ecoflow account id once. this is your account id, not your email or password.
4. connect, then open the menu bar dashboard. you can enable launch at login in general settings.

after a successful connection, somnoire saves a bank-specific credential in your mac's keychain. remembered access has been tested across quit and relaunch. the account id is cleared after use.

battery percentage monitoring works without an account. live readings and settings currently need that one-time account-id setup. fully account-free pairing is still being researched.

keep the bank nearby and awake. if it cannot connect, close the official app's connection and try again. only the selected bank is used; somnoire does not silently switch to another one.

## everyday use

open the dashboard for live power readings. closing the dashboard and settings ends the active connection while enabled background battery monitoring continues.

changes in settings stay local until you click apply. “settings applied” appears after the bank reports the new values. revert discards your edits, and done closes settings without applying them.

missing or expired readings show dashes. disconnected battery information is marked with its last update. forget bank removes its saved credential from this mac; it does not unbind or reset the bank.

## downloads

**0.11.0 is a prerelease.** download the app from [releases](https://github.com/kusanalee/somnoire/releases). it supports apple silicon and intel macs running macos 13 or later.

the downloadable build is locally signed, not apple-notarized, so macos may block its first launch. you can also build the app yourself by opening the xcode project and running the somnoire scheme on your mac. building requires xcode with swift 6 support.

## current limits

- tested with the rapid pro p512; other power banks are not verified
- custom artwork upload is unavailable; the official app also restricts artwork in bluetooth mode
- charging and screen controls have been user-tested, but physical charge and discharge cutoffs have not been independently validated
- input direction, dock readings, and every supported macos version have not all been checked on hardware

the local artwork preview remains experimental and cannot upload to the bank. this release does not add cloud connectivity or change the bank's existing ecoflow pairing.

## privacy

somnoire operates locally over bluetooth. it has no analytics or cloud requests and never asks for your password.

only the derived bank credential is stored in keychain. bank selection and preferences stay on your mac. copied diagnostics exclude account ids, credentials, device identities, measurement values, and packet contents. troubleshooting tools are tucked away under advanced settings.

## development

the app uses native macos controls. [build instructions](docs/building.md), protocol research, and validation history live in [docs](docs/). private captures, android packages, and build files are excluded from the repository.

original code is mit licensed. see the license file and third-party notices in this repository for dependency licenses.
