import Foundation
import Observation

/// The URL the Live Activity uses to bring the app forward.
///
/// A widget cannot open the app by running an `AppIntent`: `Button(intent:)` deliberately
/// performs the intent in the background so interactive widgets stay in place. Opening a
/// URL is the supported way, and it is what `Link` and `widgetURL` do.
///
/// Shared between the app (which parses it) and the widget extension (which builds it).
enum DeepLink {
    static let scheme = "puckalarm"
    static let scanHost = "scan"

    static func scan(alarmID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = scanHost
        components.queryItems = [URLQueryItem(name: "alarm", value: alarmID.uuidString)]
        // The components above are all valid by construction; a nil here would mean the
        // constants themselves are wrong, which a test would catch long before a user does.
        return components.url ?? URL(string: "\(scheme)://\(scanHost)")!
    }

    /// Returns the alarm id when `url` is a scan link, `nil` for anything else.
    static func scanAlarmID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == scanHost else { return nil }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "alarm" }?
            .value
        return value.flatMap(UUID.init(uuidString:))
    }
}

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
