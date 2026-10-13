<h1 align="center">NOTHING&nbsp;X&nbsp;for&nbsp;Mac</h1>

<p align="center">
  A lightweight, native macOS companion for the <b>Nothing Headphone (1)</b>.<br/>
  Noise control, spatial audio, equalizer and battery — without reaching for your phone.
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS%2014.2%2B-000000?style=flat-square">
  <img alt="swift" src="https://img.shields.io/badge/Swift-SwiftUI-D71921?style=flat-square">
  <img alt="status" src="https://img.shields.io/badge/status-work%20in%20progress-555555?style=flat-square">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-000000?style=flat-square">
</p>

> **Unofficial.** This project is not affiliated with, endorsed by, or sponsored by
> Nothing Technology Limited. "Nothing" and "Nothing X" are trademarks of their respective owner.
> The protocol was worked out by probing a headphone I own, and from public references.

---

## Why

Nothing X is only available on iOS and Android. If your headphones live on your Mac all day,
changing the ANC mode or the EQ means picking up a phone. This app talks to the headphones
directly from macOS.

## Features

| | Status |
|---|---|
| Battery level, charging state, firmware, serial number | working |
| Noise control: ANC (High / Mid / Low / Adaptive), Transparency, Off | working |
| Spatial audio on the headphone, with head tracking | working |
| **Mac anchor**: the app renders the Mac's audio as binaural sound fixed in front of you and follows your head, like AirPods on a Mac | working, in testing |
| Equalizer presets (Balanced, More bass, More treble, Voice) shown as 8-band curves — the bars move when you pick one | working |
| Custom 8-band equalizer, saved locally | working |
| EQ files: import an AutoEq / Equalizer APO `ParametricEQ.txt` (or a `GraphicEQ:` line) into the custom EQ, export the current curve | working, not yet tried on the headphone |
| Gestures: view and remap the customizable controls, restore the original table | experimental |
| Menu bar item: battery and quick noise-control switching | working |
| Notifications: low battery (20 % or 10 %) and headphone connected, configured in Settings (⌘,) | working |
| English UI, French when macOS is set to French | working |
| Device settings: low latency, codec (Standard / LDAC), dual connection, adaptive ANC, in-ear detection | experimental (reads verified, writes untested) |
| Find my headphone (short pulse, asks you to take the headphone off first) | experimental |

Settings changed from the headphone's own buttons are picked up within a few seconds, and the app
reconnects by itself when the headphone comes back.

## Stack

- **Swift + SwiftUI**, native macOS app — a few MB, no web runtime.
- **IOBluetooth** for the Bluetooth Classic RFCOMM link.
- Design language inspired by Nothing: black canvas, mono labels, dot-matrix display, a single red accent.

## How it talks to the headphones

The headphones expose a vendor RFCOMM service named **NT LINK**
(UUID `AEAC4A03-DFF5-498F-843A-34487CF133EB`). The app finds it through SDP, opens the
channel and exchanges small framed packets:

```
55 60 01 | cmd (LE16) | len (LE16) | opId | payload | CRC16 (LE)
```

The full, evolving reference — frame layout, command families, ANC modes, EQ payloads, spatial
audio, gestures, and what was verified versus only documented — lives in
[`Protocol.md`](Protocol.md). If you own another Nothing device and want to help map it, that
document is the place to start.

## Download

Grab `NothingX-<version>.dmg` from the [latest release](../../releases/latest), open it and drag
**Nothing X.app** to the Applications folder. It is a universal build (Apple Silicon and Intel).

The app is signed with a Developer ID certificate and notarized by Apple, so it opens normally.

## Requirements

- macOS 14.2 or later (built with Xcode 27 / Swift 6.4)
- A Nothing Headphone (1), paired and connected to your Mac
- Bluetooth permission for the app, plus System Audio Recording for the Mac anchor mode (macOS asks on first use)

## Build

```bash
./build.sh
open "build/Nothing X.app"
```

`build.sh` compiles a universal (arm64 + x86_64) Swift package and assembles an ad-hoc signed `build/Nothing X.app`
(set `SIGN_IDENTITY` to sign with another identity). It has to be a real app bundle: macOS only lets a process
use Bluetooth if its `Info.plist` carries a Bluetooth usage description. The app is intentionally **not
sandboxed** (RFCOMM access).

`release.sh` produces the signed, notarized and stapled DMG; see the header of the script for the one-time setup
(a Developer ID certificate and a `notarytool` keychain profile).

Unit tests (EQ file parsing): `swift test`.

