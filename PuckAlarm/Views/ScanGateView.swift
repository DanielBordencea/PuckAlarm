import SwiftUI

/// The blocking wake-up screen: big time, puck target, "Scan Puck".
///
/// Modeled on the reference screenshot. It appears whenever a `WakeGuard` is open and
/// cannot be swiped away — the only exits are a successful scan or the explicit
/// "I can't find my puck" escape hatch, which is recorded as a bypass.
struct ScanGateView: View {
    let wakeGuard: WakeGuard

    @Environment(WakeEnforcer.self) private var enforcer
    @Environment(AlarmStore.self) private var store

    @State private var reader = PuckReader()
    @State private var status: Status = .idle
    @State private var showEscapeConfirmation = false
    @State private var pulse = false

    /// The clock is the one fixed-size element on the screen; `@ScaledMetric` keeps it
    /// responsive to the user's text-size setting instead of pinning it at 76pt.
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 76

    private enum Status: Equatable {
        case idle
        case scanning
        case wrongTag
        case failed(String)
        case success
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                clock
                Spacer(minLength: 16)
                puckTarget
                Spacer(minLength: 16)
                statusLine
                if let warning = enforcer.enforcementWarning {
                    enforcementBanner(warning)
                }
                Spacer(minLength: 24)
                actions
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onAppear { pulse = true }
        .confirmationDialog(
            "Dismiss without scanning?",
            isPresented: $showEscapeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Dismiss anyway", role: .destructive) {
                enforcer.resolveWithoutScan()
            }
            Button("Keep trying", role: .cancel) {}
        } message: {
            Text("This is logged as a bypass and the alarm will not come back.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("ALARM")
                        .font(Theme.eyebrow)
                        .tracking(0.6)
                        .foregroundStyle(Theme.tertiaryText)
                    Text(wakeGuard.label)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            if wakeGuard.bypassCount > 0 {
                Text("Attempt \(wakeGuard.bypassCount + 1)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.destructive)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.destructive.opacity(0.15), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var clock: some View {
        VStack(spacing: 6) {
            Text(displayTime)
                .font(Theme.clock(size: clockSize))
                .foregroundStyle(Theme.primaryText)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(wakeGuard.label)
                .font(Theme.label)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// Stand-in for the physical puck. Pulses while idle so the screen has a focal point,
    /// and swaps to the system NFC glyph while a session is open.
    private var puckTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface)
                .frame(width: 168, height: 96)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            status == .scanning ? Theme.accent : Color.white.opacity(0.06),
                            lineWidth: status == .scanning ? 2 : 1
                        )
                }
                .scaleEffect(pulse && status != .scanning ? 1.0 : 0.97)
                .animation(
                    .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                    value: pulse
                )

            Group {
                switch status {
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                case .scanning:
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                default:
                    Text(puckName)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 16)
                }
            }
            .transition(.opacity.combined(with: .scale))
        }
        .animation(.snappy, value: status)
        .accessibilityHidden(true)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(Theme.caption)
            .foregroundStyle(statusColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .animation(.snappy, value: status)
    }

    /// Shown when the retry could not be armed. The user is awake right now and can set a
    /// backup alarm; five minutes from now they cannot.
    private func enforcementBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.caption)
            .foregroundStyle(Theme.destructive)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.destructive.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 14) {
            Button(action: scan) {
                Text(status == .scanning ? "Scanning…" : "Scan Puck")
                    .font(Theme.button)
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(status == .scanning || status == .success)
            .opacity(status == .scanning ? 0.6 : 1)

            Button("I can't find my puck") {
                showEscapeConfirmation = true
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.tertiaryText)
        }
    }

    // MARK: - Derived copy

    private var displayTime: String {
        var components = DateComponents()
        components.hour = wakeGuard.displayHour
        components.minute = wakeGuard.displayMinute
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    private var puckName: String {
        store.puck?.name ?? "puck"
    }

    private var statusText: String {
        switch status {
        case .idle:
            store.puck == nil
                ? "No puck paired. Pair one in Settings, or dismiss below."
                : "Hold your iPhone against the dock to stop the alarm."
        case .scanning:
            "Hold near the puck…"
        case .wrongTag:
            "That's not your puck."
        case .failed(let message):
            message
        case .success:
            "Alarm stopped."
        }
    }

    private var statusColor: Color {
        switch status {
        case .wrongTag, .failed: Theme.destructive
        case .success: Theme.accent
        default: Theme.secondaryText
        }
    }

    // MARK: - Scanning

    private func scan() {
        guard store.puck != nil else {
            status = .failed("Pair a puck first — Settings ▸ Puck.")
            return
        }

        if store.isSimulationEnabled {
            simulateScan()
            return
        }

        status = .scanning
        Task {
            do {
                let identifier = try await reader.readIdentifier(
                    prompt: "Hold your iPhone near the puck",
                    successMessage: "Alarm Stopped"
                )
                if store.matchesPuck(identifier: identifier) {
                    status = .success
                    enforcer.resolveByScan()
                } else {
                    status = .wrongTag
                }
            } catch PuckReader.Failure.cancelled {
                status = .idle
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Simulation path: no Core NFC session, so no entitlement and no system sheet. Keeps
    /// the same timing as a real tap so the screen behaves identically.
    private func simulateScan() {
        status = .scanning
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            status = .success
            enforcer.resolveByScan()
        }
    }
}
