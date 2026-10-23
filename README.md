# Blask Sync (macOS)

A menu bar app that drives Philips Hue lights from screen content and system audio.

**Status:** bridge discovery, pairing, manual light control, and screen sync over the Entertainment streaming API.

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

## Using it

- **Menu bar:** if no bridge is paired, **Pair Bridge…** opens Settings. Once paired, the panel shows the
  default area with **Start Sync / Stop Sync** (screen sync) and **Manual Control…**. The icon (a monitor with a sparkle) fills in
  while the lights are driven.
- **Settings (⌘,):**
  - **General:** bridge discovery, pairing and forgetting, and the default entertainment area.
  - **Screen:** display, intensity, brightness and the mapping editor. The live preview runs while this tab is visible.
- **Manual Control window:** opening it switches the lights to manual colors and starts streaming if needed.
  Closing it returns to screen sync if that was running, otherwise it releases the lights.

The sync session belongs to the app, not to a window, so sync keeps running with all windows closed.

## Streaming

1. Starting sends `PUT /clip/v2/resource/entertainment_configuration/{id}` with `{"action": "start"}`,
   then opens a DTLS 1.2 PSK session (`TLS_PSK_WITH_AES_128_GCM_SHA256`) to UDP port 2100. The PSK identity
   is the application key and the key is the hex-decoded client key.
2. Each channel's RGB color goes out as a HueStream v2 message at 50 Hz (`HueKit/EntertainmentStream.swift`).
3. Stopping, or any graceful quit (menu, logout, shutdown, relaunch), sends `{"action": "stop"}` first, with a 2 s cap. The lights then return to their previous state.
4. While streaming or capturing, the app holds a latency-critical activity so App Nap doesn't throttle its timers.

## Screen sync

Configured in **Settings → Screen**, started from the menu bar:

- **Capture.** ScreenCaptureKit streams the chosen display at 160 px wide and up to 60 fps
  (`SyncCore/ScreenCapture.swift`). Blask Sync's own windows are left out, so the editor doesn't sample itself.
- **Mapping.** Each channel samples a screen region. Strip segments (solid, joined in physical order) and
  lamps (dashed) can be dragged and resized over a live preview. Mappings are saved per area.
- **Colors.** `ColorExtractor` averages each region. `ScreenSyncEngine` eases toward those colors at 50 Hz
  through two exponential stages, which gives an ease-in/ease-out curve instead of a jolt. **Intensity** sets the
  average delay (subtle 0.6 s … extreme 0.1 s); even Extreme covers the usual gap between captured frames.
  The easing continues while the screen is static and no new frames arrive.
- **Adjustments.** **Saturation** pushes the averaged colors (which drift toward gray) toward vivid ones,
  keeping hue and brightness. **Minimum brightness** keeps the lights glowing faintly in dark scenes.

The first time, macOS asks for **Screen Recording** permission, and the app has to be relaunched after
you allow it. `scripts/bundle.sh` signs with an "Apple Development" certificate when one exists.
With ad-hoc signing, the permission has to be granted again after every rebuild.

The bridge's certificate is issued by Signify's private CA. The app accepts it only when its
common name equals the bridge ID.

## App icon

`scripts/make-icon.swift` draws the icon with CoreGraphics. `scripts/make-icns.sh` renders it at every
macOS size into `Resources/AppIcon.icns`, which `scripts/bundle.sh` copies into the app.
