import SwiftUI

/// Puck pairing, simulation switch, and the wake-up history.
struct SettingsView: View {
    @Environment(AlarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var reader = PuckReader()
    @State private var pairingStatus: String?
    @State private var isPairing = false

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                puckSection(store: store)

                Section {
                    Toggle("Simulate puck scans", isOn: $store.isSimulationEnabled)
                        .tint(Theme.accent)
                } header: {
                    Text("Testing")
                } footer: {
                    Text(
                        "Skips Core NFC entirely so the alarm and re-arm loop can be tested in the Simulator, or on a build signed with a free Apple ID (which cannot carry the NFC entitlement). Turn this off on a real, fully-signed build."
                    )
                }

                historySection

                Section {
                    Picker("Re-arm delay", selection: $store.retryInterval) {
                        ForEach(AlarmStore.retryChoices, id: \.self) { interval in
                            Text(Self.intervalLabel(interval)).tag(interval)
                        }
                    }
                    .tint(Theme.accent)
                } header: {
                    Text("Enforcement")
                } footer: {
                    Text(
                        "iOS always provides a Stop button on the system alarm and it cannot be removed. Pressing it — or \"I can't find my puck\" — re-arms the alarm after this delay, over and over, until the puck is scanned. Shorter is harsher. A new delay applies from the next bypass; a retry already armed keeps its original timing."
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// "30 seconds", "1 minute", "5 minutes" — reads better than a raw second count in a
    /// picker the user is choosing a punishment with.
    static func intervalLabel(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    // MARK: - Puck

    @ViewBuilder
    private func puckSection(store: AlarmStore) -> some View {
        Section {
            if let puck = store.puck {
                LabeledContent("Paired", value: puck.name)
                LabeledContent("Tag ID", value: puck.shortIdentifier)
                    .monospaced()
                LabeledContent("Since", value: puck.pairedAt.formatted(date: .abbreviated, time: .shortened))
                Button("Unpair", role: .destructive) {
                    store.unpairPuck()
                    pairingStatus = nil
                }
            } else {
                Text("No puck paired.")
                    .foregroundStyle(Theme.secondaryText)
            }

            Button(isPairing ? "Hold near the tag…" : (store.puck == nil ? "Pair Puck" : "Pair a Different Puck")) {
                pair()
            }
            .disabled(isPairing)
            .tint(Theme.accent)

            if let pairingStatus {
                Text(pairingStatus)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text("Puck")
        } footer: {
            Text(
                "Any NFC tag works and nothing has to be written to it — the app matches on the tag's built-in ID. Put it somewhere that forces you out of bed."
            )
        }
    }

    private func pair() {
        if store.isSimulationEnabled {
            store.pair(
                PairedPuck(
                    identifier: "SIMULATED-PUCK",
                    name: "Simulated puck",
                    pairedAt: Date()
                )
            )
            pairingStatus = "Paired a simulated puck."
            return
        }

        isPairing = true
        pairingStatus = nil
        Task {
            defer { isPairing = false }
            do {
                let identifier = try await reader.readIdentifier(
                    prompt: "Hold your iPhone near the tag you want to use",
                    successMessage: "Puck Paired"
                )
                store.pair(
                    PairedPuck(identifier: identifier, name: "esc", pairedAt: Date())
                )
                pairingStatus = "Paired."
            } catch PuckReader.Failure.cancelled {
                pairingStatus = nil
            } catch {
                pairingStatus = error.localizedDescription
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section {
            if store.history.isEmpty {
                Text("No wake-ups recorded yet.")
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(store.history.prefix(20)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.label)
                                .foregroundStyle(Theme.primaryText)
                            Text(record.firedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.caption)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Image(
                                systemName: record.dismissedByScan
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(record.dismissedByScan ? Theme.accent : Theme.destructive)
                            if record.bypassCount > 0 {
                                Text("\(record.bypassCount) bypass\(record.bypassCount == 1 ? "" : "es")")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                    }
                }
                Button("Clear History", role: .destructive) { store.clearHistory() }
            }
        } header: {
            Text("History")
        }
    }
}
