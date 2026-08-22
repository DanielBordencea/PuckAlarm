import AlarmKit
import AppIntents
import Foundation
import SwiftUI

/// Thin wrapper over `AlarmManager`. Owns every call into AlarmKit so the presentation —
/// title, buttons, tint — is defined in exactly one place.
@MainActor
enum AlarmScheduler {
    /// How long after a bypass the alarm comes back. Short enough to be relentless, long
    /// enough that the system alert has actually dismissed before the next one arrives.
    static let retryInterval: TimeInterval = 60

    // MARK: - Authorization

    static var authorizationState: AlarmManager.AuthorizationState {
        AlarmManager.shared.authorizationState
    }

    @discardableResult
    static func requestAuthorization() async throws -> AlarmManager.AuthorizationState {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return try await AlarmManager.shared.requestAuthorization()
        @unknown default:
            return try await AlarmManager.shared.requestAuthorization()
        }
    }

    // MARK: - Scheduling

    /// Schedules (or reschedules) the user's alarm under its own id.
    static func schedule(_ item: AlarmItem) async throws {
        // AlarmKit rejects a schedule call for an id it already holds — the daemon logs
        // "Not scheduling an alarm with a duplicate ID" and throws
        // `AlarmServiceError.invalidInput`. Editing an alarm reuses its id, so the previous
        // registration has to go first or every edit fails.
        cancel(id: item.id)

        let configuration = AlarmManager.AlarmConfiguration(
            schedule: item.schedule,
            attributes: attributes(for: item.metadata(), requiresScan: item.requiresPuckScan),
            stopIntent: item.requiresPuckScan ? StopWithoutScanIntent(alarmID: item.id.uuidString) : nil,
            secondaryIntent: item.requiresPuckScan ? OpenScanIntent(alarmID: item.id.uuidString) : nil,
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: item.id, configuration: configuration)
    }

    /// Schedules the retry that makes the puck scan mandatory. Fires `retryInterval` from
    /// now under a fresh id, but carries the *original* alarm's metadata so the wake-up
    /// screen keeps showing the time the user set.
    ///
    /// - Returns: the id of the retry alarm, so it can be cancelled on a successful scan.
    @discardableResult
    static func scheduleFollowUp(for wakeGuard: WakeGuard) async throws -> UUID {
        let followUpID = UUID()
        let fireDate = Date().addingTimeInterval(retryInterval)

        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(fireDate),
            attributes: attributes(for: wakeGuard.metadata, requiresScan: true),
            stopIntent: StopWithoutScanIntent(alarmID: wakeGuard.originAlarmID.uuidString),
            secondaryIntent: OpenScanIntent(alarmID: wakeGuard.originAlarmID.uuidString),
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: followUpID, configuration: configuration)
        return followUpID
    }

    // MARK: - Lifecycle

    static func cancel(id: UUID) {
        // `cancel` throws when the id is unknown to AlarmKit, which is a normal race
        // (the alarm may have already been stopped). Nothing useful to do about it.
        try? AlarmManager.shared.cancel(id: id)
    }

    static func stop(id: UUID) {
        try? AlarmManager.shared.stop(id: id)
    }

    /// Stops whichever alarm is currently alerting, plus any pending retry. Used when the
    /// puck scan succeeds and the wake-up is genuinely over.
    static func stopEverything(for wakeGuard: WakeGuard) {
        stopAlerting()
        if let followUpID = wakeGuard.pendingFollowUpID {
            cancel(id: followUpID)
        }
    }

    /// Silences whatever is ringing without touching the pending retry. Used when the user
    /// bypasses from inside the app: the noise should stop, the enforcement should not.
    static func stopAlerting() {
        for alarm in alarms where alarm.state == .alerting {
            try? AlarmManager.shared.stop(id: alarm.id)
        }
    }

    /// AlarmKit's `alarms` getter throws. A failure here means AlarmKit has nothing to
    /// report, which is indistinguishable from an empty list for every caller.
    static var alarms: [Alarm] {
        (try? AlarmManager.shared.alarms) ?? []
    }

    /// Schedules `item` and records the outcome in `store`.
    ///
    /// Every scheduling path goes through here rather than calling `schedule` directly:
    /// an alarm app whose list says "on" while AlarmKit holds nothing has no feature left
    /// worth discussing, so the failure has to reach the UI.
    ///
    /// - Returns: a human-readable message on failure, `nil` on success.
    @discardableResult
    static func schedule(_ item: AlarmItem, recordingIn store: AlarmStore) async -> String? {
        do {
            try await schedule(item)
            store.clearSchedulingFailure(for: item.id)
            return nil
        } catch {
            let message = describe(error)
            store.markSchedulingFailure(message, for: item.id)
            return message
        }
    }

    /// Pushes the whole local list into AlarmKit at launch. Disabled alarms are cancelled.
    ///
    /// Alarms AlarmKit already holds are left strictly alone. Re-registering them would
    /// mean cancelling first (see `schedule`), and cancelling an alarm that is *ringing
    /// right now* would silently end the wake-up — which is exactly the state the app is
    /// most likely to be launched in, since "Scan Puck" cold-launches it mid-alarm.
    static func syncAll(_ items: [AlarmItem], recordingIn store: AlarmStore) async {
        let alreadyScheduled = Set(alarms.map(\.id))

        for item in items {
            guard item.isEnabled else {
                cancel(id: item.id)
                store.clearSchedulingFailure(for: item.id)
                continue
            }
            guard !alreadyScheduled.contains(item.id) else {
                store.clearSchedulingFailure(for: item.id)
                continue
            }
            await schedule(item, recordingIn: store)
        }
    }

    /// AlarmKit's errors are not user-facing, so translate the ones that have a remedy.
    static func describe(_ error: Error) -> String {
        if let alarmError = error as? AlarmManager.AlarmError {
            switch alarmError {
            case .maximumLimitReached:
                return "iOS won't accept any more alarms from this app. Delete one and try again."
            @unknown default:
                return "iOS refused to schedule this alarm."
            }
        }
        return error.localizedDescription
    }

    // MARK: - Presentation

    /// The system alert. Note the deliberate absence of a snooze button: the retry loop is
    /// the snooze, and it costs a scan to end.
    private static func attributes(
        for metadata: PuckAlarmMetadata,
        requiresScan: Bool
    ) -> AlarmAttributes<PuckAlarmMetadata> {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: metadata.label),
            secondaryButton: requiresScan
                ? AlarmButton(
                    text: "Scan Puck",
                    textColor: .black,
                    systemImageName: "wave.3.right.circle.fill"
                )
                : nil,
            secondaryButtonBehavior: requiresScan ? .custom : nil
        )

        return AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: metadata,
            tintColor: Theme.accent
        )
    }
}
