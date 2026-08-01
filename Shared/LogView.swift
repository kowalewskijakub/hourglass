import SwiftUI
import HourglassCore

/// The unified, editable history: focus sessions, clocked-in stretches and the
/// rests inside them, grouped by day. Hosted as the History segment of Stats on
/// both platforms.
struct LogView: View {
    @Bindable var model: AppModel
    /// Owned by Stats, so the Add button can live in one unchanging toolbar
    /// rather than appearing when this segment does — which resized the macOS
    /// window every time the user switched segments.
    @Binding var isAdding: Bool
    @State private var editingSession: FocusSession?
    @State private var editingClock: ClockSession?
    @State private var editingBreak: BreakEdit?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: OrbitPalette { .system(colorScheme) }

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
                                    .listRowBackground(Color.clear)
                                    .listRowSeparatorTint(palette.hairline)
                            }
                        } header: {
                            if let clockSession = group.clockSession {
                                workdayHeader(clockSession)
                            } else {
                                Text("Outside a workday")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(palette.inkSecondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        // No title and no toolbar of its own: History is a segment of Stats,
        // not a screen the user navigated into, and Stats owns both.
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
            VStack(alignment: .leading, spacing: 1) {
                Text(dayTitle(session.clockedInAt))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text(clockRange(session))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.inkSecondary)
            }
            Spacer()
            Text(TimeFormatting.humanDuration(session.netDuration()))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.inkSecondary)
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

    /// Focus rows are ember; every work break — Pomodoro or manual — is stone,
    /// because they are the same kind of interval in the totals above. A break
    /// phase and the rest it opened are one row, named by its source.
    @ViewBuilder
    private func row(for child: LogEntry) -> some View {
        switch child {
        case .session(let session):
            LogRow(
                tint: session.kind.tint,
                title: "\(session.kind.displayName) · \(TimeFormatting.humanDuration(session.plannedDuration))",
                subtitle: session.kind.isBreak ? breakSource(session.kind) : nil,
                range: range(from: session.startedAt, duration: session.plannedDuration)
            )
            .modifier(LogRowActions(
                edit: { editingSession = session },
                delete: { model.deleteSession(id: session.id) }
            ))

        case .workBreak(let sessionID, let entry, let source):
            LogRow(
                tint: SessionKind.shortBreak.tint,
                title: "\(breakTitle(source)) · \(TimeFormatting.humanDuration(entry.duration()))",
                subtitle: breakSource(source),
                range: range(from: entry.startedAt, duration: entry.duration())
            )
            .modifier(LogRowActions(
                edit: { editingBreak = BreakEdit(sessionID: sessionID, entry: entry) },
                delete: { model.deleteBreak(sessionID: sessionID, entryID: entry.id) }
            ))
        }
    }

    private func breakTitle(_ source: SessionKind?) -> String {
        switch source {
        case .shortBreak: return String(localized: "Short break")
        case .longBreak: return String(localized: "Long break")
        default: return String(localized: "Break")
        }
    }

    private func breakSource(_ source: SessionKind?) -> String {
        switch source {
        case .shortBreak: return String(localized: "Pomodoro short break")
        case .longBreak: return String(localized: "Pomodoro long break")
        default: return String(localized: "Manual break")
        }
    }

    private func range(from start: Date, duration: TimeInterval) -> String {
        let end = start.addingTimeInterval(duration)
        return "\(TimeFormatting.timeOfDay(start))–\(TimeFormatting.timeOfDay(end))"
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

/// A state dot, the title and duration, optional source metadata, and the time
/// range on the trailing edge.
private struct LogRow: View {
    let tint: Color
    let title: String
    let subtitle: String?
    let range: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(range)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
