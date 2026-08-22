import Foundation
import Observation

/// Carries a request from an intent (which may run while the app is still launching) to
/// the view layer.
///
/// Shared between the app and the widget extension because `OpenScanIntent` lives in both
/// targets; only the app ever observes it.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// Set by `OpenScanIntent`. `RootView` watches this and presents the scan screen.
    private(set) var pendingScanAlarmID: UUID?

    /// Bumped every time a scan is requested, so tapping "Scan Puck" twice in a row still
    /// re-triggers the sheet even though the id has not changed.
    private(set) var scanRequestToken = 0

    func requestScan(for alarmID: UUID) {
        pendingScanAlarmID = alarmID
        scanRequestToken += 1
    }

    func clearScanRequest() {
        pendingScanAlarmID = nil
    }
}
