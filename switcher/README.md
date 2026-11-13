# Switcher

A small macOS app that hands the desk over to another computer in one go:

- switches the **Logitech MX Keys** and **MX Master 4** (Bluetooth) to another Easy-Switch channel,
- switches the external **monitor** to another input over DDC/CI.

It is separate from Blask Sync and is not part of the Swift package or its CI.

## Build and install

```sh
switcher/build.sh
```

This builds `MXSwitch.app` (ad-hoc signed) and installs it to `~/Applications`. The first time it runs, allow
**Bluetooth** when macOS asks. No other permission is needed.

Because the app is ad-hoc signed, macOS treats every rebuild as a new app and may ask for Bluetooth again.

## Use

Open **MXSwitch** from Spotlight or Finder (or bind it to a hotkey with a Shortcuts "Open App" action).
By default it switches the monitor to input 17 and both devices to channel 1. Nothing appears on success.

Options, passed with `open ~/Applications/MXSwitch.app --args …`:

| Option           | Meaning                                         |
| ---------------- | ----------------------------------------------- |
| `--host N`       | Easy-Switch channel to switch to (default 1)    |
| `--input N`      | Monitor input to switch to (default 17)         |
| `--no-monitor`   | Switch only the keyboard and mouse              |
| `--monitor-only` | Switch only the monitor                         |
| `--dry-run`      | Only report current channels and input          |

It checks every device first and switches nothing if any of them fails. Results are written to
`~/Library/Logs/MXSwitch.log`; a dialog shows them on failure or with `--dry-run`.

## How it works

- **Keyboard and mouse**: HID++ 2.0 feature `0x1814` (Change Host), sent over Logitech's own BLE GATT
  characteristic (`00010001-0000-1000-8000-011f2000046d`). Frames are 18 bytes: feature index, function/software
  id, parameters. macOS refuses HID output reports to keyboards, so the IOHID route is only a fallback (and needs
  Input Monitoring).
- **Monitor**: DDC/CI VCP `0x60` (input source) through the private `IOAVService` I2C functions on Apple Silicon,
  the same approach as [m1ddc](https://github.com/waydabber/m1ddc).
