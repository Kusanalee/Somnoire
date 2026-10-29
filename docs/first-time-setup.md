# first-time setup

battery-percentage monitoring in Somnoire 1.0.0 needs no account. full readings and device settings currently need one-time EcoFlow account setup; everyday use then remains local over Bluetooth. account-free full access has not been established for the tested linked P512, rather than proven universally impossible.

## connect for full readings

1. install the official EcoFlow phone app. sign in or create an account using the correct country or region.
2. if your bank is already linked, use its **existing authorizing account**. otherwise complete the bank’s official first-time setup. Somnoire does not provision credentials, replace ownership, unbind, or reset your bank.
3. retrieve the numeric account ID using the browser procedure below.
4. close the official app’s Bluetooth connection. in Somnoire, find and select your bank, choose full readings in general settings, paste **only the numeric ID**, and connect. never paste a password, token, email address, or entire browser response.
5. after connection succeeds, quit and reopen Somnoire to check remembered access. only the derived bank credential is saved in this Mac’s Keychain; the entered ID is cleared after use.

keep the bank awake and nearby. Somnoire uses your selected bank and does not silently switch to another one. in the older v0.11.0 prerelease, use settings → general for setup; it does not include all of the current development version’s onboarding or mode controls.

## finding the numeric ID

this is a **community-documented, region-dependent procedure**, not a guaranteed or newly authenticated end-to-end test. the older upstream website-login-response procedure is flagged as outdated. consult the [retrieval guide and regional updates](https://github.com/rabits/ha-ef-ble/issues/130) if these steps do not match your region.

1. on your Mac, open your regional EcoFlow website.
2. open the browser’s developer tools → network **before** signing in with the same account that authorizes your bank.
3. filter requests for `pages/web/create` and inspect the request payload for numeric `user_id`. reports identify `shopify-na` for the US/Canada and `shopify-eu` for Europe.
4. copy only that numeric value into Somnoire. a website ID is a candidate until your bank accepts it; do not substitute a different shop account or guess IDs.

there is no verified phone-app ID menu documented here. Somnoire does not perform the website login, retrieve the ID itself, or handle your password or login tokens.

## remembered access

bank credentials are local, non-synchronizing Keychain entries. remembered access has been checked across quit/relaunch on the tested bank. switching to percentage-only mode preserves saved access while ending the live session. forget bank removes its saved access from this Mac, without changing the bank’s EcoFlow binding.

Somnoire 1.0.0 uses `io.github.kusanalee.Somnoire`. migrating from older builds may require a normal Keychain authorization prompt or one-time setup again; old data is retained if migration is blocked. the [build guide](building.md) documents this personal-machine transition and signing-key continuity.

[back to Somnoire](../README.md)
