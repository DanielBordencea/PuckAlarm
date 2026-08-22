# PuckAlarm — Tech Report Card

**Date:** 2026-08-22 · **Timeline:** Planning phase (Architecture and Testing double-weighted)
**Focus:** Full analysis, Performance emphasized

---

## 1. Executive Summary

Clean, small, well-layered codebase with no force unwraps, no legacy concurrency, and no
network or secret-handling surface to get wrong. Two things pull the grade down hard: the
alarm-scheduling calls swallow their errors, so a scheduling failure shows in the UI as a
working alarm — the worst possible failure mode for this product — and there are no tests
at all, despite the re-arm state machine being the one piece that genuinely needs them.

## 2. CLAUDE.md Summary

No `CLAUDE.md` exists at the project root, so no project-specific instructions were
applied. (The user's global `~/.claude/CLAUDE.md` is tooling configuration, not project
context, and was not treated as such.)

## 3. Project Metrics

```
Swift Files: 17 | LOC: ~1,948 | Targets: 2 (app + widget extension)
Architecture: layered SwiftUI + @Observable | Persistence: Codable → UserDefaults
Unit Tests: 0 | UI Tests: 0 | Test Framework: none
Frameworks: AlarmKit, ActivityKit, AppIntents, CoreNFC, WidgetKit, SwiftUI
Largest file: ScanGateView.swift (268 lines) — well under the 500-line threshold
```

## 4. Grade Summary Line

```
Overall: C+ (Arch A- | Quality C+ | Perf B+ | Concurrency B | Security B | A11y D+ | Testing F | UI B | Data C)
```

## 5. Trend Comparison

No prior report found — this is the first grade for this project.

---

## 6. Per-Category Grades

### Architecture: A-
Clear layering with one owner per concern and no God objects.

**Strengths:**
- Every AlarmKit call is funneled through `AlarmScheduler`, so the presentation
  (title, tint, buttons) is defined once.
- `WakeEnforcer` holds the entire enforcement state machine and takes its store by
  injection (`init(store:)`), so the hard logic is isolated and testable.
- The shared-vs-app-only source split is declared explicitly in `generate_project.py`
  rather than implied by target membership in a pbxproj nobody reads.
- The decision to avoid an App Group is documented at the point of impact
  (`AlarmStore.swift:6-11`) with the reasoning, not just the fact.

**Findings:**
- `ScanGateView` reaches for the `AlarmStore.shared` singleton in 6 places
  (lines 196, 202, 227, 232, 244) while every other view injects it via
  `@Environment`. Inconsistent, and it makes the one screen that matters most
  impossible to drive from a test store.

### Code Quality: C+
Spotless on the usual metrics, undone by one swallowed-error pattern in the wrong place.

**Strengths:**
- Zero force casts, zero force unwraps, zero `TODO`/`FIXME`/`HACK` markers.
- Doc comments consistently explain *why* rather than restating the signature.

**Findings:**
- `try? await schedule(...)` at `AlarmScheduler.swift:102`, `AlarmListView.swift:113`,
  and `AlarmEditorView.swift:94` discards the scheduling result. AlarmKit defines
  `AlarmManager.AlarmError.maximumLimitReached`, so this is a reachable path, not a
  hypothetical one. **CONFIRMED — see Issue #1.**
- `AlarmStore.swift:173` swallows decode failures. **CONFIRMED — see Issue #4.**

**Classified as INTENTIONAL (not listed as issues):** `try?` around
`AlarmManager.cancel`/`stop` (`AlarmScheduler.swift:74, 78, 85`) — these throw on an
unknown id, which is a normal race when the alarm has already ended; and
`Task.sleep` in `ScanGateView.swift:263`, where the only error is cancellation.

### Performance: B+
Nothing here burns battery, which is most of the job for an alarm app.

**Strengths:**
- No `Timer`, no polling loop, no location, no main-thread file I/O. The app does not
  run in the background at all — AlarmKit does the waking.
- Persistence is small JSON blobs written on mutation.

**Findings:**
- The re-arm loop is unbounded. Each bypass schedules a fresh AlarmKit alarm; a user who
  never scans will eventually hit `maximumLimitReached`, at which point
  `WakeEnforcer.swift:127` clears `pendingFollowUpID` and the enforcement loop silently
  stops. **CONFIRMED — see Issue #3.**

**Noted, not a finding:** `AlarmStore` re-encodes the whole array on every `didSet`.
At an alarm list's realistic size this is free; it would matter at thousands of records.

