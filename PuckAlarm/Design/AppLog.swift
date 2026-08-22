import Foundation
import os

/// Structured logging for the parts of the app that run while nobody is watching.
///
/// The enforcement loop fires at 6am, in the background, driven by a system daemon. When
/// it misbehaves there is no debugger attached and no console open — the only way to find
/// out what happened is a log that was already being written. `print` does not survive
/// that: it goes to stdout, which is not captured unless the process was launched from
/// Xcode. `os.Logger` writes to the unified log, readable afterwards with:
///
///     log show --last 30m --predicate 'subsystem == "com.bordencea.PuckAlarm"'
///
/// Shared between the app and the widget extension.
enum AppLog {
    private static let subsystem = "com.bordencea.PuckAlarm"

    /// Wake-up state machine: guards opening, bypasses, deferrals, resolutions.
    static let enforcement = Logger(subsystem: subsystem, category: "enforcement")

    /// AlarmKit scheduling and its failures.
    static let scheduling = Logger(subsystem: subsystem, category: "scheduling")

    /// Navigation into the app from outside it — Live Activity links, intents.
    static let routing = Logger(subsystem: subsystem, category: "routing")
}