To force English on a French system:
`open -n "build/Nothing X.app" --args -AppleLanguages "(en)"`.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/NothingX/Protocol.swift` | frame codec, CRC16, command ids, ANC / EQ / spatial / gesture models |
| `Sources/NothingX/BluetoothLink.swift` | IOBluetooth transport: finds the headphone, resolves the channel via SDP, reconnects |
| `Sources/NothingX/EQInterchange.swift`, `EQFileActions.swift` | AutoEq / Equalizer APO import and export (pure parser + serializer, and the Import / Export buttons) |
| `Tests/NothingXTests/` | unit tests for the EQ file parser (`swift test`) |
| `Sources/NothingX/HeadphoneModel.swift` | observable state, request/response matching, settings logic |
| `Sources/NothingX/ContentView.swift`, `Theme.swift`, `BandSlider.swift` | Nothing-style UI |
| `Sources/NothingX/NotificationService.swift`, `NotificationRules.swift` | notification permission and posting; pure threshold / hysteresis rules |
| `Sources/NothingX/SettingsView.swift` | Settings window (⌘,), one view per section |
| `Resources/` | `Info.plist`, `en` / `fr` localizations, app icon and menu bar glyph |
| `tools/make-icons.swift` | regenerates `AppIcon.icns` and the menu bar glyph (the "Dot X" icon) |

## EQ files

**Import…** / **Export…** under the equalizer read and write the plain-text format used by
[AutoEq](https://github.com/jaakkopasanen/AutoEq) and Equalizer APO (`ParametricEQ.txt`):

```
Preamp: -6.2 dB
Filter 1: ON PK Fc 31 Hz Gain 2.4 dB Q 1.41
Filter 2: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70
```

- `PK` is a peaking filter, `LSC` / `LS` / `LSQ` a low shelf, `HSC` / `HS` / `HSQ` a high shelf. `OFF` filters
  are skipped; other types (low/high pass, notch...) are ignored with a warning. Decimal commas, missing
  units, `BW Oct` instead of `Q` and a `GraphicEQ: 25 -3; 40 -2.5; ...` line (sampled at the 8 band centres
  in log frequency) are accepted.
- The headphone has exactly **8 bands**. With fewer filters the rest are 0 dB bands at the default
  frequencies; with more, the 8 with the largest |gain| are kept and the warning says how many were dropped.
  Gains are limited to ±12 dB (reported).
- **Preamp is not applied**: the custom EQ payload has a global gain field, but what the firmware does with
  it is unverified, so the preamp line is only reported. Keep an eye on clipping if a file boosts a lot.
- Importing sends the curve like a manual edit (written, read back, switches to Custom). Note that the
  shelf type, frequency and Q of the imported bands stay on the headphone; the preset buttons and
  **Reset to zero** only change gains.

## Mac anchor

Pick **Mac anchor** under Spatial audio. The app captures everything the Mac plays (Core Audio process
tap, muted at the source while the app runs), spatializes it with HRTF as two virtual speakers in front
of you, and keeps them fixed while your head turns, using the headphone's motion sensor (~10 Hz,
smoothed and extrapolated). The headphone's own spatial processing is switched off in this mode so the
effect is not applied twice. Look at the Mac and press **Recenter** (also in the menu bar) if the image
drifts. Yaw drift is also cancelled slowly by itself, but only while your head is still and close to the
Mac direction, so looking at another screen never drags the anchor along. If the app quits or crashes, the normal system audio
comes back on its own.

## Notifications and Settings

Open **Settings** with ⌘, or from the menu bar item.

- **Low battery**: on by default. Choose 20 % or 10 %. The alert fires once when the level reaches the
  threshold while the headphone is not charging. It arms again only after the battery climbs more than
  10 points above the threshold or the headphone is charged, so it never repeats on every reading.
- **Headphone connected**: off by default. Fires when the headphone connects, but not for the connection
  made in the first 8 seconds after the app launches.
- The app never asks for notification permission by itself at launch. Permission is requested when you
  switch an alert on (or from the onboarding). If macOS has it blocked, Settings says so and offers a
  button that opens System Settings > Notifications.
- Choices are stored in `UserDefaults` (`notify.connected`, `notify.lowBattery`,
  `notify.lowBattery.threshold`). Notifications need the packaged `.app`; `swift run` has none.

## Known limits

- ANC level names (High / Mid / Low) follow the Nothing convention and were not confirmed by ear.
- Mac anchor adds a little latency on top of Bluetooth (video may be slightly late), the sensor only reports
  ~10 times a second, and the angle scale is an estimate (use the sensitivity slider).
- Development builds signed ad hoc ask for Bluetooth permission again after every rebuild; sign with a
  stable identity (`SIGN_IDENTITY="..." ./build.sh`) to avoid that.
- Bluetooth permission: the app checks the macOS Bluetooth permission before touching IOBluetooth, so the
  window opens right away. Until you answer the system prompt (which can appear on another display) it shows
  "Waiting for Bluetooth permission…"; if access was denied it shows "Bluetooth access denied" with a link to
  Privacy & Security › Bluetooth. Granting access later is picked up without restarting the app. To see the
  prompt again: `tccutil reset Bluetooth dev.younes.NothingX`.
- The headphone does not expose the curves of its built-in presets, so the app defines its own
  (see `EQPreset` in `Protocol.swift`) and sends them through the custom EQ slot.
- Gesture rewrites are accepted and read back by the headphone, but their effect on the physical
  controls has not been verified.

## Roadmap

- [x] Decode the transport and framing
- [x] ANC, EQ preset and custom EQ read/write
- [x] Core library: transport, protocol, model
- [x] Main window (Nothing-style UI)
- [x] Menu bar control
- [x] Custom EQ editor
- [x] Spatial audio and gestures
- [ ] Verify gesture remapping on the physical controls
- [ ] Low latency, dual connection, codec, in-ear detection
- [x] App icon (Dot X) and a first release build
- [x] Developer ID signing and notarization

## Disclaimer

Writing to a device you did not intend to modify can change its settings. This software is
provided as is, without warranty. Use it on your own hardware, at your own risk.

## License

[MIT](LICENSE)
