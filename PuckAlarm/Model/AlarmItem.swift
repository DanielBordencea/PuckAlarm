import AlarmKit
import Foundation

/// One alarm as the user configured it. Persisted by `AlarmStore`; AlarmKit holds its own
/// copy of the schedule, so this is the source of truth for everything AlarmKit does not
/// remember (label, enabled flag, whether a puck scan is required).
struct AlarmItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var hour: Int
    var minute: Int
    var label: String
    var isEnabled: Bool

    /// Weekdays this alarm repeats on. Empty means a one-shot alarm.
    var repeatDays: Set<Weekday>

    /// When false the alarm behaves like a normal alarm and Stop just stops it.
    var requiresPuckScan: Bool

    init(
        id: UUID = UUID(),
        hour: Int = 7,
        minute: Int = 0,
        label: String = "Wake Up",
        isEnabled: Bool = true,
        repeatDays: Set<Weekday> = [],
        requiresPuckScan: Bool = true
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.label = label
        self.isEnabled = isEnabled
        self.repeatDays = repeatDays
        self.requiresPuckScan = requiresPuckScan
    }
}

extension AlarmItem {
    /// "09:00", locale-aware.
    var displayTime: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    /// "Never", "Every day", "Weekdays", "Mon Tue Fri", …
    var repeatDescription: String {
        if repeatDays.isEmpty { return "Never" }
        if repeatDays.count == 7 { return "Every day" }
        if repeatDays == Weekday.weekdays { return "Weekdays" }
        if repeatDays == Weekday.weekend { return "Weekends" }
        return Weekday.allCases
            .filter { repeatDays.contains($0) }
            .map(\.shortName)
            .joined(separator: " ")
    }

    var schedule: Alarm.Schedule {
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        let recurrence: Alarm.Schedule.Relative.Recurrence =
            repeatDays.isEmpty
            ? .never
            : .weekly(Weekday.allCases.filter { repeatDays.contains($0) }.map(\.localeWeekday))
        return .relative(Alarm.Schedule.Relative(time: time, repeats: recurrence))
    }

    func metadata(bypassCount: Int = 0, isFollowUp: Bool = false) -> PuckAlarmMetadata {
        PuckAlarmMetadata(
            originAlarmID: id,
            label: label,
            displayHour: hour,
            displayMinute: minute,
            bypassCount: bypassCount,
            isFollowUp: isFollowUp
        )
    }

    /// Next wall-clock firing, used only for the "rings in 7h 12m" hint in the list.
    func nextFireDate(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }

        if repeatDays.isEmpty {
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime
            )
        }

        return repeatDays
            .compactMap { day in
                calendar.nextDate(
                    after: now,
                    matching: DateComponents(hour: hour, minute: minute, weekday: day.calendarWeekday),
                    matchingPolicy: .nextTime
                )
            }
            .min()
    }
}

/// A weekday that is `Codable` and `Hashable` in a stable way, unlike `Locale.Weekday`
/// whose raw representation we do not want to persist.
enum Weekday: Int, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case monday = 2, tuesday, wednesday, thursday, friday, saturday
    case sunday = 1

    var id: Int { rawValue }

    /// `Calendar`'s 1-based weekday, Sunday == 1.
    var calendarWeekday: Int { rawValue }

    var localeWeekday: Locale.Weekday {
        switch self {
        case .sunday: .sunday
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        }
    }

    var shortName: String {
        switch self {
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        case .sunday: "Sun"
        }
    }

    var initial: String {
        switch self {
        case .monday: "M"
        case .tuesday: "T"
        case .wednesday: "W"
        case .thursday: "T"
        case .friday: "F"
        case .saturday: "S"
        case .sunday: "S"
        }
    }

    /// Display order: Monday first, Sunday last. `allCases` follows the declaration order,
    /// which already puts Monday first, but Sunday's raw value is 1 — spell the order out
    /// so a future reorder of the cases cannot silently change the UI.
    static let displayOrder: [Weekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
    ]

    static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let weekend: Set<Weekday> = [.saturday, .sunday]
}
