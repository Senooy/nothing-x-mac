<h1 align="center">NOTHING&nbsp;X&nbsp;for&nbsp;Mac</h1>

<p align="center">
  A lightweight, native macOS companion for the <b>Nothing Headphone (1)</b>.<br/>
  Noise control, equalizer and battery — without reaching for your phone.
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS-000000?style=flat-square">
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
| Battery level, firmware, device info | protocol decoded |
| Noise control: Off · Transparency · ANC (levels) · Adaptive | protocol decoded |
| EQ presets | protocol decoded |
| 8-band custom parametric EQ | read decoded, write per public reference |
| Menu bar app | planned |
| Gestures, spatial audio, low-latency mode | not yet mapped |

## Stack

- **Swift + SwiftUI**, native macOS app — a few MB, no web runtime.
- **IOBluetooth** for the Bluetooth Classic RFCOMM link.
- Design language inspired by Nothing: monochrome, Space Grotesk / Space Mono / Doto, a single red accent.

## How it talks to the headphones

The headphones expose a vendor RFCOMM service named **NT LINK**
(UUID `AEAC4A03-DFF5-498F-843A-34487CF133EB`). The app finds it through SDP, opens the
channel and exchanges small framed packets:

```
55 60 01 | cmd (LE16) | len (LE16) | opId | payload | CRC16 (LE)
```

The full, evolving reference — frame layout, command families, ANC modes, EQ payloads — lives in
[`Protocol.md`](Protocol.md). If you own another Nothing device and want to help map it, that
document is the place to start.

## Requirements

- macOS (built with Xcode 27 / Swift 6.4)
- A Nothing Headphone (1), paired with your Mac
- Bluetooth permission for the app

## Build

Coming with the first runnable version. The app is intentionally **not sandboxed**
(RFCOMM access), so it is meant to be built and run locally.

## Roadmap

- [x] Decode the transport and framing
- [x] ANC and EQ preset read/write
- [ ] Core library: transport, protocol, model
- [ ] Main window (Nothing-style UI)
- [ ] Menu bar control
- [ ] Custom EQ editor
- [ ] Map gestures and remaining toggles

## Disclaimer

Writing to a device you did not intend to modify can change its settings. This software is
provided as is, without warranty. Use it on your own hardware, at your own risk.

## License

[MIT](LICENSE)
