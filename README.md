# Blask Sync (macOS)

A menu bar app that drives Philips Hue lights from screen content and system audio.

**Status:** bridge discovery, pairing, and manual light control over the Entertainment streaming API.

## Requirements

- macOS 14.2+
- Xcode 26+ (the Command Line Tools alone lack the SwiftUI macro plugin)
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

## Manual light control

Choosing **Control…** next to an entertainment area in the menu opens the Light Control window:

1. **Start Streaming** sends `PUT /clip/v2/resource/entertainment_configuration/{id}` with `{"action": "start"}`,
   then opens a DTLS 1.2 PSK session (`TLS_PSK_WITH_AES_128_GCM_SHA256`) to UDP port 2100. The PSK identity
   is the application key and the key is the hex-decoded client key.
2. Each channel's RGB color goes out as a HueStream v2 message at 50 Hz (`HueKit/EntertainmentStream.swift`).
3. **Stop**, closing the window, or quitting sends `{"action": "stop"}`. The lights then return to their previous state.

The bridge's certificate is issued by Signify's private CA. The app accepts it only when its
common name equals the bridge ID.
