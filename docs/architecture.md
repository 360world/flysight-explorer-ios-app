**English** | [Magyar](architecture.hu.md)

# FlySight Explorer — Technical documentation

iOS app for the FlySight 2 GPS logger: file download over BLE, jump analysis,
HUD display and device configuration.

Platform: iOS 26.5+, SwiftUI. No external dependencies (CoreBluetooth, MapKit
and Swift Charts come with the system).

---

## 1. BLE connection and pairing

This is the most important section: the FlySight's BLE behaviour is
undocumented in several places, and badly handled pairing produces symptoms
that are easy to blame on something else.

### Characteristics

| UUID | Direction | Role |
|---|---|---|
| `00000001-8E22-…-ED19` | device → phone | notifications (`ftPacketOut`) |
| `00000002-8E22-…-ED19` | phone → device | commands (`ftPacketIn`) |
| `00000000-8E22-…-ED19` | device → phone | live GNSS stream |

### ⚠ Pairing is triggered by READING `ftPacketIn`, not by writing it

**This is not documented; it was found by measurement.** If the client only
*writes* to the characteristic, pairing never starts. The connection then
appears to be established — connecting succeeds and services can be
discovered — but without a secure bond.

The correct order is therefore: connect → discover services → **read the
command characteristic** → start the keepalive.

### ⚠ Keepalive: `0xFE` ping every 15 seconds

**Without a ping the device disconnects after 30 seconds.** This is the
device's own timeout, not a BLE-level error.

The ping must start right after pairing has been triggered. It can pause
during a file transfer, because the per-packet `0x12` acknowledgements keep
the connection alive then.

### When the connection is established but pairing is not

- the connection **drops after ~30 seconds** (because of the missing
  keepalive)
- the device **shows up with a different MAC address when you scan again**
- protected operations (file read, config write) get a **`0xF0` NAK**
- so it looks as if every operation needs a "reset" or a fresh config upload
  first

**The changing MAC address is not the cause of the problem but a consequence
of it.** Per the BLE standard, the device uses a *random resolvable private
address* that it rotates roughly every 15 minutes — a privacy feature. During
pairing the two sides exchange the **IRK** (Identity Resolving Key), which
lets the central resolve the changing address and recognise the device.
Without a bond there is no IRK, so the rotating address really does become
unidentifiable.

> Note: the list of symptoms above was derived from the BLE standard and the
> observed device-side timeout; it was not separated symptom by symptom
> through direct measurement.

### Identifying devices

The device must **not be identified by its advertised address**, because that
rotates. On iOS the system doesn't expose the MAC at all; it provides a
stable per-device identifier instead. On Android, the list of bonded devices
is the right starting point.

### Multiple devices

The app keeps track of discovered devices, and each can have a user-defined
nickname. Nicknames only exist inside the app — deleting one restores the
advertised factory name; nothing is written to the device.

One device can be marked as preferred: the app connects to it automatically
and, after a disconnect, tries to reconnect **only to that device**. With
several devices around, it therefore never connects blindly to whichever it
finds first.

---

## 2. File transfer protocol

| Code | Name | | Code | Name |
|---|---|---|---|---|
| `0x02` | readFile | | `0x11` | dirEntry |
| `0x03` | writeFileOpen | | `0x12` | ackFileData |
| `0x05` | listDirectory | | `0xF0` / `0xF1` | NAK / ACK |
| `0x10` | fileData | | `0xFE` / `0xFF` | ping / cancel |

Download sequence:

1. `[0x05][path][0x00]` → list directory; `0x11` replies, empty name = end
2. `[0x02][offset u32 LE][stride u32 LE][path][0x00]` → request the file
3. `[0x10][seq][data]` packets, each acknowledged with `[0x12][seq]`
4. a `0x10` with empty data = end of stream
5. **compare the number of bytes received with the size known from the
   directory listing**

`seq` is a single byte and wraps around every 256 packets. The packet size
depends on the MTU; measured on iOS it is ~242 bytes. A 464 kB TRACK.CSV is
~1920 packets and takes ~17 seconds.

---

## 3. Early bugs in the processing pipeline

Four independent bugs produced the same symptom for a valid file: *"could not
save — recording too short or download incomplete"*. The message is raised at
the end of the pipeline; the actual cause was earlier.

**1. Packet order.** Incoming BLE notifications were processed in
asynchronous tasks whose order is not guaranteed. Reordered packets were
dropped by the sequence check — without an acknowledgement or a log entry.
Fix: packets are processed synchronously in arrival order; a repeated packet
is re-acknowledged, a real gap in the sequence aborts the transfer, and the
size is checked at the end.

**2. Parsing blocked saving.** Saving parsed the CSV first, and if parsing
failed, the raw file wasn't written to disk either. Fix: the raw CSV is
always written; parsing only provides metadata.

**3. CR line endings.** The FlySight uses `\r`; splitting on `\n` saw the
271 kB file as a single line → zero samples → "too short". Fix: all three
line-ending styles (`\n`, `\r`, `\r\n`) are handled. The same bug also
existed when reading CONFIG.TXT.

**4. Index serialisation.** The dates in the index were written and read in
different formats, so decoding failed on every launch and the logbook came up
empty. Fix: the same format in both directions; if the index is corrupt, the
logbook is rebuilt from the files on disk.

