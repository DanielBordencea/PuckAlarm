import AlarmKit
import Foundation

/// Travels with the alarm into the Live Activity, so the widget extension can render the
/// wake-up screen without reading any shared storage. Keep it small — it is encoded into
/// the activity payload.
///
/// Shared between the app and the widget extension.
struct PuckAlarmMetadata: AlarmMetadata {
    /// Identifier of the *user-facing* alarm. Follow-up (re-armed) alarms carry the id of
    /// the alarm they are enforcing, not their own, so the scan screen keeps showing the
    /// original 09:00 rather than the retry time.
    var originAlarmID: UUID

    /// "Wake Up", "Gym", … shown under the time.
    var label: String

    /// The time the user actually set, formatted for display. The retry alarms fire at
    /// arbitrary times, but the screen should keep reading 09:00.
    var displayHour: Int
    var displayMinute: Int

    /// How many times the alarm has been stopped without a puck scan during this wake-up.
    /// Drives the escalating copy on the alert.
    var bypassCount: Int

    /// True when this is a re-armed follow-up rather than the original firing.
    var isFollowUp: Bool

    init(
        originAlarmID: UUID,
        label: String,
        displayHour: Int,
        displayMinute: Int,
        bypassCount: Int = 0,
        isFollowUp: Bool = false
    ) {
        self.originAlarmID = originAlarmID
        self.label = label
        self.displayHour = displayHour
        self.displayMinute = displayMinute
        self.bypassCount = bypassCount
        self.isFollowUp = isFollowUp
    }

    /// "09:00" — locale-aware, matching the system alarm presentation.
    var displayTime: String {
        var components = DateComponents()
        components.hour = displayHour
        components.minute = displayMinute
        let date = Calendar.current.date(from: components) ?? Date()

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }
}
