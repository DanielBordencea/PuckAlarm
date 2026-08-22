import AlarmKit
import SwiftUI

/// The main screen: the alarm list, styled after the system Clock app's dark alarm tab.
struct AlarmListView: View {
    @Environment(AlarmStore.self) private var store

    @State private var editing: AlarmItem?
    @State private var showSettings = false
    @State private var authorizationDenied = false
    @State private var schedulingAlert: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if store.alarms.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Alarms")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                // Both trailing: with `.inlineLarge` the title claims the leading slot, and
                // iOS 26 folds a lone leading button into the "…" overflow, which buries
                // Settings behind an extra tap for no reason.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = AlarmItem()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("Add alarm")
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { item in
            AlarmEditorView(alarm: item)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            let state = (try? await AlarmScheduler.requestAuthorization()) ?? .notDetermined
            authorizationDenied = state == .denied
            if state == .authorized {
                await AlarmScheduler.syncAll(store.alarms, recordingIn: store)
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if authorizationDenied { authorizationBanner }
                if let warning = store.storeWarning { storeWarningBanner(warning) }
            }
        }
        .alert(
            "Alarm not scheduled",
            isPresented: Binding(
                get: { schedulingAlert != nil },
                set: { if !$0 { schedulingAlert = nil } }
            )
        ) {
            Button("OK", role: .cancel) { schedulingAlert = nil }
        } message: {
            Text(schedulingAlert ?? "")
        }
    }

    // MARK: - Pieces

    private var list: some View {
        List {
            ForEach(store.alarms) { alarm in
                AlarmRow(
                    alarm: alarm,
                    schedulingFailure: store.schedulingFailure(for: alarm.id)
                ) { isEnabled in
                    toggle(alarm, to: isEnabled)
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = alarm }
                .listRowBackground(Theme.background)
                .listRowSeparatorTint(Color.white.opacity(0.08))
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Alarms", systemImage: "alarm")
        } description: {
            Text("Add an alarm, then pair the NFC puck you'll keep away from your bed.")
        } actions: {
            Button("Add Alarm") { editing = AlarmItem() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    private var authorizationBanner: some View {
        Text("Alarms are turned off for this app. Enable them in Settings ▸ PuckAlarm.")
            .font(Theme.caption)
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.destructive.opacity(0.85))
    }

    private func storeWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            Button("Dismiss") { store.clearStoreWarning() }
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
        }
        .padding(12)
        .background(Theme.destructive.opacity(0.85))
    }

    // MARK: - Actions

    /// Turning an alarm on optimistically flips the switch, then reverts it if AlarmKit
    /// refuses — a switch that stays on while nothing is scheduled is the exact lie this
    /// app cannot afford to tell.
    private func toggle(_ alarm: AlarmItem, to isEnabled: Bool) {
        store.setEnabled(isEnabled, for: alarm.id)
        Task {
            guard isEnabled, var updated = store.alarm(id: alarm.id) else {
                AlarmScheduler.cancel(id: alarm.id)
                store.clearSchedulingFailure(for: alarm.id)
                return
            }
            updated.isEnabled = true
            if let message = await AlarmScheduler.schedule(updated, recordingIn: store) {
                store.setEnabled(false, for: alarm.id)
                schedulingAlert = message
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { store.alarms[$0] }
        for alarm in doomed {
            AlarmScheduler.cancel(id: alarm.id)
            store.delete(id: alarm.id)
        }
    }
}

private struct AlarmRow: View {
    let alarm: AlarmItem
    let schedulingFailure: String?
    let onToggle: (Bool) -> Void

    /// The switch is bound to local state rather than to a `Binding(get:set:)` over the
    /// model. Handing a closure to `Binding`'s `@Sendable` setter forces a reabstraction
    /// thunk to `@isolated(any) @Sendable (Bool) -> ()`, which crashes swift-frontend in
    /// IRGen on Xcode 26.5; going through `@State` plus `onChange` sidesteps the thunk and
    /// reads more plainly anyway.
    @State private var isOn: Bool

    init(alarm: AlarmItem, schedulingFailure: String?, onToggle: @escaping (Bool) -> Void) {
        self.alarm = alarm
        self.schedulingFailure = schedulingFailure
        self.onToggle = onToggle
        _isOn = State(initialValue: alarm.isEnabled)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(alarm.displayTime)
                    .font(Theme.rowTime)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .foregroundStyle(alarm.isEnabled ? Theme.primaryText : Theme.tertiaryText)
                    .monospacedDigit()

                HStack(spacing: 6) {
                    Text(alarm.label)
                    Text("·")
                    Text(alarm.repeatDescription)
                    if alarm.requiresPuckScan {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(alarm.isEnabled ? Theme.accent : Theme.tertiaryText)
                            .accessibilityLabel("Requires puck scan")
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)

                if let schedulingFailure {
                    Label(schedulingFailure, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
                .onChange(of: isOn) { _, newValue in
                    guard newValue != alarm.isEnabled else { return }
                    onToggle(newValue)
                }
                .onChange(of: alarm.isEnabled) { _, newValue in
                    // Snaps the switch back when the parent reverts an alarm that
                    // AlarmKit refused to schedule.
                    if isOn != newValue { isOn = newValue }
                }
        }
        .padding(.vertical, 6)
    }
}
