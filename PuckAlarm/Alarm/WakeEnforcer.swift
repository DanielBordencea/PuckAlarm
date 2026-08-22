import AlarmKit
import Foundation
import Observation

/// The part that makes the scan mandatory.
///
/// iOS does not let a third-party alarm remove the system Stop button, so "you must scan"
/// cannot be enforced at the button. It is enforced *after* the button instead: stopping
/// without a scan opens a `WakeGuard`, and every open guard re-arms the alarm one minute
/// later. The loop only ends when `resolveByScan` is called with the paired puck.
@MainActor
@Observable
final class WakeEnforcer {
    static let shared = WakeEnforcer()

    private let store: AlarmStore

    /// Set briefly around a programmatic stop so our own `AlarmManager.stop` call cannot be
    /// mistaken for the user pressing Stop.
    private var suppressStopHandlingUntil: Date = .distantPast

    /// Non-nil when the retry could not be armed. The whole product is the promise that
    /// the alarm comes back; if that promise cannot be kept, the user has to be told
    /// while they are still awake enough to set a backup.
    private(set) var enforcementWarning: String?

    private var updatesTask: Task<Void, Never>?

    /// `AlarmStore.shared` is main-actor isolated, so it cannot be a default argument —
    /// default arguments are evaluated in a nonisolated context.
    convenience init() {
        self.init(store: .shared)
    }

    init(store: AlarmStore) {
        self.store = store
    }

    /// Whether the scan screen should be on screen.
    ///
    /// Note this is *not* the same as "the wake-up is over". A bypass hides the screen for
    /// a minute so the phone is usable, but `store.activeGuard` stays set the whole time —
    /// the alarm is coming back.
    var isGateVisible: Bool {
        store.activeGuard?.isGateVisible ?? false
    }

    var activeGuard: WakeGuard? {
        store.activeGuard
    }

    // MARK: - Observing AlarmKit

    /// Starts watching for alarms entering `.alerting` so a guard exists from the moment
    /// the alarm rings, not only once Stop is pressed.
    func startObserving() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                guard let self else { return }
                self.reconcile(with: alarms)
            }
        }
    }

    func stopObserving() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// Called at launch and whenever AlarmKit reports a change. Opens a guard for any
    /// alarm that is currently alerting and is configured to require a scan.
    func reconcile(with alarms: [Alarm]? = nil) {
        let alarms = alarms ?? AlarmScheduler.alarms
        let alerting = alarms.filter { $0.state == .alerting }

        // An open guard plus something ringing means the retry has landed: end the
        // deferral so the scan screen comes back with the noise. This is the event that
        // makes "the alarm returns every minute" visible in the UI, rather than relying
        // on a timer.
        if store.activeGuard != nil {
            if !alerting.isEmpty, store.activeGuard?.deferredUntil != nil {
                store.updateGuard { $0.deferredUntil = nil }
            }
            return
        }

        guard !alerting.isEmpty else { return }

        // Prefer an alerting alarm we recognise; a retry alarm has an id the store does
        // not know, in which case there would already be a guard, so this is the original.
        guard let item = alerting.compactMap({ store.alarm(id: $0.id) }).first,
              item.requiresPuckScan
        else { return }

        store.beginGuard(
            WakeGuard(
                originAlarmID: item.id,
                label: item.label,
                displayHour: item.hour,
                displayMinute: item.minute,
                firedAt: Date(),
                bypassCount: 0,
                pendingFollowUpID: nil
            )
        )
    }

    // MARK: - Bypass

    /// Invoked by `StopWithoutScanIntent` when the user presses the system Stop button.
    /// Opens the guard if this is the first bypass, then arms the retry.
    func handleStopPressed(originAlarmID: UUID) async {
        guard Date() >= suppressStopHandlingUntil else { return }

        if store.activeGuard == nil {
            guard let item = store.alarm(id: originAlarmID), item.requiresPuckScan else { return }
            store.beginGuard(
                WakeGuard(
                    originAlarmID: item.id,
                    label: item.label,
                    displayHour: item.hour,
                    displayMinute: item.minute,
                    firedAt: Date(),
                    bypassCount: 0,
                    pendingFollowUpID: nil
                )
            )
        }

        await bypass()
    }

    /// "I can't find my puck". Silences the current ring and lets go of the screen so the
    /// phone is usable — and that is all it does. The wake-up stays open, the retry is
    /// armed, and the alarm comes back in a minute. It keeps coming back until the puck is
    /// scanned; there is no other way out by design.
    func deferWithoutScan() async {
        AlarmScheduler.stopAlerting()
        await bypass()
    }

    /// One bypass: count it, replace any retry already in flight, and hide the screen until
    /// the alarm rings again.
    private func bypass() async {
        guard var wakeGuard = store.activeGuard else { return }

        // A retry may already be in flight if the user hammered Stop; replace it rather
        // than stacking alarms.
        if let existing = wakeGuard.pendingFollowUpID {
            AlarmScheduler.cancel(id: existing)
        }

        wakeGuard.bypassCount += 1
        store.updateGuard { $0.bypassCount = wakeGuard.bypassCount }

        do {
            let interval = store.retryInterval
            let followUpID = try await AlarmScheduler.scheduleFollowUp(
                for: wakeGuard,
                after: interval
            )
            store.updateGuard {
                $0.pendingFollowUpID = followUpID
                $0.deferredUntil = Date().addingTimeInterval(interval)
            }
            enforcementWarning = nil
        } catch {
            // The guard stays open and visible: if the retry could not be armed, hiding the
            // screen would leave nothing at all holding the user to the scan.
            store.updateGuard {
                $0.pendingFollowUpID = nil
                $0.deferredUntil = nil
            }
            enforcementWarning =
                "The alarm couldn't be re-armed: \(AlarmScheduler.describe(error)) "
                + "It will not come back on its own."
        }
    }

    // MARK: - Resolution

    /// The only way out: the paired puck was scanned.
    func resolveByScan() {
        guard let wakeGuard = store.activeGuard else { return }
        suppressStopHandlingUntil = Date().addingTimeInterval(5)
        enforcementWarning = nil
        AlarmScheduler.stopEverything(for: wakeGuard)
        store.resolveGuard(scanned: true)
        retireIfOneShot(wakeGuard.originAlarmID)
    }

    /// A non-repeating alarm is spent once it has gone off. AlarmKit drops it on its own
    /// ("Removing alarm as it will never fire again"), so without this the switch would
    /// stay on and the next launch would quietly re-arm it for tomorrow — which is not
    /// what "Never" means, and not what the system Clock does.
    private func retireIfOneShot(_ alarmID: UUID) {
        guard let item = store.alarm(id: alarmID), item.repeatDays.isEmpty else { return }
        store.setEnabled(false, for: alarmID)
        AlarmScheduler.cancel(id: alarmID)
    }
}
