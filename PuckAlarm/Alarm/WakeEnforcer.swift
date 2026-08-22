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

    /// True while a wake-up is unresolved. The UI uses this to present the scan screen and
    /// refuse to be dismissed.
    var isGuardActive: Bool {
        store.activeGuard != nil
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
        guard store.activeGuard == nil else { return }

        let alerting = alarms.filter { $0.state == .alerting }
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

        guard var wakeGuard = store.activeGuard else { return }

        // A retry may already be in flight if the user hammered Stop; replace it rather
        // than stacking alarms.
        if let existing = wakeGuard.pendingFollowUpID {
            AlarmScheduler.cancel(id: existing)
        }

        wakeGuard.bypassCount += 1
        store.updateGuard { $0.bypassCount = wakeGuard.bypassCount }

        do {
            let followUpID = try await AlarmScheduler.scheduleFollowUp(for: wakeGuard)
            store.updateGuard { $0.pendingFollowUpID = followUpID }
            enforcementWarning = nil
        } catch {
            // The guard stays open, so the in-app scan screen still blocks and the next
            // scheduled occurrence still fires — but the one-minute retry is gone, which
            // is the part the user is relying on. Say so instead of failing quietly.
            store.updateGuard { $0.pendingFollowUpID = nil }
            enforcementWarning =
                "The alarm couldn't be re-armed: \(AlarmScheduler.describe(error)) "
                + "It will not come back on its own."
        }
    }

    // MARK: - Resolution

    /// The only clean way out: the paired puck was scanned.
    func resolveByScan() {
        resolve(scanned: true)
    }

    /// Escape hatch for a lost or broken puck. Recorded as a bypass, not as a wake-up.
    func resolveWithoutScan() {
        resolve(scanned: false)
    }

    private func resolve(scanned: Bool) {
        guard let wakeGuard = store.activeGuard else { return }
        suppressStopHandlingUntil = Date().addingTimeInterval(5)
        enforcementWarning = nil
        AlarmScheduler.stopEverything(for: wakeGuard)
        store.resolveGuard(scanned: scanned)
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
