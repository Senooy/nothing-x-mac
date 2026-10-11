# Nothing Headphone (1) — control protocol (RFCOMM "NT LINK")

Established by probing a real headphone (firmware 1.0.1.81) and cross-checking public
references: [`nothing.js`](https://www.pragmaticaudio.com/bluetooth/js/nothing.js) (Pragmatic Audio),
[`chukfinley/nada`](https://github.com/chukfinley/nada) (`docs/PROTOCOL.md`, recovered from the
official app) and [`ezvk/nadamas`](https://github.com/ezvk/nadamas) (per-model profile for the
Headphone (1)).

Each entry is tagged:

- **verified** — written/read on this headphone and the read-back matched
- **behaviour unverified** — the device accepts and reports it, but its audible/physical effect
  was not confirmed (the firmware acknowledges commands it then ignores, so an ACK proves nothing)
- **documented** — from a public reference, not tried here

## Transport

- Bluetooth Classic **RFCOMM**, SDP service "NT LINK", UUID
  `AEAC4A03-DFF5-498F-843A-34487CF133EB` (channel 15 on this headphone — always resolve it
  through SDP, never hard-code it).
- `/dev/cu.NothingHeadphone1` belongs to a *different* SPP service and stays silent: do not use it.
- On macOS use `IOBluetooth` (`performSDPQuery` → `openRFCOMMChannelAsync`). The process must be a
  real `.app` bundle with `NSBluetoothAlwaysUsageDescription`; a bare binary started from a
  terminal is killed by TCC because the *responsible process* is the terminal's parent app.

## Frame

```
55 60 01 | cmd (LE16) | len (LE16) | opId | payload[len] | crc (LE16)
```

- `crc` is CRC16-Modbus (reflected polynomial `0xA001`, init `0xFFFF`) over everything before it.
- `opId` is a host-side counter echoed in the reply; match replies by `opId`, not by arrival order.

## Command families

| Family | Direction | Example |
|---|---|---|
| `C0xx` | read (host → headphone) | `C01E` read ANC |
| `40xx` | reply to `C0xx` (same opId) | `401E` |
| `F0xx` | write | `F00F` set ANC |
| `70xx` | write ACK, payload `00` or empty = OK (same opId) | `700F` |
| `E0xx` | unsolicited notification (opId 0) | `E003` ANC changed |

The reply command is the request with bit 15 cleared (`C007` → `4007`, `F00F` → `700F`).
No activation handshake is needed on this headphone.

## Commands

### Device info — verified

| Cmd | Payload | Reply |
|---|---|---|
| `C042` | — | firmware, ASCII (`1.0.1.81`) |
| `C006` | — | `count`, then CSV lines `6,<key>,<value>`: key 2 = firmware, 4 = serial, 6 = MAC (reversed) |
| `C007` | — | `01 06 <level>`: low 7 bits = battery %, bit 7 = charging |

### Noise control — verified

| Cmd | Payload | Notes |
|---|---|---|
| `C01E` | — | reply `01 <mode> 00 02 <last ANC level> 00` |
| `F00F` | `01 <mode> 00` | also pushes `E003 01 <mode> 00` |

Modes: `1` ANC level 1, `2` ANC level 2, `3` ANC level 3, `4` adaptive, `5` off, `7` transparency
(`6` and other values are rejected). Choosing 1–4 also stores the "last ANC level".
Level names (High / Mid / Low) follow the Nothing convention and were not checked by ear.

### Equalizer

| Cmd | Payload | Status |
|---|---|---|
| `C01F` | — → `<preset>` | verified |
| `F010` | `<preset> 00` | verified (accepted values 0–5; 6–15 are rejected and read back as 0) |
| `C04D` | `00` → custom EQ | verified |
| `F050` | same layout as the `C04D` reply | verified read-back; effect unverified |

Device presets: `0` Balanced and `5` Custom curve are used by the app. `1`–`3` are accepted but their
meaning is **not confirmed on this headphone** (Nothing/CMF family order: bass, treble, voice; a CMF
Headphone Pro source lists voice, treble, bass) and their curves cannot be read back, so the app
does not use them: it defines More bass / More treble / Voice as explicit 8-band curves and writes
them to the custom slot (`F050` + preset `5`). `4` is accepted but unidentified.

Custom EQ layout (little-endian): `profile u8, nBands u8, gain f32, [type u8, gain f32, freq f32, Q f32] × nBands`.
Type 0 = low shelf, 1 = peaking, 2 = high shelf. Default: 8 bands at 55/110/220/440/1320/3300/6600/13200 Hz,
Q = 1, 0 dB. Only profile `0` exists; profiles 1–3 read back as zeros and 4+ do not answer.
Selecting the custom curve is done with preset `5`; `F050` alone does not change the active preset.

### Spatial audio — verified (read-back), effect documented as audible

| Cmd | Payload |
|---|---|
| `C04F` | → `[on, headTracking]` |
| `F052` | `[on, headTracking]` |

On, head tracking on and off were all confirmed by read-back. Public notes say the firmware
refuses spatial audio together with bass boost or a non-flat EQ; here a preset write while
spatial audio was on was still accepted and read back, so the app conservatively resets the EQ to
Balanced before enabling spatial audio and disables the EQ controls while it is on.

### Bass boost — documented

`C04E` → `[enabled, level]` (reads `00 06` here), `F051` `[enabled, level]`. Not exposed in the UI;
the app only turns it off before enabling spatial audio.

### Gestures — read verified, write behaviour unverified

| Cmd | Payload |
|---|---|
| `C018` | → `count`, then `[side, control, gesture, action] × count` |
| `F003` | `01 side control gesture action` |

This headphone reports three rows, all with `side = 06` (single unit):

| control | gesture | action | Interpretation |
|---|---|---|---|
| `01` | `07` | `16` | Roller · triple press → previous track |
| `0A` | `01` | `0B` | Button · press → noise control |
| `0A` | `07` | `01` | Button · triple press → none |

Action codes `01` none, `08` next, `09` play/pause, `16` previous come from other models (measured via
AVRCP there); `0B` = noise control is inferred. Writing a row is acknowledged and read back
correctly here, and was restored afterwards, **but whether the physical control then behaves
differently has not been confirmed** (on an Ear (3a) such writes were reported to change nothing).
The app therefore marks gestures as experimental and keeps the first table it ever read so it can
restore it.

## Seen but not decoded

- `E015` (16 bytes, opId 0): continuous sensor stream, seen while spatial audio / head tracking was
  being exercised during a `C000–C0FF` read sweep (probably head tracking).
- `C017`, `C00E` (feature table of `id, flag` pairs), `C041` (low latency: `01` on, `02` off),
  `C027` (dual connection), `C029` (codec), `C055` (adaptive ANC), `C04C`.
  Writes: `F040`, `F01A`, `F01C`, `F059` according to the public references — none were tried here.
