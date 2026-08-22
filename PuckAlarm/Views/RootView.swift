import SwiftUI

/// Decides between the alarm list and the blocking wake-up screen.
///
/// The gate is presented as a full-screen cover with dismissal disabled, so once a
/// `WakeGuard` is open the rest of the app is unreachable until it resolves.
struct RootView: View {
    @Environment(WakeEnforcer.self) private var enforcer
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        AlarmListView()
            .fullScreenCover(isPresented: .constant(enforcer.isGuardActive)) {
                if let wakeGuard = enforcer.activeGuard {
                    ScanGateView(wakeGuard: wakeGuard)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // The app is usually cold-launched by "Scan Puck", so the guard has to be
                // reconstructed from AlarmKit's live state rather than assumed.
                if phase == .active {
                    enforcer.reconcile()
                }
            }
            .onChange(of: router.scanRequestToken) { _, _ in
                enforcer.reconcile()
                router.clearScanRequest()
            }
            .task {
                enforcer.startObserving()
                enforcer.reconcile()
            }
    }
}
