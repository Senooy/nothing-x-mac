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
- The first three bytes are `55 60 01` for replies and most events but `55 20 03` for the head tracking stream:
  validate a frame by its CRC, not by those bytes.

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

#### EQ files (app side, no new command)

The app imports and exports the custom EQ as AutoEq / Equalizer APO text (`Preamp:` plus
`Filter n: ON PK|LSC|HSC Fc <Hz> Gain <dB> Q <q>`), see `EQInterchange.swift`. Filter types map to the band
type byte (`LSC`/`LS`/`LSQ` → 0, `PK` → 1, `HSC`/`HS`/`HSQ` → 2); the result is always 8 bands written with
`F050`, then preset `5`. The file's preamp is **not** written to the profile `gain` field (offset 2 of the
payload): its effect on the firmware is *documented* only, not verified. Per-band gains are limited to ±12 dB.

### Spatial audio — verified (read-back), effect documented as audible

| Cmd | Payload |
|---|---|
| `C04F` | → `[on, headTracking]` |
| `F052` | `[on, headTracking]` |

On, head tracking on and off were all confirmed by read-back. Public notes say the firmware
refuses spatial audio together with bass boost or a non-flat EQ; here a preset write while
spatial audio was on was still accepted and read back, so the app conservatively resets the EQ to
Balanced before enabling spatial audio and disables the EQ controls while it is on.

### Head tracking stream — decoded, scale estimated

`C058` (read, empty payload) starts a stream of `E015` notifications at a fixed ~9.5 Hz (a payload on
`C058` does not change the rate); it runs until the RFCOMM channel closes. It works with the headphone's
own spatial audio off. **These frames use different control bytes: `55 20 03 15 E0 10 00 00 …`** instead of
`55 60 01`, so a parser must not require `60 01` and should rely on the CRC alone.

Payload, 16 bytes, little-endian: three `Int32` orientation words then a `Float32`:

| Offset | Meaning (checked with guided head movements) |
|---|---|
| 0 | pitch, + = looking up |
| 4 | roll, + = right shoulder |
| 8 | yaw, + = turned left |
| 12 | `Float32` "settled" confidence: ~0.6–0.95 when the head is still, 0 while displaced |

The words are absolute orientation (they hold at the turned value). **Yaw is calibrated**: a guided
180° chair rotation made it plateau at ±1040…1070 M, i.e. a half turn is 2³⁰ (1 073 741 824) units
and the range is ±180°. Pitch and roll use an estimated scale of 2⁻²⁹ rad per unit (plausible head ranges);
the app also exposes a sensitivity slider. Yaw drifts by a few degrees per minute (gyro only), so a slow
recentre towards the resting pose is needed. Whether `C058:00` stops the stream is not established.

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

### Device settings — reads seen here, writes documented

Reads were seen on this headphone (current values in the table). **No write below has been tried here yet**,
so every write is *documented*; the app verifies each one with a read-back and reports `[ERROR: …]` when
the value did not change. Reads are repeated about every 30 s.

| Setting | Read | Write | Payload | Status |
|---|---|---|---|---|
| Low latency | `C041` → 1 byte, `01` on / `02` off (reads `02`) | `F040` | `[1]` on, `[2]` off | documented |
| Audio codec | `C029` → 1 byte (reads `00`) | `F01C` | `0` Standard (AAC/SBC), `2` LDAC | documented |
| Dual connection | `C027` → 1 byte (reads `00`) | `F01A` | `[on]` | documented |
| Adaptive ANC | `C055` → 1 byte (reads `01`) | `F059` | `[on]` | documented |
| In-ear detection | `C00E` → `count, (featureId, flag) × count` | `F004` | `[01, 01, on]` = count, feature, value | documented |
| Find my headphone | none | `F002` | `[side, on]`, `side` = `06` (assumed) | documented, side unverified, no read-back |

Notes:

- **Codec**: the firmware ACKs any value 0–3 but only `0` and `2` mean something here (the app shows no
  selection for `1`/`3`). **After a change the headphone drops the RFCOMM link** to renegotiate A2DP; the app
  treats the missing reply as expected, shows "Reconnect after changing", lets `BluetoothLink` reconnect and
  checks the codec once the link is back (a mismatch within 60 s is reported then).
- **Dual connection**: public notes say it is usually exclusive with the hi-res codec. The app shows a hint but
  does not enforce it.
- **Adaptive ANC** (`C055`) is a separate flag from ANC mode `4` ("adaptive" in `C01E`/`F00F`); how the two
  interact is not established.
- **In-ear detection** is feature `01` of the `C00E` table. This headphone reads
  `09 01 00 02 01 07 01 09 01 0A 01 0B 00 0E 01 12 01 15 01`: nine features `01..`, in-ear detection (`01`)
  currently `00`. Only feature `01` is ever written, the other flags are never touched. The meaning of the
  other features is unknown.
- **Find my headphone** can play a **loud sound while worn**. The app asks for a two-step confirmation
  ("Take the headphone off first"), sends `on`, waits 2 s and always sends `off` (also on Stop). `side` `06`
  is inferred from battery/wear/gestures; there is no read to confirm the state, so only the ACK is checked.

## Wired (USB) mode — verified

Plugging in the USB-C cable makes the headphone **drop Bluetooth entirely** (stated on Nothing's support page;
checked here: the classic link cannot be reopened from the Mac and a 25 s BLE scan finds no Nothing device).
The RFCOMM protocol above is therefore unavailable while the cable is in. There is no serial port and no
vendor channel on USB, so there is nothing to talk to.

- USB identity: vendor id `48728` (`0xBE58`, "Nothing Tech"), product id `820` (`0x0334`), product string
  "Nothing Headphone (1)". `USB Serial Number` equals the serial read over Bluetooth (device info key 4).
- Composite device: USB audio (control interface + 2 streaming interfaces) and one HID interface
  (consumer / telephony keys).
- Core Audio lists two devices named "Nothing Headphone (1)" with transport USB: output 2 ch @ 48 kHz and
  input 1 ch @ 48 kHz. In Bluetooth mode the same name has transport Bluetooth (output 44.1 kHz, 16 kHz HFP
  input). macOS does not make the USB device the default output by itself.
- The app matches on the IOKit class `IOUSBHostDevice` with `idVendor = 0xBE58` and a product string containing
  "Headphone" (`USBHeadphoneMonitor`), and finds the output by `kAudioDevicePropertyTransportType ==
  kAudioDeviceTransportTypeUSB` plus the name (`AudioDevices.usbOutputDevice`).

## Seen but not decoded

- `C017`, `C04C`.

### Codec (`C029` / `F01C`) — verified, but not exposed on macOS

`F01C [2]` selects LDAC and `C029` reads it back (`02`), and the link survives the change (observed on this
headphone). It has no audible effect on a Mac, though: macOS only plays SBC and AAC over A2DP, so the output
stayed at 44.1 kHz. The app therefore does not offer it.

### Find my headphone (`F002`) — verified

`F002 [06, 01]` makes the headphone ring (side `06` = the single unit), `F002 [06, 00]` stops it. Verified with
the headphone off the head: it sounds, and the app's 2 s pulse then stops it. There is no read command.

