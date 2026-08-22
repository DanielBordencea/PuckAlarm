import SwiftUI

/// Decides between the alarm list and the blocking wake-up screen.
///
/// The gate is a full-screen cover with dismissal disabled, so while it is up the rest of
/// the app is unreachable. A bypass hides it for a minute; only a scan closes the wake-up.
struct RootView: View {
    @Environment(WakeEnforcer.self) private var enforcer
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    /// Mirrors `enforcer.isGateVisible` rather than binding to it directly.
    ///
    /// `fullScreenCover(isPresented: .constant(true))` does not present when the value is
    /// already true at first render — it needs a transition from false. That is exactly
    /// the cold-launch case: "Scan Puck" launches the app from scratch with a guard
    /// already open, and the gate would silently never appear. Seeding this from `.task`
    /// (which runs after the first render) makes it a real change every time.
    @State private var isGateUp = false

    var body: some View {
        AlarmListView()
            .fullScreenCover(isPresented: $isGateUp) {
                if let wakeGuard = enforcer.activeGuard {
                    ScanGateView(wakeGuard: wakeGuard)
                } else {
                    // The guard resolved while the cover was animating in; close it again
                    // rather than showing an empty sheet the user cannot dismiss.
                    Color.clear.onAppear { isGateUp = false }
                }
            }
            .onChange(of: enforcer.isGateVisible) { _, visible in
                isGateUp = visible
            }
            .onChange(of: scenePhase) { _, phase in
                // The app is usually cold-launched by "Scan Puck", so the guard has to be
                // reconstructed from AlarmKit's live state rather than assumed.
                if phase == .active {
                    enforcer.reconcile()
                    syncGate()
                }
            }
            .onChange(of: router.scanRequestToken) { _, _ in
                enforcer.reconcile()
                enforcer.presentGateNow()
                syncGate()
                router.clearScanRequest()
            }
            .onOpenURL { url in
                // How the Live Activity gets here: a widget cannot foreground the app by
                // running an intent, so the "Scan Puck" button is a Link to this URL.
                guard let alarmID = DeepLink.scanAlarmID(from: url) else {
                    AppLog.routing.notice("ignored unknown URL \(url.absoluteString, privacy: .public)")
                    return
                }
                AppLog.routing.notice("scan link opened for \(alarmID.uuidString, privacy: .public)")
                router.requestScan(for: alarmID)
            }
            .task {
                enforcer.startObserving()
                enforcer.reconcile()
                syncGate()
            }
    }

    private func syncGate() {
        let visible = enforcer.isGateVisible
        guard isGateUp != visible else { return }
        AppLog.routing.notice("gate \(visible ? "shown" : "hidden", privacy: .public)")
        isGateUp = visible
    }
}