What made the cause hard to find was that the error message contained no
diagnostic data and the BLE log was not reachable from the UI. After a
persistent log was added, the cause was visible from a single entry:

```
[SAVE] Parse FAILED — 271615 bytes, 1 lines — $GNSS:0 ISO:0 numeric:0 other:1
```

---

## 4. Diagnostic log

Written to a file (`Documents/flysight-diagnostics.log`), survives app
restarts, rotates after 4000 lines and can be shared from the UI. It is always
in English.

Categories: `BLE`, `DL`, `SAVE`, `READ`, `SCAN`, `IMPORT`, `APP`. Save and
read entries include the first 8 lines of the file — that immediately shows
the real format.

---

## 5. Data model

A track is a series of GNSS samples (time, position, altitude, velocity
vector, accuracy, satellite count), plus derived data: the estimated ground
level (the 5th percentile of the altitudes), the exit/deployment/landing
indices, and the cumulative distance per sample. The latter is computed once
at load time, because recomputing it at runtime would mean thousands of
distance calculations per frame.

**Supported CSV formats:** FlySight 2 (`$FLYS`/`$VAR`/`$COL`/`$UNIT`/`$DATA`
header + `$GNSS,<ISO time>,…`), FlySight 1 (no prefix, 12 columns, ISO time),
and an older export (10 columns, seconds offset). Fractional seconds may have
2 digits (`.00Z`), so they are padded to 3 digits before parsing.

Threshold: 6 usable samples. Below that there is no analysis, but the file is
still saved.

**Phase detection:** exit = first sample with a descent rate above 60 km/h;
deployment = after that, the descent rate stays below 40 km/h; landing =
less than 20 m above ground and below 15 km/h.

---

## 6. Storage

```
Documents/
├── tracks/
│   ├── index.json
│   └── 20260812_090828__26-08-02_11-10-24_TRACK.CSV
└── flysight-diagnostics.log
```

Duplicate detection is based on the recording's path on the device: the same
recording is never added twice. Import uses the system file picker.
`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are enabled.

---

## 7. Non-trivial UI solutions

**Scrolling vs. dragging on a chart.** In SwiftUI, any continuous gesture on
the chart captures the touch as soon as it starts, after which scrolling stops
working — this is true for all three variants of the native gesture API. The
solution is a UIKit-based pan recogniser that doesn't block the scroll
gesture: after a few pixels of movement it decides the direction, hands
vertical movement to scrolling, and disables scrolling until the end of the
gesture for horizontal movement. The two gestures are therefore mutually
exclusive.

**Handle offset.** The visible strip of a selection handle is 5 pt wide, but
its hit area is 30 pt; the strip sits in the middle of the hit area, so the
earlier offset shifted the marker 12.5 pt to the right of the selection's real
edge. In addition, the gesture was measured in the handle's own coordinate
space instead of the bar's, so the two end positions were unreachable. Both
are fixed.

**Protection against bad data.** For a ground recording without a jump, the
altitude profile was drawn without normalisation or clipping and ran outside
its frame. Fixed: values are clamped to 0…1, the drawing is clipped,
non-finite values are filtered out, the chart's time axis is at least 1 s
wide, and every index is clamped to the actual bounds of the samples.

**Playback.** The code that watches the cursor also stopped playback when
playback itself moved the cursor. Fix: stopping only happens on a real user
gesture. The timer also now runs in a run-loop mode that keeps firing during
interaction.

---

## 8. Localisation

A dictionary of 112 keys, Hungarian and English. The configurator's texts
(9 groups, 31 fields, help texts, pickers) are not key-based; they live in the
schema as bilingual values and are resolved at display time. The `CONFIG.TXT`
keys are byte-identical; the file format is not touched.

On first launch the app uses the phone's language (Hungarian if that is the
preferred language, English otherwise) until the user picks one in Settings;
the choice is stored under `app_language`. The texts iOS itself shows — the
Bluetooth permission prompt and the app name — are translated in
`InfoPlist.xcstrings`.

---

## 9. Open questions

Each can be settled with a short measurement; none has been done yet:

- does the FlySight offer the standard Battery Service (`0x180F`)?
- is there useful data in the advertising packet (battery, logging state)?
- exactly how many parallel BLE connections does it allow?
- can the free storage be read? (used storage can be computed from the
  directory listing)

Each needs the service and characteristic list written to the log.

---

## 10. Flutter migration — measurement results

`flutter_spike/` (not part of this repository) was a throwaway experiment to
check whether `flutter_blue_plus` handles this protocol flawlessly.

**iOS, 464,548 bytes, 3 runs:** all three byte-exact (1920 packets,
17.0–18.1 s), 0 ordering errors, parse 4640 samples. ~242 bytes/packet,
~26 kB/s — the same as the native performance. The parser's 12 unit tests
passed in Dart, including CR line endings.

**Android measurement: not done yet.** The decision can't be made from one
platform; Android's BLE stack is the other common point of failure (MTU
negotiation, write-without-response congestion, vendor differences).

`flutter_blue_plus` 2.x is free for personal, non-profit and educational use
and paid for commercial use.
