import AppIntents
import Foundation

/// Runs when the user presses the system Stop button on the alarm.
///
/// AlarmKit invokes this in the *app's* process (that is what `LiveActivityIntent` means),
/// so it can reach the store and the enforcer directly — no App Group required.
///
/// Shared between the app and the widget extension.
struct StopWithoutScanIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Alarm"
    static let description = IntentDescription(
        "Stops the alarm. If the alarm requires a puck scan, it will come back in a minute."
    )
    static let isDiscoverable = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        await WakeEnforcer.shared.handleStopPressed(originAlarmID: id)
        return .result()
    }
}

/// The "Scan Puck" button. Opens the app straight onto the scan screen.
///
/// Shared between the app and the widget extension.
struct OpenScanIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Scan Puck"
    static let description = IntentDescription("Opens the app to scan the alarm puck.")
    static let isDiscoverable = false

    /// Launching the app is the whole point: Core NFC will not start a reader session from
    /// a background extension.
    static let openAppWhenRun = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        await AppRouter.shared.requestScan(for: id)
        return .result()
    }
}
