import SwiftUI
import HourglassCore

/// Editable history of all recorded sessions. Shared by the macOS Log window and
/// the iOS Log tab. Supports view / add / edit / delete (full CRUD).
struct LogView: View {
    @Bindable var model: AppModel
    @State private var editing: FocusSession?
    @State private var isAdding = false

    var body: some View {
        Group {
            if model.logEntries.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Completed focus sessions and breaks show up here. Tap + to add one manually.")
                )
            } else {
                List {
                    ForEach(model.logEntries) { session in
                        Button { editing = session } label: {
                            LogRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.deleteSession(id: session.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = session }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteSession(id: session.id)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { isAdding = true }
            }
            if !model.logEntries.isEmpty {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear All", systemImage: "trash", role: .destructive) {
                        model.clearHistory()
                    }
                }
            }
        }
        .sheet(item: $editing) { session in
            SessionEditView(session: session, onSave: model.updateSession)
        }
        .sheet(isPresented: $isAdding) {
            SessionEditView(
                session: FocusSession(
                    kind: .focus,
                    plannedDuration: model.settings.focusDuration,
                    startedAt: Date(),
                    endedAt: Date(),
                    completed: true
                ),
                isNew: true,
                onSave: model.addSession
            )
        }
    }
}

private struct LogRow: View {
    let session: FocusSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.kind.symbolName)
                .foregroundStyle(session.kind.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.kind.displayName)
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TimeFormatting.humanDuration(session.plannedDuration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Add/edit sheet for a single session.
private struct SessionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FocusSession
    let isNew: Bool
    let onSave: (FocusSession) -> Void

    init(session: FocusSession, isNew: Bool = false, onSave: @escaping (FocusSession) -> Void) {
        _draft = State(initialValue: session)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $draft.kind) {
                    ForEach(SessionKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                DatePicker("Started", selection: $draft.startedAt)
                Stepper("Duration: \(minutes) min", value: minutesBinding, in: 1...180)
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add Session" : "Edit Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.endedAt = draft.startedAt.addingTimeInterval(draft.plannedDuration)
                        onSave(saved)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 340)
    }

    private var minutes: Int { Int((draft.plannedDuration / 60).rounded()) }
    private var minutesBinding: Binding<Int> {
        Binding(
            get: { Int((draft.plannedDuration / 60).rounded()) },
            set: { draft.plannedDuration = TimeInterval($0 * 60) }
        )
    }
}
