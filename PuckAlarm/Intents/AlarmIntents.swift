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

    /// Runs in the background: pressing Stop should re-arm the alarm, not drag the user
    /// into the app.
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        AppLog.routing.notice("StopWithoutScanIntent fired for \(alarmID, privacy: .public)")
        guard let id = UUID(uuidString: alarmID) else {
            AppLog.routing.error("StopWithoutScanIntent: unparseable id")
            return .result()
        }
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
    /// a background extension, so this intent is useless unless it brings the app forward.
    ///
    /// `openAppWhenRun` is the iOS 16 spelling and is deprecated as of iOS 26 — the SDK
    /// says "provide 'supportedModes' instead". Left in place for the older API surface,
    /// but `supportedModes` is what iOS 26 actually honours; with only the deprecated flag
    /// set, the intent ran in the background and the button appeared to do nothing at all.
    static let openAppWhenRun = true
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        AppLog.routing.notice("OpenScanIntent fired for \(alarmID, privacy: .public)")
        guard let id = UUID(uuidString: alarmID) else {
            AppLog.routing.error("OpenScanIntent: unparseable id")
            return .result()
        }
        await AppRouter.shared.requestScan(for: id)
        return .result()
    }
}