### Concurrency: B
Modern and consistent, but the project is pinned to Swift 5 language mode by a trivial fix.

**Strengths:**
- `@MainActor` on every stateful type; verified by reading the full attribute stack on
  each declaration, not a one-line window.
- Both closure capture lists use `[weak self]` (`PuckReader.swift:124`,
  `WakeEnforcer.swift:50`).
- Zero `DispatchQueue.main` calls and zero `nonisolated` escapes.
- `startObserving`/`stopObserving` manage the `alarmUpdates` task explicitly rather than
  leaking it.

**Findings:**
- Compiling with `-swift-version 6` produces 7 errors, all of the same shape:
  `static var` on the `AppIntent` conformances in `AlarmIntents.swift`
  (lines 11, 12, 15, 37, 38, 39, 43). **CONFIRMED — see Issue #2.**

### Security: B
Almost no attack surface, and one honest limitation worth stating rather than hiding.

**Strengths:**
- No network code at all. No hardcoded secrets, no `http://`, no logging of any kind.
- Nothing sensitive is persisted — the alarm list and a tag UID.

**Findings:**
- The puck UID lives unencrypted in `UserDefaults` (`AlarmStore.swift:158`). Low real
  risk, but it is the app's only authentication factor and the Keychain is its correct
  home. **See Issue #6.**
- UID matching is defeatable. Cheap NFC emulators clone a UID in seconds. This matters
  more than usual here because the threat model is *the user themselves* — a commitment
  device's adversary is the person who installed it. **See Issue #7.**

### Accessibility: D+
The weakest category, and unusually consequential for this specific app.

**Findings:**
- Zero `accessibilityLabel` in the codebase. Four icon-only controls have no label at
  all: `AlarmListView.swift:31` (gearshape), `:39` (plus), and the two status glyphs in
  `ScanGateView`. **CONFIRMED — see Issue #5.**
- Every font in `Theme.swift` is `.system(size:)` with no `ScaledMetric` and no
  `dynamicTypeSize` support anywhere. Body text does not scale at all. The 76pt clock
  has `minimumScaleFactor(0.6)`, which handles overflow but not user preference.
- Zero `accessibilityIdentifier`, which will block UI tests before they are written.

An alarm screen is used half-asleep, in the dark, by someone who may not have their
glasses on. Dynamic Type is not a nice-to-have on this screen.

### Testing: F
No test target, no test files, no test framework.

`WakeEnforcer` is pure logic over an injectable store and already has the seam
(`init(store:)`) — the bypass → re-arm → scan → resolve cycle could be driven
deterministically without a device. Nothing is blocking these tests except their absence.
**CONFIRMED — see Issue #8.**

### UI/UX: B

**Strengths:**
- No deprecated APIs, no platform conditionals to drift.
- Loading and failure states are modeled explicitly as `ScanGateView.Status`, not
  improvised booleans.
- The "I can't find my puck" escape hatch is the right call — a broken tag should not
  brick a phone — and it is recorded as a bypass rather than a wake-up.

**Findings:**
- No haptic feedback on scan success. On a screen used in the dark, this is the cheapest
  possible usability win.
- `AlarmEditorView.body` is 75 lines — at the threshold, not over it. Noted, not flagged.

### Data/Persistence: C

**Strengths:**
- `Codable` throughout with explicit, namespaced keys; history capped at 100 records.

**Findings:**
- No schema versioning. Changing the shape of `AlarmItem` makes `try? decode` at
  `AlarmStore.swift:173` return `nil`, which **silently erases every alarm the user has
  set**. The failure is invisible: the app opens to an empty list. **CONFIRMED — see
  Issue #4.**

---

## 7. Issue Rating Table

