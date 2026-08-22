import CoreNFC
import Foundation
import Observation

/// Persistence for everything AlarmKit does not remember: the alarm list, the paired
/// puck, and the state of an in-progress wake-up.
///
/// Deliberately backed by plain `UserDefaults.standard`, not an App Group. The widget
/// extension never reads this — it renders from `AlarmAttributes` — and `LiveActivityIntent`
/// runs inside the app process, so a single-process store is sufficient. Avoiding the App
/// Group also keeps the project buildable on a free Apple ID.
@MainActor
@Observable
final class AlarmStore {
    static let shared = AlarmStore()

    private enum Key {
        static let alarms = "puckalarm.alarms"
        static let puck = "puckalarm.puck"
        static let guardState = "puckalarm.guard"
        static let history = "puckalarm.history"
        static let simulation = "puckalarm.simulatePuck"
        static let schemaVersion = "puckalarm.schemaVersion"
        static let retryInterval = "puckalarm.retryInterval"
    }

    /// How long after a bypass the alarm comes back. Short enough to be relentless, long
    /// enough that the system alert has dismissed before the next one arrives — below
    /// about 30 seconds the alerts start stepping on each other.
    static let retryChoices: [TimeInterval] = [30, 60, 120, 300, 600]
    static let defaultRetryInterval: TimeInterval = 60

    /// Bump whenever the shape of a persisted model changes. Stored alongside the data so
    /// a mismatch can be reported instead of being discovered as an empty alarm list.
    static let currentSchemaVersion = 1

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var alarms: [AlarmItem] {
        didSet { persist(alarms, forKey: Key.alarms) }
    }

    /// The paired puck. `nil` until the user pairs one in Settings.
    /// Backed by the Keychain, not `UserDefaults` — see `PuckKeychain`.
    private(set) var puck: PairedPuck? {
        didSet {
            if let puck {
                PuckKeychain.save(puck)
            } else {
                PuckKeychain.delete()
            }
        }
    }

    /// Non-nil while an alarm has fired and has not yet been dismissed by a puck scan.
    /// This is what makes the scan mandatory: as long as it is set, the app re-arms.
    private(set) var activeGuard: WakeGuard? {
        didSet { persist(activeGuard, forKey: Key.guardState) }
    }

    /// Newest first, capped at `historyLimit`.
    private(set) var history: [WakeRecord] {
        didSet { persist(history, forKey: Key.history) }
    }

    /// Stands in for a real tag scan on hardware where Core NFC cannot run: the Simulator,
    /// and any build signed with a free Apple ID, which cannot carry the NFC entitlement.
    /// Turning it on lets the whole alarm → bypass → re-arm → scan loop be exercised.
    var isSimulationEnabled: Bool {
        didSet { defaults.set(isSimulationEnabled, forKey: Key.simulation) }
    }

    /// Seconds between a bypass and the alarm returning. User-configurable in Settings.
    var retryInterval: TimeInterval {
        didSet { defaults.set(retryInterval, forKey: Key.retryInterval) }
    }

    /// Set when saved data could not be read back. Surfaced in Settings rather than left
    /// for the user to discover as a mysteriously empty alarm list.
    private(set) var storeWarning: String?

    /// Alarms the app believes are on but AlarmKit refused to schedule, keyed by alarm id.
    /// Not persisted: `syncAll` re-derives it at every launch. An entry here is what stops
    /// the list from lying about whether an alarm will actually ring.
    private(set) var schedulingFailures: [UUID: String] = [:]

    private let historyLimit = 100

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var unreadableKeys: [String] = []

