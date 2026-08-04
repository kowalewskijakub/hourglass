import Foundation

/// What a History row *is*, for the purposes of filtering.
///
/// Deliberately coarser than `SessionKind` on one axis and finer on another: the
/// user does not care whether a rest was short or long (History paints them the
/// same stone, and so do the totals), but they very much care whether the app
/// opened it or they did.
public enum HistoryKind: String, CaseIterable, Sendable, Hashable, Identifiable, Codable {
    case workday
    case focus
    case pomodoroBreak
    case manualBreak

    public var id: String { rawValue }
    public var isBreak: Bool { self == .pomodoroBreak || self == .manualBreak }
}

extension LogEntry {
    /// Which filter bucket this row falls into. A break phase with no interval
    /// behind it is still a Pomodoro break — it is the same rest, recorded by a
    /// version of the app that hadn't linked the two yet.
    public var historyKind: HistoryKind {
        switch self {
        case .session(let session):
            return session.kind == .focus ? .focus : .pomodoroBreak
        case .workBreak(_, _, let source):
            return source == nil ? .manualBreak : .pomodoroBreak
        }
    }

    /// The text a search runs against. Kind names come from the same table the
    /// rows are titled from, so what the user reads is what they can type.
    var searchTerms: [String] {
        switch self {
        case .session(let session):
            return [session.kind.phaseName, session.kind.displayName, session.taskLabel].compactMap { $0 }
        case .workBreak(_, _, let source):
            return ["Break", source?.phaseName, source?.displayName].compactMap { $0 }
        }
    }
}

/// The spans History can be narrowed to. Every one of them is resolved against
/// an injected `now` and calendar, so "last 7 days" means the same thing in a
/// test as it does at 23:58 in Auckland.
public enum HistoryRange: String, CaseIterable, Sendable, Hashable, Identifiable {
    case all
    case today
    case last7
    case last30
    case thisMonth

    public var id: String { rawValue }

    /// The window this range covers, or nil for `all` (which excludes nothing).
    /// Trailing ranges are whole days — a 7-day range ends at midnight tonight,
    /// not at this instant, so a session started an hour ago is inside it.
    public func interval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .all:
            return nil
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .last7:
            return trailing(days: 7, now: now, calendar: calendar)
        case .last30:
            return trailing(days: 30, now: now, calendar: calendar)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        }
    }

    private func trailing(days: Int, now: Date, calendar: Calendar) -> DateInterval? {
        guard let today = calendar.dateInterval(of: .day, for: now),
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: today.start)
        else { return nil }
        return DateInterval(start: start, end: today.end)
    }
}

/// How History is narrowed: free text, which kinds of row to show, and over what
/// span. Value-typed and comparable so a view can diff it and a test can build
/// one without a store.
public struct HistoryFilter: Sendable, Equatable {
    public var searchText: String
    /// Which kinds to show. **Empty means every kind**, not none: deselecting
    /// the last chip is what a user clearing a filter does, and answering that
    /// with a blank screen reads as a bug rather than as an answer.
    public var kinds: Set<HistoryKind>
    public var range: HistoryRange

    public init(
        searchText: String = "",
        kinds: Set<HistoryKind> = [],
        range: HistoryRange = .all
    ) {
        self.searchText = searchText
        self.kinds = kinds
        self.range = range
    }

    public static let none = HistoryFilter()

    /// Whether this filter narrows anything at all — what the UI badges, and
    /// what decides whether a "no matches" state should offer to clear it.
    public var isActive: Bool {
        !trimmedSearch.isEmpty || range != .all || narrowsKinds
    }

    var narrowsKinds: Bool {
        !kinds.isEmpty && kinds.count < HistoryKind.allCases.count
    }

    var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func allows(_ kind: HistoryKind) -> Bool {
        kinds.isEmpty || kinds.contains(kind)
    }

