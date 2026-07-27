import SwiftUI
import HourglassCore

/// The unified, editable history: Pomodoro sessions, clocked-in stretches and
/// non-Pomodoro breaks, grouped by day. Shared by the macOS Log window and the
/// iOS Settings → Session Log screen.
struct LogView: View {
    @Bindable var model: AppModel
    @State private var editingSession: FocusSession?
    @State private var editingClock: ClockSession?
    @State private var editingBreak: BreakEdit?
    @State private var isAdding = false

    var body: some View {
        let workdays = model.log.workdays
        Group {
            if workdays.isEmpty {
                ContentUnavailableView(
                    "Nothing logged yet",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Focus sessions, breaks and clock-ins show up here. Tap + to add one manually.")
                )
            } else {
                List {
                    ForEach(workdays) { group in
                        Section {
                            // Focus sessions and breaks that happened inside this
                            // workday, indented under it.
                            ForEach(group.children) { child in
                                row(for: child)
                            }
                        } header: {
                            if let clockSession = group.clockSession {
                                workdayHeader(clockSession)
                            } else {
                                Text("Outside a workday")
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
            ToolbarItem(placement: .automatic) {
                LogExportButton(model: model)
            }
        }
        .sheet(item: $editingSession) { session in
            SessionEditView(session: session, onSave: model.updateSession)
        }
        .sheet(item: $editingClock) { session in
            ClockEditView(session: session) { clockedInAt, clockedOutAt in
                model.updateClockSession(
                    id: session.id,
                    clockedInAt: clockedInAt,
                    clockedOutAt: clockedOutAt
                )
            }
        }
        .sheet(item: $editingBreak) { edit in
            BreakEditView(entry: edit.entry) { updated in
                model.updateBreak(sessionID: edit.sessionID, entry: updated)
            }
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

    /// A workday section header — the container the nested items belong to.
    private func workdayHeader(_ session: ClockSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.isActive ? "clock.badge.checkmark" : "clock")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(dayTitle(session.clockedInAt))
                    .font(.subheadline.weight(.semibold))
                Text(clockRange(session))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TimeFormatting.humanDuration(session.netDuration()))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editingClock = session }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editingClock = session }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.deleteClockSession(id: session.id)
            }
        }
    }

    @ViewBuilder
    private func row(for child: LogEntry) -> some View {
        switch child {
        case .session(let session):
            LogRow(
                icon: session.kind.symbolName,
                tint: session.kind.tint,
                title: session.kind.displayName,
                subtitle: session.startedAt.formatted(date: .omitted, time: .shortened),
                trailing: TimeFormatting.humanDuration(session.plannedDuration)
            )
            .modifier(LogRowActions(
                edit: { editingSession = session },
                delete: { model.deleteSession(id: session.id) }
            ))

        case .workBreak(let sessionID, let entry):
            LogRow(
                icon: "cup.and.saucer",
                tint: .orange,
                title: "Break",
                subtitle: entry.startedAt.formatted(date: .omitted, time: .shortened),
                trailing: TimeFormatting.humanDuration(entry.duration())
            )
            .modifier(LogRowActions(
                edit: { editingBreak = BreakEdit(sessionID: sessionID, entry: entry) },
                delete: { model.deleteBreak(sessionID: sessionID, entryID: entry.id) }
            ))
        }
    }

    private func clockRange(_ session: ClockSession) -> String {
        let start = session.clockedInAt.formatted(date: .omitted, time: .shortened)
        guard let out = session.clockedOutAt else { return "\(start) – now" }
        return "\(start) – \(out.formatted(date: .omitted, time: .shortened))"
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Identifies which break is being edited (a break lives inside a clock session).
private struct BreakEdit: Identifiable {
    let sessionID: ClockSession.ID
    let entry: WorkBreak
    var id: UUID { entry.id }
}

private struct LogRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailing: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Swipe-to-delete + context menu, shared by every log row.
private struct LogRowActions: ViewModifier {
    let edit: () -> Void
    let delete: () -> Void

    func body(content: Content) -> some View {
        content
            .onTapGesture(perform: edit)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button("Edit", systemImage: "pencil", action: edit)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
    }
}

// MARK: - Editors

/// Add/edit sheet for a Pomodoro session.
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
                Stepper("Duration: \(minutes) min", value: minutesBinding, in: 1...240)
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
        .frame(minWidth: 380, minHeight: 300)
    }

    private var minutes: Int { Int((draft.plannedDuration / 60).rounded()) }
    private var minutesBinding: Binding<Int> {
        Binding(
            get: { Int((draft.plannedDuration / 60).rounded()) },
            set: { draft.plannedDuration = TimeInterval($0 * 60) }
        )
    }
}

/// Edit sheet for a clocked-in stretch. Hands back only the two stamps it edits,
/// never the whole session — the breaks it shows may have moved on since it
/// opened.
private struct ClockEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClockSession
    @State private var stillClockedIn: Bool
    @State private var clockOut: Date
    let onSave: (_ clockedInAt: Date, _ clockedOutAt: Date?) -> Void

    init(session: ClockSession, onSave: @escaping (_ clockedInAt: Date, _ clockedOutAt: Date?) -> Void) {
        _draft = State(initialValue: session)
        _stillClockedIn = State(initialValue: session.clockedOutAt == nil)
        _clockOut = State(initialValue: session.clockedOutAt ?? Date())
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Clocked in", selection: $draft.clockedInAt)
                Toggle("Still clocked in", isOn: $stillClockedIn)
                if !stillClockedIn {
                    DatePicker("Clocked out", selection: $clockOut)
                }
                if !draft.breaks.isEmpty {
                    Text("\(draft.breaks.count) break(s) · \(TimeFormatting.humanDuration(draft.breakDuration()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Workday")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft.clockedInAt, stillClockedIn ? nil : clockOut)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}

/// Edit sheet for a non-Pomodoro break.
private struct BreakEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkBreak
    @State private var stillRunning: Bool
    @State private var endedAt: Date
    let onSave: (WorkBreak) -> Void

    init(entry: WorkBreak, onSave: @escaping (WorkBreak) -> Void) {
        _draft = State(initialValue: entry)
        _stillRunning = State(initialValue: entry.endedAt == nil)
        _endedAt = State(initialValue: entry.endedAt ?? Date())
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Started", selection: $draft.startedAt)
                Toggle("Still on break", isOn: $stillRunning)
                if !stillRunning {
                    DatePicker("Ended", selection: $endedAt)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Break")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.endedAt = stillRunning ? nil : endedAt
                        onSave(saved)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}
