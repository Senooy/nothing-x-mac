# Nothing Headphone (1) — protocole de contrôle (RFCOMM « NT LINK »)

Établi par sondage du casque réel (firmware 1.0.1.81) + référence publique
[`nothing.js`](https://www.pragmaticaudio.com/bluetooth/js/nothing.js) (Pragmatic Audio).

## Transport

- Bluetooth Classic **RFCOMM**, service SDP « NT LINK », UUID
  `AEAC4A03-DFF5-498F-843A-34487CF133EB` (canal 15 sur ce casque — toujours le
  résoudre via SDP, ne jamais le coder en dur).
- ⚠️ `/dev/cu.NothingHeadphone1` correspond à *un autre* service SPP (silencieux) : ne pas l'utiliser.
- Sur macOS : `IOBluetooth` (`performSDPQuery` → `openRFCOMMChannelAsync`).
  L'app doit être un vrai `.app` avec `NSBluetoothAlwaysUsageDescription`
  (un binaire lancé depuis un terminal est tué par TCC).

## Trame

```
55 60 01 | cmd (LE16) | len (LE16) | opId | payload[len] | crc (LE16)
```

- `crc` = CRC16 Modbus (poly réfléchi `0xA001`, init `0xFFFF`) sur tout ce qui précède.
- `opId` : compteur d'opération incrémental côté hôte, renvoyé dans la réponse.

## Familles de commandes

| Famille | Sens | Exemple |
|---|---|---|
| `C0xx` | lecture (hôte → casque) | `C01E` lire ANC |
| `40xx` | réponse à `C0xx` (même opId) | `401E` |
| `F0xx` | écriture | `F00F` régler ANC |
| `70xx` | accusé d'écriture, payload `00` = OK (même opId) | `700F` |
| `E0xx` | notification spontanée (opId 0) | `E003` ANC changé |

Rapprocher les réponses par **opId**, pas par ordre d'arrivée.

## Commandes confirmées

| Cmd | Payload | Réponse / sens |
|---|---|---|
| `C042` | — | `40 42` : firmware ASCII (`1.0.1.81`) |
| `C006` | — | `4006` : lignes CSV `6,1,` / `6,2,<fw>` / `6,4,<série>` / `6,6,<MAC inversée>` |
| `C007` | — | `4007` : `01 06 <batterie %>` |
| `C01E` | — | `401E` : `01 <mode> 00 02 <dernier niveau ANC> 00` |
| `F00F` | `01 <mode> 00` | règle l'ANC ; notif `E003 01 <mode> 00` |
| `C01F` | — | `401F` : preset EQ (1 octet) |
| `F010` | `<preset> 00` | règle le preset EQ |
| `C04D` | `00` | `404D` : `profil, nBandes, gain f32, [type u8, gain f32, freq f32, Q f32] × nBandes` (little-endian) |
| `F050` (61520) | `profil, nBandes, gain f32, bandes…` | écrit l'EQ personnalisé (d'après nothing.js, **non testé ici**) |

### Modes ANC (`F00F`)

| Valeur | Mode |
|---|---|
| 1 / 2 / 3 | ANC niveau 1 / 2 / 3 (haut / moyen / bas selon la convention Nothing, **à vérifier à l'oreille**) |
| 4 | ANC adaptatif |
| 5 | Désactivé |
| 7 | Transparence |
| 6 | refusé (pas d'effet) |

Choisir 1–4 mémorise aussi le « dernier niveau ANC » (5ᵉ octet de `401E`).

### EQ

Presets `F010` : 0 = équilibré (par défaut), 1 = testé OK (autres valeurs non cartographiées).
EQ personnalisé : 8 bandes, type 0 = low-shelf, 1 = peaking, 2 = high-shelf ;
par défaut 55/110/220/440/1320/3300/6600/13200 Hz, Q = 1, gain = 0.

## Observé mais non décodé

- `E015` (16 octets, opId 0) : flux continu de capteurs, déclenché pendant un balayage `C000–C0FF`
  (absent sur connexion neuve) — probablement suivi de tête / audio spatial.
- `C018`, `C017`, `C00E` (table de fonctionnalités `id,bool`), `C041`, `C04C`, `C04E`, etc.
  Aucune écriture `F0xx` autre que `F00F`/`F010` n'a été tentée.
