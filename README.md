<h1 align="center">NOTHING&nbsp;X&nbsp;for&nbsp;Mac</h1>

<p align="center">
  A lightweight, native macOS companion for the <b>Nothing Headphone (1)</b>.<br/>
  Noise control, spatial audio, equalizer and battery — without reaching for your phone.
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-000000?style=flat-square">
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
| Spatial audio, with head tracking | working |
| Equalizer presets (Balanced, More bass, More treble, Voice) shown as 8-band curves — the bars move when you pick one | working |
| Custom 8-band equalizer, saved locally | working |
| Gestures: view and remap the customizable controls, restore the original table | experimental |
| Menu bar item: battery and quick noise-control switching | working |
| English UI, French when macOS is set to French | working |
| Low-latency mode, dual connection, codec, in-ear detection | not yet mapped |

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

## Requirements

- macOS 14 or later (built with Xcode 27 / Swift 6.4)
- A Nothing Headphone (1), paired and connected to your Mac
- Bluetooth permission for the app (macOS asks on first launch)

## Build

```bash
./build.sh
open "build/Nothing X.app"
```

`build.sh` compiles the Swift package and assembles an ad-hoc signed `build/Nothing X.app`. It has
to be a real app bundle: macOS only lets a process use Bluetooth if its `Info.plist` carries a
Bluetooth usage description. The app is intentionally **not sandboxed** (RFCOMM access), so it is
meant to be built and run locally.

To force English on a French system:
`open -n "build/Nothing X.app" --args -AppleLanguages "(en)"`.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/NothingX/Protocol.swift` | frame codec, CRC16, command ids, ANC / EQ / spatial / gesture models |
| `Sources/NothingX/BluetoothLink.swift` | IOBluetooth transport: finds the headphone, resolves the channel via SDP, reconnects |
| `Sources/NothingX/HeadphoneModel.swift` | observable state, request/response matching, settings logic |
| `Sources/NothingX/ContentView.swift`, `Theme.swift`, `BandSlider.swift` | Nothing-style UI |
| `Resources/` | `Info.plist` and `en` / `fr` localizations |

## Known limits

- ANC level names (High / Mid / Low) follow the Nothing convention and were not confirmed by ear.
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
- [ ] App icon and signed release builds

## Disclaimer

Writing to a device you did not intend to modify can change its settings. This software is
provided as is, without warranty. Use it on your own hardware, at your own risk.

## License

[MIT](LICENSE)