| # | Finding | Urgency | Risk: Fix | Risk: No Fix | ROI | Blast Radius | Fix Effort |
|---|---------|---------|-----------|--------------|-----|--------------|------------|
| 1 | Alarm scheduling errors swallowed by `try?` at `AlarmScheduler.swift:102`, `AlarmListView.swift:113`, `AlarmEditorView.swift:94` — UI shows the alarm as on while AlarmKit has nothing scheduled | 🔴 Critical | ⚪ Low | 🔴 Critical | 🟠 Excellent | 🟡 High | Small |
| 2 | 7 Swift 6 errors: `static var` on `AppIntent` conformances, `AlarmIntents.swift:11,12,15,37,38,39,43` | 🟡 High | ⚪ Low | 🟡 High | 🟠 Excellent | ⚪ Low | Trivial |
| 3 | Re-arm loop dies silently when AlarmKit returns `maximumLimitReached`; `WakeEnforcer.swift:127` clears state without telling anyone | 🟡 High | ⚪ Low | 🟡 High | 🟠 Excellent | 🟢 Medium | Small |
| 4 | No schema versioning — a model change silently erases all alarms via `try? decode` at `AlarmStore.swift:173` | 🟡 High | ⚪ Low | 🟡 High | 🟠 Excellent | 🟡 High | Small |
| 5 | Zero accessibility labels and no Dynamic Type support anywhere | 🟢 Medium | ⚪ Low | 🟢 Medium | 🟢 Good | 🟢 Medium | Medium |
| 6 | Puck UID stored in `UserDefaults` rather than Keychain (`AlarmStore.swift:158`) | ⚪ Low | ⚪ Low | ⚪ Low | 🟡 Marginal | ⚪ Low | Small |
| 7 | UID matching is cloneable with commodity NFC emulators — a documentation gap more than a code one | ⚪ Low | ⚪ Low | 🟢 Medium | 🟢 Good | ⚪ Low | Trivial |
| 8 | No tests; the `WakeEnforcer` bypass/re-arm cycle is unverified despite already having an injection seam | 🟡 High | ⚪ Low | 🟡 High | 🟠 Excellent | 🟡 High | Medium |
| 9 | `ScanGateView` bypasses `@Environment` for `AlarmStore.shared` in 6 places, breaking the pattern every other view follows | ⚪ Low | ⚪ Low | ⚪ Low | 🟢 Good | ⚪ Low | Small |

---

## 8. Next Steps

**Immediate (this week):**
- Issue #1 — surface scheduling failures. An alarm app that lies about whether an alarm
  is set has no other feature worth discussing.
- Issue #2 — `static var` → `static let`, then move the project to Swift 6 language mode
  while the codebase is still 2k lines.

**Short-term (this month):**
- Issue #4 — add a schema version key and a migration path before the model shape ever
  changes; retrofitting this after the first silent wipe is much harder.
- Issue #3 — surface a persistent in-app warning when the retry cannot be armed.
- Issue #8 — a test target covering `WakeEnforcer`; the seam already exists.

**Medium-term (this quarter):**
- Issue #5 — accessibility labels and Dynamic Type, prioritising `ScanGateView`.
- Issues #6, #7, #9 — Keychain, an honest note in the README about UID cloning, and
  bringing `ScanGateView` onto `@Environment`.

---

## 9. Resolution Log — 2026-08-22

Issues #1–#4 were fixed in the same session as the audit. Everything below was
re-verified by type-checking both targets against the iOS 26.5 SDK.

| # | Status | What changed |
|---|--------|--------------|
| 1 | ✅ Fixed | New `AlarmScheduler.schedule(_:recordingIn:)` is now the only scheduling path; it records the outcome in `AlarmStore.schedulingFailures`. Toggling an alarm on reverts the switch and raises an alert if AlarmKit refuses. The editor waits for acceptance before dismissing, and the list shows a red badge on any alarm that failed to schedule. `AlarmManager.AlarmError.maximumLimitReached` is translated into a message with a remedy. |
| 2 | ✅ Fixed | All seven `static var` declarations in `AlarmIntents.swift` are now `static let`. Two further Swift 6 problems surfaced once those cleared and were also fixed: `AlarmRow.onToggle` is now `@MainActor`-isolated so it satisfies `Binding`'s `@Sendable` setter, and `PuckReader` is `@unchecked Sendable` with its cross-queue state behind an `NSLock` and the non-Sendable session capture spelled out as `nonisolated(unsafe)`. **The project now builds in Swift 6 language mode** (`SWIFT_VERSION = 6.0`) with zero warnings in both targets. |
| 3 | ✅ Fixed | `WakeEnforcer.enforcementWarning` is set when the retry cannot be armed, and `ScanGateView` renders it as a red banner while the user is still awake enough to set a backup. |
| 4 | ✅ Fixed | `AlarmStore` now writes a `schemaVersion` key and reports a mismatch. Decode failures no longer vanish: the raw bytes are preserved under `<key>.corrupt` so the next write cannot destroy them, and `storeWarning` surfaces a dismissible banner on the alarm list. |

**Grades after the fixes** (re-derived, same weights, Planning timeline):

