# Blask Sync (macOS)

A menu bar app that drives Philips Hue lights from screen content and system audio.

**Status:** milestone 1 covers bridge discovery and pairing.

## Requirements

- macOS 14.2+
- Swift 6 toolchain (the Command Line Tools are enough; full Xcode is optional)
- A Hue Bridge v2/Pro with an entertainment area set up in the Hue app

## Build & run

```sh
swift test                      # unit tests
scripts/bundle.sh               # builds build/BlaskSync.app (ad-hoc signed)
open build/BlaskSync.app
```

`swift run` also works for quick iteration. The bundled app is what you'll need once screen
recording and audio permissions come in, because macOS ties those to a bundle ID and signature.

## Layout

| Path | What |
|---|---|
| `Sources/HueKit` | UI-free bridge logic: mDNS + cloud discovery, pairing, CLIP v2, Keychain storage |
| `Sources/BlaskSync` | SwiftUI `MenuBarExtra` app |
| `Resources/Info.plist` | Bundle metadata (LSUIElement, local network usage, Bonjour service) |

## Pairing flow

1. Discovery browses `_hue._tcp` over mDNS (with `discovery.meethue.com` as a fallback). You can also enter an IP.
2. **Pair** POSTs `{"devicetype": "blask-sync#<host>", "generateclientkey": true}` to `/api` every 2 s for 30 s
   while you press the bridge's link button.
3. The returned `username` (the CLIP v2 application key) and `clientkey` (the DTLS PSK for streaming)
   go into the login Keychain under the service `local.blasksync.bridge`.

The bridge's certificate is issued by Signify's private CA. The app accepts it only when its
common name equals the bridge ID.

## Notes

- With only the Command Line Tools installed, SwiftUI macros (`@State`, `#Preview`, `@Entry`) are unavailable
  because the SwiftUI macro plugin ships with Xcode. The code avoids them for now.
