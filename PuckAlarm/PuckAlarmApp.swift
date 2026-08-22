import SwiftUI

@main
struct PuckAlarmApp: App {
    @State private var store = AlarmStore.shared
    @State private var enforcer = WakeEnforcer.shared
    @State private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(enforcer)
                .environment(router)
                .tint(Theme.accent)
        }
    }
}
