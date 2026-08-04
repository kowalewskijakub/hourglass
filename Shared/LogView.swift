import SwiftUI
import HourglassCore
#if os(macOS)
import AppKit
#endif

/// The unified, editable history: focus sessions, clocked-in stretches and the
/// rests inside them, grouped by day. Hosted as the History segment of Stats on
/// both platforms.
///
/// Two things a plain list could not do live here. **Filtering** — by kind, by
/// span, by text — so a log that grows for months stays answerable. And
/// **selection**, so the answer can be acted on in one go rather than one swipe
/// at a time. Both are drawn inside the segment rather than in Stats' toolbar,
/// which is deliberately identical across segments (see `StatisticsView`).
struct LogView: View {
    @Bindable var model: AppModel
    /// Owned by Stats, so the Add button can live in one unchanging toolbar
    /// rather than appearing when this segment does — which resized the macOS
    /// window every time the user switched.
    @Binding var isAdding: Bool

    @State private var filter = HistoryFilter()
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    /// The last row picked outright, which a shift-click extends *from*.
    @State private var selectionAnchor: UUID?
    @State private var isConfirmingBulkDelete = false
    @State private var editingSession: FocusSession?
    @State private var editingClock: ClockSession?
    @State private var editingBreak: BreakEdit?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: OrbitPalette { .system(colorScheme) }

