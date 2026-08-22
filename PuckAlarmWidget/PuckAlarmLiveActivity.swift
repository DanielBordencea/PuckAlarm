import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity AlarmKit drives for our alarms — Lock Screen banner and Dynamic
/// Island.
///
/// This is the customisable half of the presentation. The full-screen alert that appears
/// when the alarm actually fires is drawn by the system from `AlarmPresentation.Alert`,
/// so its layout cannot be replaced; what is below is what the user sees on the Lock
/// Screen and in the Dynamic Island around it.
struct PuckAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<PuckAlarmMetadata>.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Theme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.metadata?.label ?? "Alarm", systemImage: "alarm.fill")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.metadata?.displayTime ?? "")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    scanButton(for: context.attributes.metadata)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(Theme.accent)
            } compactTrailing: {
                Image(systemName: "wave.3.right").foregroundStyle(Theme.accent)
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(Theme.accent)
            }
            .keylineTint(Theme.accent)
        }
    }

    /// `Link`, not `Button(intent:)`.
    ///
    /// A widget runs `Button(intent:)` in the background on purpose — interactive widgets
    /// are meant to act without launching anything — so an intent here would tick over
    /// silently and the user would see nothing happen. Only a URL brings the app forward,
    /// and the app has to be in the foreground before Core NFC will open a reader session
    /// at all.
    @ViewBuilder
    private func scanButton(for metadata: PuckAlarmMetadata?) -> some View {
        if let metadata {
            Link(destination: DeepLink.scan(alarmID: metadata.originAlarmID)) {
                Text("Scan Puck")
                    .font(Theme.button)
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.white, in: Capsule())
            }
        }
    }
}

/// Lock Screen presentation, laid out like the reference screenshot: label at the top,
/// oversized time, then the scan affordance.
private struct LockScreenView: View {
    let attributes: AlarmAttributes<PuckAlarmMetadata>
    let state: AlarmPresentationState

    private var metadata: PuckAlarmMetadata? { attributes.metadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(metadata?.label ?? "Alarm")
                    .font(Theme.caption)
                Spacer()
                if let count = metadata?.bypassCount, count > 0 {
                    Text("Attempt \(count + 1)")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.destructive)
                }
            }
            .foregroundStyle(Theme.secondaryText)

            Text(timeText)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(subtitle)
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiaryText)

            if case .alert = state.mode, let metadata {
                Link(destination: DeepLink.scan(alarmID: metadata.originAlarmID)) {
                    Text("Scan Puck")
                        .font(Theme.button)
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white, in: Capsule())
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        // Tapping anywhere on the banner, not just the button, opens the scan screen.
        .widgetURL(metadata.map { DeepLink.scan(alarmID: $0.originAlarmID) })
    }

    /// While alerting, AlarmKit reports the scheduled time in the state; fall back to the
    /// metadata so a re-armed alarm still shows the time the user originally set.
    private var timeText: String {
        metadata?.displayTime ?? ""
    }

    private var subtitle: String {
        switch state.mode {
        case .alert:
            "Scan your puck to stop the alarm."
        case .countdown:
            "Alarm armed."
        case .paused:
            "Paused."
        @unknown default:
            ""
        }
    }
}
