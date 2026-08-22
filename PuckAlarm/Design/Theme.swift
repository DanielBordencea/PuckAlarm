import SwiftUI

/// Colors and type ramp for the wake-up screen. Tuned against the reference screenshots:
/// true black behind a very large rounded time, one accent, everything else grayscale.
///
/// Shared between the app and the widget extension.
enum Theme {
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)   // system-blue-ish
    static let background = Color.black
    static let surface = Color(white: 0.11)
    static let surfaceRaised = Color(white: 0.16)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.62)
    static let tertiaryText = Color(white: 0.42)
    static let destructive = Color(red: 1.0, green: 0.27, blue: 0.23)

    /// The oversized clock. Rounded design and semibold weight is what makes it read as the
    /// system alarm rather than a generic SwiftUI screen.
    ///
    /// Takes an explicit size because callers scale it with `@ScaledMetric`: a fixed 76pt
    /// clock ignores the user's text-size setting, and this is a screen people read at 6am
    /// without their glasses.
    static func clock(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    // Text styles rather than fixed point sizes, so everything below the clock scales with
    // Dynamic Type for free.
    static let label = Font.system(.body, design: .rounded).weight(.medium)
    static let caption = Font.system(.footnote, design: .rounded).weight(.medium)
    static let button = Font.system(.body, design: .rounded).weight(.semibold)
    static let eyebrow = Font.system(.caption2, design: .rounded).weight(.bold)
    static let rowTime = Font.system(size: 40, weight: .semibold, design: .rounded)
}
