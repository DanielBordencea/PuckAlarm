# PuckAlarm

An iOS alarm that will not let go until you physically walk to a dock and scan it.

The alarm rings through Silent and Focus like the system Clock app does, because it is a
real alarm scheduled with **AlarmKit** (iOS 26). Stopping it opens a *wake guard*: unless
the paired NFC puck is scanned, the alarm re-arms one minute later, and keeps re-arming.
The only clean exit is holding the phone against the tag.

---

## Status

Honest summary of what has actually been verified, as of 2026-08-23.

| | |
|---|---|
| ✅ Builds | Both targets, **Swift 6 language mode**, zero warnings |
| ✅ Runs | iOS 26.5 Simulator — alarms fire, the re-arm loop works, history records wake-ups |
| ✅ Verified | Alarm scheduling, bypass → 60s retry, scan resolution, one-shot retirement, corrupt-store recovery, and the gate presenting on a cold launch with a wake-up already in progress |
| ⚠️ Not verified | **Never run on physical hardware.** Needs an Apple ID in Xcode for a signing identity. |
| ⚠️ Not verified | **Real NFC has never been exercised.** Requires a paid developer account (see below); all scans so far used the simulated path. |
| ❌ Missing | **No tests.** The `WakeEnforcer` state machine is the thing that most needs them. |
| ⚠️ Partial | Accessibility: labels and Dynamic Type are in, but nothing has been audited with VoiceOver actually running. |

A full graded audit lives in
[`.agents/research/2026-08-22-tech-reportcard.md`](.agents/research/2026-08-22-tech-reportcard.md),
including the defects that running the app exposed and how they were fixed.

---

## What is native and what is not

Worth being precise about, because it decides what the app can and cannot look like:

| Piece | Who draws it |
|---|---|
| "Ready to Scan" sheet with the checkmark | **iOS.** Core NFC shows it whenever an `NFCTagReaderSession` is open. The app only sets the line underneath — `"Alarm Stopped"`. |
| Full-screen alarm alert when it fires | **iOS.** AlarmKit renders it from `AlarmPresentation.Alert`. The title, tint and the secondary button ("Scan Puck") are configurable; the layout is not. |
| Lock Screen / Dynamic Island banner | **This app.** `PuckAlarmLiveActivity` — plain SwiftUI. |
| The wake-up screen with the big clock and "Scan Puck" | **This app.** `ScanGateView`, shown full-screen and non-dismissible while a guard is open. |

---

## How the enforcement actually works

iOS does not let a third-party alarm remove the system **Stop** button, and no entitlement
exists that would. So "you must scan" is enforced *after* the button rather than at it:

1. The alarm fires. `WakeEnforcer.reconcile` sees it in `.alerting` and opens a `WakeGuard`.
2. If Stop is pressed, `StopWithoutScanIntent` runs **inside the app's process** — that is
   what `LiveActivityIntent` guarantees — increments the bypass count and schedules a
   one-shot retry 60 seconds out.
3. The retry carries the *original* alarm's metadata, so the screen keeps reading 09:00
   rather than the retry time.
4. `ScanGateView` covers the app for as long as the guard is open.
5. A matching tag calls `WakeEnforcer.resolveByScan`, which stops the alerting alarm,
   cancels the pending retry, and closes the guard.

**There is no escape hatch.** *"I can't find my puck"* silences the current ring and hides
the screen so the phone is usable, and that is all it does: it counts as a bypass, arms the
same 60-second retry, and the alarm comes back. Pressing the system Stop button does
exactly the same thing. Scanning the paired tag is the only action that closes a wake-up.

Be deliberate about this before you rely on it. If the tag is genuinely lost or broken, the
alarm will keep firing every minute indefinitely, and the only way out is deleting the app.
That is the intended behaviour of a commitment device, not an oversight — but it is worth
knowing before you put the tag somewhere you might not be able to reach.

If the retry itself cannot be armed, the app says so on the wake screen instead of failing
quietly. The user is awake at that moment and can set a backup alarm; ten minutes later
they cannot.

---

## Requirements

- **iOS 26.1+** on a physical iPhone. AlarmKit needs 26.0; the alert initialiser without
  the deprecated `stopButton` needs 26.1.
- **Xcode 26** with the iOS 26 SDK **and the iOS platform installed**
  (Xcode ▸ Settings ▸ Components) — the SDK alone is not enough to build or run.
- **A paid Apple Developer Program membership** for real NFC. The
  `com.apple.developer.nfc.readersession.formats` entitlement cannot be signed with a free
  Apple ID. See *Running without a paid account*.
- **iPhone XS or newer** for the tag reader.
- **Any NFC tag.** Nothing is written to it; the app matches on the tag's built-in UID, so
  a blank sticker straight out of the bag works.