    func matchesSearch(_ terms: [String]) -> Bool {
        let needle = trimmedSearch
        guard !needle.isEmpty else { return true }
        return terms.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// The result of applying a `HistoryFilter` — the groups to draw, plus what the
/// user needs to know about *what got left out*, which is the part a bare list
/// can never tell them.
public struct FilteredHistory: Sendable, Equatable {
    /// One workday and the rows inside it that survived the filter.
    public struct Group: Identifiable, Sendable, Equatable, Hashable {
        public let workday: LogWorkday
        /// True when the workday row itself passed the filter. False means it is
        /// drawn only as context for the children below it — so it is not
        /// selectable, and "select all" does not sweep it up.
        public let headerMatches: Bool

        public var id: UUID { workday.id }
        public var clockSession: ClockSession? { workday.clockSession }
        public var children: [LogEntry] { workday.children }
    }

    public let groups: [Group]
    /// Whether a filter was actually applied, so the UI can tell "nothing
    /// recorded yet" apart from "nothing matches".
    public let isFiltered: Bool
    /// Rows in the whole log, before filtering — the denominator in "12 of 48".
    public let totalEntryCount: Int
    public let entryCount: Int
    public let workdayCount: Int
    public let focusDuration: TimeInterval
    public let breakDuration: TimeInterval
    /// Net worked time of the workdays whose header matched — excluded from the
    /// entry totals above because a workday *contains* the breaks under it, and
    /// adding the two would count the same minutes twice.
    public let workedDuration: TimeInterval

    public var isEmpty: Bool { groups.isEmpty }

    /// Everything a "select all" should select: matching rows, plus the workday
    /// headers that matched in their own right.
    public var selectableIDs: Set<UUID> { Set(orderedSelectableIDs) }

    /// The same set, **in the order they are drawn** — a day's header, then the
    /// rows under it, day after day. Shift-picking a range needs to agree with
    /// what the user sees, which a `Set` cannot answer.
    public var orderedSelectableIDs: [UUID] {
        var ids: [UUID] = []
        for group in groups {
            if group.headerMatches, let clockSession = group.clockSession {
                ids.append(clockSession.id)
            }
            ids += group.children.map(\.id)
        }
        return ids
    }
}

extension WorkdayLog {
    /// Apply a filter, keeping the workday → entries shape.
    ///
    /// A workday whose own row is filtered out still appears when it holds
    /// matching rows: the section header is the only thing saying *which day*
    /// a row belongs to, and dropping it would leave rows floating with no
    /// date. It comes back as context (`headerMatches == false`), not as a hit.
    ///
    /// Searching a day by name is treated as searching *for that day*, so its
    /// children come through on the day's match rather than having to repeat the
    /// text themselves — typing "Monday" and getting an empty Monday would be a
    /// literal reading of the query and a useless answer to the question.
    public func filtered(
        by filter: HistoryFilter,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> FilteredHistory {
        let window = filter.range.interval(now: now, calendar: calendar)
        var groups: [FilteredHistory.Group] = []
        var entryCount = 0
        var workdayCount = 0
        var focusDuration: TimeInterval = 0
        var breakDuration: TimeInterval = 0
        var workedDuration: TimeInterval = 0

        for group in workdays {
            let dayMatchesSearch = group.clockSession.map {
                filter.matchesSearch(Self.searchTerms(forDayOf: $0, locale: locale))
            } ?? false

            let children = group.children.filter { entry in
                guard filter.allows(entry.historyKind) else { return false }
                guard Self.overlaps(window, start: entry.startedAt, duration: entry.duration) else { return false }
                return dayMatchesSearch || filter.matchesSearch(entry.searchTerms)
            }

            let headerMatches: Bool = {
                guard let clockSession = group.clockSession else { return false }
                guard filter.allows(.workday), dayMatchesSearch else { return false }
                return Self.overlaps(
                    window,
                    start: clockSession.clockedInAt,
                    duration: clockSession.grossDuration(asOf: now)
                )
            }()

            guard !children.isEmpty || headerMatches else { continue }

            groups.append(
                FilteredHistory.Group(
                    workday: LogWorkday(clockSession: group.clockSession, children: children),
                    headerMatches: headerMatches
                )
            )
            entryCount += children.count
            for child in children {
                if child.historyKind == .focus {
                    focusDuration += child.duration
                } else {
                    breakDuration += child.duration
                }
            }
            if headerMatches, let clockSession = group.clockSession {
                workdayCount += 1
                workedDuration += clockSession.netDuration(asOf: now)
            }
        }

        return FilteredHistory(
            groups: groups,
            isFiltered: filter.isActive,
            totalEntryCount: workdays.reduce(0) { $0 + $1.children.count },
            entryCount: entryCount,
            workdayCount: workdayCount,
            focusDuration: focusDuration,
            breakDuration: breakDuration,
            workedDuration: workedDuration
        )
    }

    /// A row overlaps the window if any part of it does, so a stretch that began
    /// before the window opened still belongs to the days it ran through.
    ///
    /// The window's end is exclusive: a day's interval runs *to* the following
    /// midnight, so `<=` let a row that starts exactly as tomorrow begins count
    /// as part of today. The start stays inclusive, which is what keeps a
    /// zero-length row sitting exactly on midnight inside its own day.
    private static func overlaps(_ window: DateInterval?, start: Date, duration: TimeInterval) -> Bool {
        guard let window else { return true }
        let end = start.addingTimeInterval(max(0, duration))
        return end >= window.start && start < window.end
    }

    /// What typing a date into the search box can match — the day's name, its
    /// month, and the numeric date, in the user's own language.
    private static func searchTerms(forDayOf session: ClockSession, locale: Locale) -> [String] {
        let date = session.clockedInAt
        return [
            date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(locale)),
            date.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(locale)),
            "Workday",
        ]
    }
}

// MARK: - Acting on a selection

/// What a selected History row points at in the stores. The UI selects opaque
/// ids; this is how those become deletes without a view having to remember
/// which id was which kind of record.
public enum HistoryTarget: Hashable, Sendable {
    case session(FocusSession.ID)
    case clockSession(ClockSession.ID)
    case workBreak(sessionID: ClockSession.ID, entryID: WorkBreak.ID)
}

extension WorkdayLog {
    /// Resolve selected ids against the log.
    ///
    /// A break inside a selected workday is dropped: deleting the workday takes
    /// its breaks with it, and asking the tracker to delete a break out of a
    /// session that no longer exists is at best a no-op. Focus sessions are
    /// *not* dropped the same way — they live in their own store and outlive the
    /// workday that happened to contain them.
    ///
    /// A Pomodoro rest is drawn as **one** row standing for two records — the
    /// rest interval and the break phase paired into it — so selecting that row
    /// resolves to both. Deleting only the interval left the phase in history,
    /// where nothing absorbed it any more, and it came straight back as a
    /// standalone break row: the user pressed Delete and the row stayed.
    public func targets(for ids: Set<UUID>) -> [HistoryTarget] {
        let doomedWorkdays = Set(
            workdays.compactMap { group -> ClockSession.ID? in
                guard let clockSession = group.clockSession, ids.contains(clockSession.id) else { return nil }
                return clockSession.id
            }
        )

        var targets: [HistoryTarget] = doomedWorkdays.map { .clockSession($0) }
        for group in workdays {
            for child in group.children where ids.contains(child.id) {
                switch child {
                case .session(let session):
                    targets.append(.session(session.id))
                case .workBreak(let sessionID, let entry, _):
                    if let phase = phase(pairedInto: entry.id) { targets.append(.session(phase)) }
                    guard !doomedWorkdays.contains(sessionID) else { continue }
                    targets.append(.workBreak(sessionID: sessionID, entryID: entry.id))
                }
            }
        }
        return targets
    }
}