```
Overall: B- (Arch A- | Quality A- | Perf A- | Concurrency A | Security B | A11y D+ | Testing F | UI B | Data B+)
```

Testing (F) and Accessibility (D+) are untouched and are now the only things holding the
overall grade down — the code-correctness categories are clean. Issues #5–#9 remain open.

---

## 10. Second Pass — 2026-08-22, after running the app

The app was built and run in the iOS 26.5 Simulator. Running it surfaced two defects that
no amount of static analysis had caught, plus a compiler crash caused by one of the
Section 9 fixes. Issues #5, #6 and #9 were closed in the same pass.

### Defects found by running, not by reading

| Finding | Evidence | Fix |
|---|---|---|
| **`syncAll` re-scheduled ids AlarmKit already held.** Every launch, and every edit of an existing alarm, failed to schedule. | `mobiletimerd` log: `Not scheduling an alarm with a duplicate ID` → `AlarmServiceError(code: .invalidInput)`, surfaced in the UI as "com.apple.AlarmKit.Alarm error 0". | `schedule(_:)` cancels the previous registration first. `syncAll` skips ids AlarmKit already holds, because cancelling one that is *currently ringing* would silently end the wake-up — and "Scan Puck" cold-launches the app in exactly that state. |
| **One-shot alarms never retired.** AlarmKit drops a `.never` alarm after it fires (`Removing alarm as it will never fire again`), but the store kept `isEnabled = true`, so the next launch quietly re-armed it for the following day. | Log line above, plus the row staying switched on after firing. | `WakeEnforcer.retireIfOneShot` turns the switch off on resolution, matching the system Clock. Verified visually: the row is now greyed with the toggle off. |
| **swift-frontend crashed in IRGen.** Introduced by the Section 9 Swift 6 fix, not present before it. | `While emitting IR SIL function "@$sSbScA_pSgIeAghyg_SbIeAghn_TR"` — the reabstraction thunk for `@isolated(any) @Sendable (Bool) -> ()`, i.e. the `@MainActor` closure handed to `Binding`'s setter. | `AlarmRow` drives the switch from `@State` plus `onChange` instead of a custom `Binding`. No thunk, no warning, and less indirection than before. |
| **No app icon.** The Home Screen showed a blank tile. | Screenshot. | Generated a 1024pt icon into the asset catalog. |
| **Settings button hidden in the "…" overflow.** iOS 26 folds a lone `.topBarLeading` button away when the title is `.inlineLarge`. | Screenshot. | Both toolbar buttons are now `.topBarTrailing`. |
| **The type-check script had a hand-maintained file list** and reported "clean" while `PuckKeychain.swift` was not being checked at all — the same class of silent-pass failure this audit's own scan discipline warns about. | Adding a file produced "clean", then the real build failed. | Replaced by `typecheck.sh`, which reads the file lists out of `generate_project.py`. |

### Audit issues closed

- **#5 Accessibility** — labels on every icon-only control, decorative glyphs marked
  `accessibilityHidden`, and the type ramp moved from fixed `.system(size:)` to text
  styles. The wake-up clock scales via `@ScaledMetric(relativeTo: .largeTitle)`. Not yet
  audited with VoiceOver running, and there are still no `accessibilityIdentifier`s.
- **#6 Keychain** — the paired puck moved to `PuckKeychain`
  (`kSecAttrAccessibleAfterFirstUnlock`, so a scan works before the first unlock after a
  reboot), with a migration for pucks paired by an earlier build. Verified: after launch,
  `puckalarm.puck` is gone from the container plist.
- **#9 `ScanGateView` singleton access** — all five reads now go through the injected
  `@Environment(AlarmStore.self)`.

### What running the app confirmed works

- AlarmKit fires under the Simulator; the alert appears and the app is launched by it.
- The re-arm loop: after Stop, a retry alarm was scheduled 44 seconds later.
- `AlarmStore.history` recorded four wake-ups — three resolved by scan, one bypass.
- Fix #4 is live: `puckalarm.schemaVersion = 1` is present in the container plist.
- Fix #1 is live: the scheduling failure appeared as a red badge on the row, which is how
  the duplicate-id bug became visible at all.

### Grades after the second pass

```
Overall: B- (Arch A | Quality A- | Perf A- | Concurrency A | Security A- | A11y B- | Testing F | UI B+ | Data A-)
```

Testing is now the only category below a B, and with Planning-phase double weighting it
alone accounts for the gap between B- and A-. **Issue #8 is the entire remaining agenda.**