        /// Decodes one key, and on failure preserves the raw bytes under `<key>.corrupt`
        /// so the next write cannot destroy them. A decode bug then costs the user a
        /// support conversation rather than every alarm they had set.
        func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            guard let data = defaults.data(forKey: key) else { return nil }
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                defaults.set(data, forKey: key + ".corrupt")
                unreadableKeys.append(key)
                return nil
            }
        }

        alarms = read([AlarmItem].self, Key.alarms) ?? []

        // Migrate a puck paired by an earlier build, which kept it in UserDefaults.
        // The Keychain wins if both exist, but the legacy copy is cleared either way —
        // leaving it behind would defeat the point of moving the identifier out of the
        // plist in the first place.
        if let keychainPuck = PuckKeychain.load() {
            puck = keychainPuck
        } else if let legacyPuck = read(PairedPuck.self, Key.puck) {
            puck = legacyPuck
            PuckKeychain.save(legacyPuck)
        } else {
            puck = nil
        }
        defaults.removeObject(forKey: Key.puck)

        activeGuard = read(WakeGuard.self, Key.guardState)
        history = read([WakeRecord].self, Key.history) ?? []
        isSimulationEnabled =
            defaults.object(forKey: Key.simulation) as? Bool ?? !NFCTagReaderSession.readingAvailable
        retryInterval =
            defaults.object(forKey: Key.retryInterval) as? TimeInterval ?? Self.defaultRetryInterval

        let storedVersion = defaults.object(forKey: Key.schemaVersion) as? Int
        if let storedVersion, storedVersion > Self.currentSchemaVersion {
            unreadableKeys.append("data from a newer version of the app")
        }
        defaults.set(Self.currentSchemaVersion, forKey: Key.schemaVersion)

        storeWarning = unreadableKeys.isEmpty
            ? nil
            : "Couldn't read saved data (\(unreadableKeys.joined(separator: ", "))). "
                + "A copy was kept and nothing was overwritten, but you may need to set your alarms again."
    }

    func clearStoreWarning() {
        storeWarning = nil
    }

    // MARK: - Alarms

    func alarm(id: UUID) -> AlarmItem? {
        alarms.first { $0.id == id }
    }

    func upsert(_ alarm: AlarmItem) {
        if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[index] = alarm
        } else {
            alarms.append(alarm)
        }
        sortAlarms()
    }

    func delete(id: UUID) {
        alarms.removeAll { $0.id == id }
        schedulingFailures[id] = nil
        if activeGuard?.originAlarmID == id {
            activeGuard = nil
        }
    }

    // MARK: - Scheduling outcomes

    func markSchedulingFailure(_ message: String, for id: UUID) {
        schedulingFailures[id] = message
    }

    func clearSchedulingFailure(for id: UUID) {
        schedulingFailures[id] = nil
    }

    func schedulingFailure(for id: UUID) -> String? {
        schedulingFailures[id]
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled = isEnabled
    }

    private func sortAlarms() {
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    // MARK: - Puck

    func pair(_ puck: PairedPuck) {
        self.puck = puck
    }

    func unpairPuck() {
        puck = nil
    }

    /// True when `identifier` is the paired puck. Comparison is on the raw tag identifier,
    /// so an unwritten, blank NFC tag works — nothing has to be programmed onto it.
    func matchesPuck(identifier: String) -> Bool {
        guard let puck else { return false }
        return puck.identifier.caseInsensitiveCompare(identifier) == .orderedSame
    }

    // MARK: - Wake guard

    func beginGuard(_ wakeGuard: WakeGuard) {
        activeGuard = wakeGuard
    }

    func updateGuard(_ transform: (inout WakeGuard) -> Void) {
        guard var current = activeGuard else { return }
        transform(&current)
        activeGuard = current
    }

    /// Clears the guard and records the outcome.
    func resolveGuard(scanned: Bool) {
        guard let wakeGuard = activeGuard else { return }
        let record = WakeRecord(
            id: UUID(),
            alarmID: wakeGuard.originAlarmID,
            label: wakeGuard.label,
            firedAt: wakeGuard.firedAt,
            resolvedAt: Date(),
            bypassCount: wakeGuard.bypassCount,
            dismissedByScan: scanned
        )
        history.insert(record, at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        activeGuard = nil
    }

    func clearHistory() {
        history = []
    }

    // MARK: - Codable plumbing

    private func persist<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try encoder.encode(value), forKey: key)
        } catch {
            // A failed write must not take the app down mid-alarm. The in-memory value
            // stays correct for this launch; the next successful write repairs disk.
            assertionFailure("Failed to persist \(key): \(error)")
        }
    }

}

/// The NFC tag that acts as the dock. Only its identifier matters — the tag can be blank.
struct PairedPuck: Codable, Hashable, Sendable {
    /// Uppercase hex of the tag's UID, e.g. `04A2B3C4D5E680`.
    var identifier: String
    var name: String
    var pairedAt: Date

    var shortIdentifier: String {
        identifier.count <= 8 ? identifier : String(identifier.prefix(8)) + "…"
    }
}

/// Live state of a wake-up that has fired but has not been dismissed by a scan.
struct WakeGuard: Codable, Hashable, Sendable {
    /// The alarm the user configured (not the retry alarm currently ringing).
    var originAlarmID: UUID
    var label: String
    var displayHour: Int
    var displayMinute: Int

    /// When the original alarm first went off.
    var firedAt: Date

    /// How many times Stop was pressed without a scan.
    var bypassCount: Int

    /// The AlarmKit id of the retry alarm currently scheduled, if any. Kept so the retry
    /// can be cancelled the moment the puck is scanned.
    var pendingFollowUpID: UUID?

    /// While set and in the future, the scan screen stays hidden so the phone is usable —
    /// but the wake-up is *not* over. The retry is already armed and the guard is still
    /// open, so the alarm comes back and the screen returns with it.
    ///
    /// Optional and therefore backward-compatible with guards persisted before this
    /// existed: the synthesized decoder treats a missing key as `nil`.
    var deferredUntil: Date?

    /// True when the scan screen should be on screen right now.
    var isGateVisible: Bool {
        guard let deferredUntil else { return true }
        return Date() >= deferredUntil
    }

    var metadata: PuckAlarmMetadata {
        PuckAlarmMetadata(
            originAlarmID: originAlarmID,
            label: label,
            displayHour: displayHour,
            displayMinute: displayMinute,
            bypassCount: bypassCount,
            isFollowUp: bypassCount > 0
        )
    }
}

/// One completed wake-up, for the history list.
struct WakeRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var alarmID: UUID
    var label: String
    var firedAt: Date
    var resolvedAt: Date
    var bypassCount: Int
    var dismissedByScan: Bool

    var timeToWake: TimeInterval {
        resolvedAt.timeIntervalSince(firedAt)
    }
}