## Getting started

```bash
open PuckAlarm.xcodeproj
```

Add your Apple ID under Xcode ▸ Settings ▸ Accounts, set the team on both targets, then
run on a device.

1. **Settings ▸ Puck ▸ Pair Puck** — hold the phone against the tag.
2. **+** — add an alarm, leave *Require puck scan* on.
3. Put the tag somewhere that forces you out of bed. The kitchen, not the nightstand.

## Running without a paid account

The project ships with `USE_NFC_ENTITLEMENT = False` in `generate_project.py`, so it
signs with a free Apple ID out of the box. Turn on **Settings ▸ Testing ▸ Simulate puck
scans** — it bypasses Core NFC entirely, so the whole loop can be exercised in the
Simulator or on a free-account build. It defaults to on wherever
`NFCTagReaderSession.readingAvailable` is false.

Flip `USE_NFC_ENTITLEMENT` to `True` and re-run the generator once you have a paid
account.

## Buying a tag

NTAG213 stickers are the cheapest thing that works (a couple of RON each, sold in packs).
NTAG215 or NTAG216 are the same technology with more memory, which this app does not use.
Anything advertised as "NFC sticker, NTAG21x, 13.56 MHz" is fine. Avoid anything sold as
125 kHz / RFID — that is a different radio and iPhones cannot read it.

For something dock-shaped rather than a sticker, any NFC keyfob or "NFC puck" works
identically.

---

## Notable design choices

- **No App Group.** The widget renders from `AlarmAttributes`, and the intents run in the
  app process, so a single-process store is enough. App Groups are also unavailable on a
  free Apple ID, so avoiding them removes a second signing blocker.
- **No snooze button.** The retry loop *is* the snooze, and it costs a scan to end.
- **UID matching, not NDEF.** Nothing has to be written to the tag, so any sticker works.
  Be clear-eyed about what this buys: a UID is not a secret, and commodity NFC emulators
  clone one in seconds. That is acceptable here because the adversary is the person who
  installed the app — this is a commitment device, not an access-control system. Someone
  determined enough to emulate their own puck at 6am has already won.
- **Scheduling failures are never swallowed.** Every path goes through
  `AlarmScheduler.schedule(_:recordingIn:)`; if AlarmKit refuses, the switch reverts, an
  alert fires, and the row carries a red badge. A list that says "on" while nothing is
  scheduled is the one bug this app cannot ship with — and it is what made a real
  duplicate-id defect visible during testing instead of silently breaking every launch.
- **Corrupt saved data is preserved, not overwritten.** A decode failure stashes the raw
  bytes under `<key>.corrupt` and raises a banner, instead of silently presenting an empty
  alarm list. A `schemaVersion` key is written alongside.
- **The puck lives in the Keychain**, not `UserDefaults` — not because a UID is secret,
  but because it is the one value that decides whether the alarm stops.

---

## Project layout

```
PuckAlarm/
├── Model/      AlarmItem, PuckAlarmMetadata (metadata is shared with the widget)
├── Store/      AlarmStore — alarms, wake guard, history; PuckKeychain — the paired puck
├── Alarm/      AlarmScheduler (all AlarmKit calls), WakeEnforcer (the re-arm loop)
├── Intents/    StopWithoutScanIntent, OpenScanIntent, AppRouter
├── NFC/        PuckReader — Core NFC, app target only
├── Views/      RootView, AlarmListView, AlarmEditorView, ScanGateView, SettingsView
└── Design/     Theme
PuckAlarmWidget/
└── PuckAlarmLiveActivity — Lock Screen and Dynamic Island
```

## Working on it

```bash
./typecheck.sh          # both targets against the iOS SDK — no simulator or signing needed
./typecheck.sh 5        # same, in Swift 5 language mode
python3 generate_project.py
```

`generate_project.py` is the source of truth for the Xcode project. **Add a source file to
the lists at the top and re-run it rather than hand-editing `project.pbxproj`** — anything
changed in Xcode's project editor, signing included, is discarded on the next regeneration.
`SHARED_SOURCES` is compiled into both targets.

`typecheck.sh` reads its file lists straight out of the generator, so it cannot drift out
of sync with what actually gets compiled. An earlier version kept its own copy of the list
and reported "clean" while a newly added file was not being checked at all.

## Known limitations

- Scanning the puck stops **every** alerting alarm, not just the one being enforced. Only
  matters if two alarms ring at once.
- `AlarmEditorView` reads the store singleton in `init` to decide whether the alarm is new,
  because `@Environment` is not available there yet.
- The 60-second retry interval is not user-configurable.

## Licence

No licence chosen yet — all rights reserved by default.
