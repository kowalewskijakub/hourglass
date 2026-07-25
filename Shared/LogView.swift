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
        Group {
            if model.logDays.isEmpty {
                ContentUnavailableView(
                    "Nothing logged yet",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Focus sessions, breaks and clock-ins show up here. Tap + to add one manually.")
                )
            } else {
                List {
                    ForEach(model.logDays) { day in
                        Section(dayTitle(day.date)) {
                            ForEach(day.items) { item in
                                row(for: item)
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
            if !model.logDays.isEmpty {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear All", systemImage: "trash", role: .destructive) {
                        model.clearHistory()
                    }
                }
            }
        }
        .sheet(item: $editingSession) { session in
            SessionEditView(session: session, onSave: model.updateSession)
        }
        .sheet(item: $editingClock) { session in
            ClockEditView(session: session, onSave: model.updateClockSession)
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

    @ViewBuilder
    private func row(for item: LogItem) -> some View {
        switch item {
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

        case .clock(let clockSession):
            LogRow(
                icon: clockSession.isActive ? "clock.badge.checkmark" : "clock",
                tint: .blue,
                title: clockSession.isActive ? "Clocked in" : "Workday",
                subtitle: clockRange(clockSession),
                trailing: TimeFormatting.humanDuration(clockSession.netDuration())
            )
            .modifier(LogRowActions(
                edit: { editingClock = clockSession },
                delete: { model.deleteClockSession(id: clockSession.id) }
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
        EditSheet(title: isNew ? "Add Session" : "Edit Session") {
            Picker("Type", selection: $draft.kind) {
                ForEach(SessionKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            DatePicker("Started", selection: $draft.startedAt)
            Stepper("Duration: \(minutes) min", value: minutesBinding, in: 1...240)
        } onSave: {
            var saved = draft
            saved.endedAt = draft.startedAt.addingTimeInterval(draft.plannedDuration)
            onSave(saved)
            dismiss()
        } onCancel: { dismiss() }
    }

    private var minutes: Int { Int((draft.plannedDuration / 60).rounded()) }
    private var minutesBinding: Binding<Int> {
        Binding(
            get: { Int((draft.plannedDuration / 60).rounded()) },
            set: { draft.plannedDuration = TimeInterval($0 * 60) }
        )
    }
}

/// Edit sheet for a clocked-in stretch.
private struct ClockEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClockSession
    @State private var stillClockedIn: Bool
    @State private var clockOut: Date
    let onSave: (ClockSession) -> Void

    init(session: ClockSession, onSave: @escaping (ClockSession) -> Void) {
        _draft = State(initialValue: session)
        _stillClockedIn = State(initialValue: session.clockedOutAt == nil)
        _clockOut = State(initialValue: session.clockedOutAt ?? Date())
        self.onSave = onSave
    }

    var body: some View {
        EditSheet(title: "Edit Workday") {
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
        } onSave: {
            var saved = draft
            saved.clockedOutAt = stillClockedIn ? nil : clockOut
            onSave(saved)
            dismiss()
        } onCancel: { dismiss() }
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
        EditSheet(title: "Edit Break") {
            DatePicker("Started", selection: $draft.startedAt)
            Toggle("Still on break", isOn: $stillRunning)
            if !stillRunning {
                DatePicker("Ended", selection: $endedAt)
            }
        } onSave: {
            var saved = draft
            saved.endedAt = stillRunning ? nil : endedAt
            onSave(saved)
            dismiss()
        } onCancel: { dismiss() }
    }
}

/// Shared chrome for the three edit sheets.
private struct EditSheet<Fields: View>: View {
    let title: String
    @ViewBuilder let fields: Fields
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form { fields }
                .formStyle(.grouped)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: onSave)
                    }
                }
        }
        .frame(minWidth: 380, minHeight: 320)
    }
}