    var body: some View {
        let log = model.log
        let result = log.filtered(by: filter)

        VStack(spacing: 0) {
            header(result: result)
            Divider().overlay(palette.hairline)
            content(log: log, result: result)
        }
        // No title and no toolbar of its own: History is a segment of Stats,
        // not a screen the user navigated into, and Stats owns both.
        .confirmationDialog(
            deleteConfirmationTitle(count: result.selectableIDs.intersection(selection).count),
            isPresented: $isConfirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected(in: log) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
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

    // MARK: - Content

    @ViewBuilder
    private func content(log: WorkdayLog, result: FilteredHistory) -> some View {
        if log.workdays.isEmpty {
            ContentUnavailableView(
                "Nothing logged yet",
                systemImage: "clock.badge.questionmark",
                description: Text("Focus sessions, breaks and clock-ins show up here. Tap + to add one manually.")
            )
        } else if result.isEmpty {
            // Deliberately not the same screen as the one above: "you have no
            // history" and "your filter matched none of it" are different
            // problems, and only one of them has a button that fixes it.
            ContentUnavailableView {
                Label("No matching entries", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing in the log matches the filters you've set.")
            } actions: {
                Button("Clear filters") { filter = .none }
            }
        } else {
            entries(result)
        }
    }

    #if os(macOS)
    /// A plain scroller, deliberately **not** a `List`.
    ///
    /// SwiftUI backs a sectioned `List` with `NSOutlineView` on the Mac, and the
    /// log is rewritten by things happening elsewhere in the app: clocking in
    /// adds a whole section, scrubbing past a focus that ran long enough records
    /// a row, a sync pull rewrites a day. Each of those asked the table to diff
    /// itself while it was already laying out, and the re-entrant update threw
    /// an AutoLayout exception inside `-[NSTableRowData endUpdates]` — an
    /// uncaught ObjC exception during `NSView` layout, which AppKit turns into
    /// an immediate crash. The workarounds this view accumulated (a fixed-height
    /// header, unanimated filter changes, replacing the table on every section
    /// change) each closed one route into that update without closing the rest.
    ///
    /// A `LazyVStack` has no incremental update to re-enter: rows are rebuilt
    /// from the current log like any other SwiftUI view, and selection is drawn
    /// rather than negotiated with AppKit.
    ///
    /// Headers are **not** pinned. `pinnedViews` makes a header stick by lifting
    /// it out of its slot in the flow and offsetting it, and the slot it leaves
    /// behind stays reserved — so a day whose rows are shorter than the header's
    /// travel showed a band of empty page where the header used to be. A day
    /// title that scrolls away with its own day is worth more than one that
    /// follows you at the cost of holes in the list.
    private func entries(_ result: FilteredHistory) -> some View {
        let order = result.orderedSelectableIDs
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(result.groups) { group in
                    Section {
                        ForEach(Array(group.children.enumerated()), id: \.element.id) { index, child in
                            // Padding belongs inside the row, not around it: the
                            // tap that picks a row is bound to the row, so a
                            // gutter added out here would be a dead strip down
                            // both sides of a list whose whole job is selection.
                            row(for: child, in: order)
                                .background(rowBackground(child.id))
                                .overlay(alignment: .bottom) {
                                    if index < group.children.count - 1 {
                                        Rectangle()
                                            .fill(palette.hairline)
                                            .frame(height: 1)
                                            .padding(.horizontal, 20)
                                    }
                                }
                        }
                    } header: {
                        sectionHeader(group, in: order)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// The pinned day header. Opaque on purpose — it sits over the rows as they
    /// scroll under it, and a translucent one would leave them legible through it.
    private func sectionHeader(_ group: FilteredHistory.Group, in order: [UUID]) -> some View {
        Group {
            if let clockSession = group.clockSession {
                workdayHeader(clockSession, group: group, in: order)
            } else {
                Text("Outside a workday")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
        .background(palette.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.hairline).frame(height: 1)
        }
    }
    #else
    private func entries(_ result: FilteredHistory) -> some View {
        let order = result.orderedSelectableIDs
        return List {
            ForEach(result.groups) { group in
                Section {
                    ForEach(group.children) { child in
                        row(for: child, in: order)
                            .listRowBackground(rowBackground(child.id))
                            .listRowSeparatorTint(palette.hairline)
                    }
                } header: {
                    if let clockSession = group.clockSession {
                        workdayHeader(clockSession, group: group, in: order)
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
        .id(sectionIdentity(result))
    }
    #endif

    #if !os(macOS)
    /// Rebuild the list, rather than let UIKit diff it, whenever the *set of
    /// sections* changes.
    ///
    /// Filtering removes whole days at once, which changes how much content the
    /// table holds and so whether it needs a scroller. The scroller appearing
    /// resizes the table, the table handles that resize while it is still
    /// applying the row updates from the same change, and re-entering
    /// `endUpdates` throws (`NSTableView superviewFrameChanged:` on the way into
    /// `_updateFrameForRowView:`). Replacing the table sidesteps the
    /// incremental update entirely.
    ///
    /// Keyed on sections only, deliberately: deleting a single row leaves the
    /// section set alone and keeps its animation and scroll position, which is
    /// the case that has always worked.
    private func sectionIdentity(_ result: FilteredHistory) -> Int {
        var hasher = Hasher()
        // Entering selection mode re-lays out every row (each grows a tick), so
        // it belongs to the same class of change.
        hasher.combine(isSelecting)
        for group in result.groups {
            hasher.combine(group.id)
            hasher.combine(group.headerMatches)
            hasher.combine(group.children.isEmpty)
        }
        return hasher.finalize()
    }
    #endif

    /// Ember, not the system accent. A picked row should look like it belongs to
    /// the same app as the timer that recorded it, and the accent colour is
    /// whatever the user set system-wide — which was as likely to fight the
    /// ember and stone in the row as to agree with them.
    @ViewBuilder
    private func rowBackground(_ id: UUID) -> some View {
        if isSelecting, selection.contains(id) {
            Color.orbitEmber.opacity(palette.isNight ? 0.16 : 0.10)
        } else {
            Color.clear
        }
    }

    // MARK: - Header

    /// Three rows of a **fixed height**, in both modes.
    ///
    /// The height stays constant so the rows below never move when the header's
    /// contents change: a summary line that appeared only while filtering, and a
    /// selection bar that replaced all three rows, each shifted the whole log
    /// down the moment the user touched a control.
    ///
    /// Keeping the filters visible while selecting is also the better answer:
    /// what you picked and what you filtered to are the same question.
    private func header(result: FilteredHistory) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if isSelecting {
                selectionBar(result: result)
            } else {
                HStack(spacing: 9) {
                    searchField
                    // A chip, like everything else in this bar. The stock
                    // bordered button was the one control on the screen drawn in
                    // the system's language rather than the app's.
                    OrbitChipButton(symbol: "checklist", title: "Select") {
                        isSelecting = true
                        selectionAnchor = nil
                    }
                    .disabled(result.isEmpty)
                    .opacity(result.isEmpty ? 0.4 : 1)
                    .help("Pick rows to export or delete — shift-click for a range")
                }
            }

            // The range sits outside the scroller, because a filter the user
            // has to swipe sideways to discover is one they never find. Kinds
            // scroll; "when" is always on screen.
            HStack(spacing: 8) {
                rangeMenu
                Rectangle().fill(palette.hairline).frame(width: 1, height: 16)
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(HistoryKind.allCases) { kind in
                            kindChip(kind)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 8) {
                Text(summaryLine(result))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Button("Clear") { filter = .none }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orbitEmber)
                    .opacity(filter.isActive ? 1 : 0)
                    .disabled(!filter.isActive)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(filter.searchText.isEmpty ? palette.inkSecondary : Color.orbitEmber)
            TextField("Search history", text: $filter.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !filter.searchText.isEmpty {
                Button {
                    filter.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            Capsule()
                .fill(palette.isNight ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                .overlay(Capsule().stroke(palette.hairline, lineWidth: 1))
        )
    }

    private func kindChip(_ kind: HistoryKind) -> some View {
        let isOn = filter.kinds.contains(kind)
        return OrbitChipButton(
            symbol: kind.symbolName,
            title: kind.title,
            tint: kind.tint,
            isOn: isOn
        ) {
            toggle(kind)
        }
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    private var rangeMenu: some View {
        Menu {
            Picker("Range", selection: $filter.range) {
                ForEach(HistoryRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.inline)
        } label: {
            OrbitChip(
                symbol: "calendar",
                title: filter.range.title,
                tint: .orbitEmber,
                isOn: filter.range != .all
            )
        }
        .historyMenuChrome()
        .accessibilityLabel("Date range")
    }

    /// "12 of 48 · 3h 20m focus · 45m rest" — what a filter kept, and out of how
    /// much. A list that silently shortens looks like data loss; the denominator
    /// is what says it isn't. Unfiltered it drops the denominator and just
    /// counts, so the line is present at a constant height either way.
    private func summaryLine(_ result: FilteredHistory) -> String {
        var parts = [
            filter.isActive
                ? String(localized: "\(result.entryCount) of \(result.totalEntryCount)")
                : (result.entryCount == 1
                    ? String(localized: "1 entry")
                    : String(localized: "\(result.entryCount) entries")),
        ]
        if result.workdayCount > 0 {
            parts.append(
                result.workdayCount == 1
                    ? String(localized: "1 workday")
                    : String(localized: "\(result.workdayCount) workdays")
            )
        }
        if result.focusDuration > 0 {
            parts.append(String(localized: "\(TimeFormatting.humanDuration(result.focusDuration)) focus"))
        }
        if result.breakDuration > 0 {
            parts.append(String(localized: "\(TimeFormatting.humanDuration(result.breakDuration)) rest"))
        }
        return parts.joined(separator: " · ")
    }

    /// Deliberately unanimated. Toggling a chip inserts and removes whole
    /// sections, and animating that diff is the other half of what AppKit's
    /// table update cannot survive.
    private func toggle(_ kind: HistoryKind) {
        // An empty set means "everything" in the core, so deselecting the last
        // chip lands back on an unfiltered list instead of a blank one.
        if filter.kinds.contains(kind) {
            filter.kinds.remove(kind)
        } else {
            filter.kinds.insert(kind)
        }
    }

    // MARK: - Selection bar

    private func selectionBar(result: FilteredHistory) -> some View {
        let selectable = result.selectableIDs
        let picked = selection.intersection(selectable)
        let allSelected = !selectable.isEmpty && picked.count == selectable.count

        return HStack(spacing: 9) {
            OrbitChipButton(symbol: "chevron.backward", title: "Done") { endSelecting() }

            Text(picked.isEmpty
                 ? String(localized: "Shift-click for a range")
                 : String(localized: "\(picked.count) selected"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(picked.isEmpty ? palette.inkSecondary : Color.orbitEmber)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            OrbitChipButton(
                symbol: allSelected ? "circle" : "checkmark.circle",
                title: allSelected ? "None" : "All"
            ) {
                selection = allSelected ? [] : selectable
                selectionAnchor = nil
            }
            .disabled(selectable.isEmpty)
            .opacity(selectable.isEmpty ? 0.4 : 1)

            CSVExportButton(
                title: "Export",
                help: "Export the selected rows as CSV",
                filenameSuffix: "selection",
                style: .chip
            ) {
                model.log.exportCSV(ids: picked)
            }
            .disabled(picked.isEmpty)
            .opacity(picked.isEmpty ? 0.4 : 1)

            Button {
                isConfirmingBulkDelete = true
            } label: {
                OrbitChip(symbol: "trash", title: "Delete", tint: .red, isOn: !picked.isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(picked.isEmpty)
            .opacity(picked.isEmpty ? 0.4 : 1)
        }
    }

    /// What is selected *and* still on screen.
    ///
    /// Narrowing the filter while selecting hides rows, and a row the user can
    /// no longer see they picked must not be counted, exported or deleted. This
    /// is read at the point of use rather than pruned in an `onChange`, because
    /// writing state back during the pass that changed the rows re-enters
    /// AppKit's table update — the same fault the header height had.
    private func visibleSelection(_ log: WorkdayLog) -> Set<UUID> {
        selection.intersection(log.filtered(by: filter).selectableIDs)
    }

    private func deleteConfirmationTitle(count: Int) -> LocalizedStringKey {
        count == 1 ? "Delete 1 entry?" : "Delete \(count) entries?"
    }

    /// Deleting a workday takes its breaks with it, which is why the log — not
    /// this view — decides what a set of ids actually means.
    private func deleteSelected(in log: WorkdayLog) {
        for target in log.targets(for: visibleSelection(log)) {
            switch target {
            case .session(let id):
                model.deleteSession(id: id)
            case .clockSession(let id):
                model.deleteClockSession(id: id)
            case .workBreak(let sessionID, let entryID):
                model.deleteBreak(sessionID: sessionID, entryID: entryID)
            }
        }
        endSelecting()
    }

    /// Pick a row — or, with shift held, everything between the last row picked
    /// outright and this one.
    ///
    /// The range is taken from the *drawn* order (`orderedSelectableIDs`), not
    /// from the stores, so what gets picked is what the user saw between the two
    /// clicks, whatever the filter is currently hiding. Extending never
    /// deselects: shift-clicking is how you say "and these too".
    private func pick(_ id: UUID, in order: [UUID]) {
        if isExtendingSelection,
           let anchor = selectionAnchor,
           let from = order.firstIndex(of: anchor),
           let to = order.firstIndex(of: id) {
            selection.formUnion(order[min(from, to)...max(from, to)])
            return
        }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        selectionAnchor = id
    }

    /// Whether shift was down as the row was clicked. SwiftUI's tap gesture
    /// carries no modifiers, so the flags are read at the moment of the click —
    /// which is what lets this list pick a range the way every other Mac list
    /// does instead of demanding one click per row.
    private var isExtendingSelection: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    private func endSelecting() {
        isSelecting = false
        selection.removeAll()
        selectionAnchor = nil
    }

    // MARK: - Rows

    /// A workday section header — the container the nested items belong to.
    private func workdayHeader(
        _ session: ClockSession,
        group: FilteredHistory.Group,
        in order: [UUID]
    ) -> some View {
        // A header shown only to date the rows under it isn't a hit, so it is
        // neither tickable nor swept up by "All".
        let isSelectable = isSelecting && group.headerMatches
        let isSelected = selection.contains(session.id)

        return HStack(spacing: 9) {
            if isSelecting {
                selectionMark(isSelected: isSelected, isEnabled: isSelectable)
            }
            // The day is the one ember thing in the header: it is the workday,
            // and every total under it is time spent inside it.
            Image(systemName: OrbitIcon.clock.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orbitEmber)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle(session.clockedInAt))
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text(headerDetail(session, group: group))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.inkSecondary)
            }
            Spacer(minLength: 8)
            Text(TimeFormatting.humanDuration(session.netDuration()))
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.orbitEmber)
        }
        .textCase(nil)
        .opacity(isSelecting && !group.headerMatches ? 0.55 : 1)
        .padding(.vertical, 2)
        // The Mac draws its own log rather than hosting a List (see `entries`),
        // so the inset a section header would have been given comes from here —
        // inside the hit area, so the whole strip is tickable.
        #if os(macOS)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        #endif
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                guard isSelectable else { return }
                pick(session.id, in: order)
            } else {
                editingClock = session
            }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editingClock = session }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.deleteClockSession(id: session.id)
            }
        }
    }

    /// "09:12 – 17:40 · 4 focus · 2 rests". The clock range alone said when the
    /// day ran; the counts say what is folded up underneath it, which is the
    /// thing a collapsed section otherwise hides.
    private func headerDetail(_ session: ClockSession, group: FilteredHistory.Group) -> String {
        var parts = [clockRange(session)]
        let focusCount = group.children.filter { $0.historyKind == .focus }.count
        let restCount = group.children.count - focusCount
        if focusCount > 0 {
            parts.append(
                focusCount == 1 ? String(localized: "1 focus") : String(localized: "\(focusCount) focus")
            )
        }
        if restCount > 0 {
            parts.append(
                restCount == 1 ? String(localized: "1 rest") : String(localized: "\(restCount) rests")
            )
        }
        return parts.joined(separator: " · ")
    }

    /// Focus rows are ember; every work break — Pomodoro or manual — is stone,
    /// because they are the same kind of interval in the totals above. A break
    /// phase and the rest it opened are one row, named by its source.
    @ViewBuilder
    private func row(for child: LogEntry, in order: [UUID]) -> some View {
        switch child {
        case .session(let session):
            LogRow(
                symbol: child.historyKind.symbolName,
                tint: session.kind.tint,
                title: session.kind.phaseName,
                subtitle: session.taskLabel ?? (session.kind.isBreak ? breakSource(session.kind) : nil),
                duration: TimeFormatting.humanDuration(session.plannedDuration),
                range: range(from: session.startedAt, duration: session.plannedDuration),
                isSelecting: isSelecting,
                isSelected: selection.contains(session.id)
            )
            .modifier(LogRowActions(
                isSelecting: isSelecting,
                select: { pick(session.id, in: order) },
                edit: { editingSession = session },
                delete: { model.deleteSession(id: session.id) }
            ))

        case .workBreak(let sessionID, let entry, let source):
            LogRow(
                symbol: child.historyKind.symbolName,
                tint: SessionKind.shortBreak.tint,
                title: breakTitle(source),
                subtitle: breakSource(source),
                duration: TimeFormatting.humanDuration(entry.duration()),
                range: range(from: entry.startedAt, duration: entry.duration()),
                isSelecting: isSelecting,
                isSelected: selection.contains(entry.id)
            )
            .modifier(LogRowActions(
                isSelecting: isSelecting,
                select: { pick(entry.id, in: order) },
                edit: { editingBreak = BreakEdit(sessionID: sessionID, entry: entry) },
                delete: { model.deleteBreak(sessionID: sessionID, entryID: entry.id) }
            ))
        }
    }

    /// A scheduled rest is a "Focus break" whichever length it was; a rest the
    /// user started by hand is just a "Break".
    private func breakTitle(_ source: SessionKind?) -> String {
        source == nil ? String(localized: "Break") : String(localized: "Focus break")
    }

    /// Names *where the rest came from*, in the same two words the filter chips
    /// use. It used to read "Pomodoro short break" under a row already titled
    /// "Short break", which spent a whole line saying nothing.
    private func breakSource(_ source: SessionKind?) -> String {
        source == nil ? String(localized: "Manual") : String(localized: "Pomodoro")
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

/// The tick a row carries in selection mode. Disabled means "this row is here
/// for context" rather than "this row refused you" — hence a hollow, dimmed
/// mark rather than no mark at all, which would read as a missing control.
private func selectionMark(isSelected: Bool, isEnabled: Bool) -> some View {
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 15.5))
        .foregroundStyle(isSelected ? Color.orbitEmber : Color.secondary.opacity(isEnabled ? 0.7 : 0.3))
        .accessibilityHidden(true)
}

/// Identifies which break is being edited (a break lives inside a clock session).
private struct BreakEdit: Identifiable {
    let sessionID: ClockSession.ID
    let entry: WorkBreak
    var id: UUID { entry.id }
}

/// A kind mark, the title and any source metadata, and the duration over the
/// time range on the trailing edge.
///
/// The duration used to sit inside the title ("Focus · 25m"); moved out, the row
/// has one column to scan for *what* and one for *how long*, which is how a long
/// day gets read at a glance rather than word by word.
private struct LogRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    let duration: String
    let range: String
    var isSelecting: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if isSelecting {
                selectionMark(isSelected: isSelected, isEnabled: true)
            }
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(duration)
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                Text(range)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        // See `LogView.workdayHeader`: on the Mac the row owns its own inset so
        // that the padding is part of what a click can land on.
        #if os(macOS)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        #endif
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
    }
}

/// Tap, swipe-to-delete and context menu, shared by every log row.
///
/// In selection mode a tap picks the row instead of opening its editor, and the
/// swipe is withdrawn: a destructive gesture and a multi-select gesture on the
/// same row is how one of them gets fired by accident.
private struct LogRowActions: ViewModifier {
    let isSelecting: Bool
    let select: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    func body(content: Content) -> some View {
        content
            .onTapGesture(perform: isSelecting ? select : edit)
            // Swipe belongs to the list that can draw it. The Mac's log is a
            // plain scroller (see `LogView.entries`), where the modifier has
            // nothing to attach to and the context menu is the idiom anyway.
            #if os(iOS)
            .swipeActions(edge: .trailing) {
                if !isSelecting {
                    Button(role: .destructive, action: delete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            #endif
            .contextMenu {
                if !isSelecting {
                    Button("Edit", systemImage: "pencil", action: edit)
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                }
            }
    }
}

// MARK: - Filter vocabulary

/// Two colours, not five, exactly as everywhere else: work is ember, rest is
/// stone. The chips carry an icon each so the two ember chips are still told
/// apart without reading the label.
private extension HistoryKind {
    var title: LocalizedStringKey {
        switch self {
        case .workday: return "Workdays"
        case .focus: return "Focus"
        case .pomodoroBreak: return "Pomodoro"
        case .manualBreak: return "Manual"
        }
    }

    var symbolName: String {
        switch self {
        case .workday: return OrbitIcon.clock.symbolName
        case .focus: return OrbitIcon.focus.symbolName
        case .pomodoroBreak, .manualBreak: return OrbitIcon.cup.symbolName
        }
    }

    var tint: Color {
        isBreak ? .orbitStone : .orbitEmber
    }
}

private extension HistoryRange {
    var title: LocalizedStringKey {
        switch self {
        case .all: return "Any time"
        case .today: return "Today"
        case .last7: return "Last 7 days"
        case .last30: return "Last 30 days"
        case .thisMonth: return "This month"
        }
    }
}

private extension View {
    /// A menu that reads as one of the chips beside it rather than as a system
    /// pop-up button, which on the Mac would be the loudest thing in the bar.
    @ViewBuilder
    func historyMenuChrome() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        #else
        menuIndicator(.hidden)
        #endif
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
