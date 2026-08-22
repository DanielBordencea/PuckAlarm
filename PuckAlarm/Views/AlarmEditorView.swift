import SwiftUI

/// Add / edit one alarm.
struct AlarmEditorView: View {
    @Environment(AlarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AlarmItem
    @State private var time: Date
    @State private var schedulingError: String?
    @State private var isSaving = false
    private let isNew: Bool

    init(alarm: AlarmItem) {
        _draft = State(initialValue: alarm)
        var components = DateComponents()
        components.hour = alarm.hour
        components.minute = alarm.minute
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        isNew = AlarmStore.shared.alarm(id: alarm.id) == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Theme.background)

                Section {
                    TextField("Label", text: $draft.label)
                        .textInputAutocapitalization(.words)

                    NavigationLink {
                        RepeatPicker(selection: $draft.repeatDays)
                    } label: {
                        LabeledContent("Repeat", value: draft.repeatDescription)
                    }
                }

                Section {
                    Toggle("Require puck scan", isOn: $draft.requiresPuckScan)
                        .tint(Theme.accent)
                } footer: {
                    Text(
                        draft.requiresPuckScan
                            ? "Pressing Stop without scanning the puck re-arms this alarm one minute later, over and over, until you scan."
                            : "Behaves like a normal alarm. Stop ends it."
                    )
                }

                if !isNew {
                    Section {
                        Button("Delete Alarm", role: .destructive) {
                            AlarmScheduler.cancel(id: draft.id)
                            store.delete(id: draft.id)
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(isNew ? "Add Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .tint(Theme.accent)
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                }
            }
            .alert(
                "Alarm not scheduled",
                isPresented: Binding(
                    get: { schedulingError != nil },
                    set: { if !$0 { schedulingError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { schedulingError = nil }
            } message: {
                Text(schedulingError ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Saves, then waits for AlarmKit to accept the alarm before closing. Dismissing first
    /// and scheduling afterwards would put the user back on a list that claims the alarm
    /// is set while the scheduling call is still in flight — or has already failed.
    private func save() async {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        draft.hour = components.hour ?? 7
        draft.minute = components.minute ?? 0
        if draft.label.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.label = "Alarm"
        }

        store.upsert(draft)

        isSaving = true
        defer { isSaving = false }

        guard draft.isEnabled else {
            AlarmScheduler.cancel(id: draft.id)
            store.clearSchedulingFailure(for: draft.id)
            dismiss()
            return
        }

        if let message = await AlarmScheduler.schedule(draft, recordingIn: store) {
            schedulingError = message
            return
        }
        dismiss()
    }
}

private struct RepeatPicker: View {
    @Binding var selection: Set<Weekday>

    var body: some View {
        List {
            Section {
                ForEach(Weekday.displayOrder) { day in
                    Button {
                        if selection.contains(day) {
                            selection.remove(day)
                        } else {
                            selection.insert(day)
                        }
                    } label: {
                        HStack {
                            Text(day.shortName).foregroundStyle(Theme.primaryText)
                            Spacer()
                            if selection.contains(day) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Weekdays") { selection = Weekday.weekdays }
                Button("Weekends") { selection = Weekday.weekend }
                Button("Every day") { selection = Set(Weekday.allCases) }
                Button("Never") { selection = [] }
            }
            .tint(Theme.accent)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Repeat")
        .navigationBarTitleDisplayMode(.inline)
    }
}
