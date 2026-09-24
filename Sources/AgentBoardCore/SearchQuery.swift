import Foundation

/// A search field's text as the terms a match must contain. Every term has to appear somewhere
/// among the fields, case- and diacritic-insensitively, but not all in the same one — so "idle cap"
/// finds a task titled "Idle timeout" whose body mentions the cap.
public struct SearchQuery: Sendable, Equatable {
    public let terms: [String]

    public init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func matches(_ fields: [String?]) -> Bool {
        matches(folded: Self.haystack(fields))
    }

    /// Against text already passed through `haystack`. Folding once and searching literally is
    /// what makes a query cheap: `range(of:options:)` with case and diacritic folding costs ~115ns
    /// a byte, 87ms for one pass over the largest real board.
    public func matches(folded haystack: String) -> Bool {
        var haystack = haystack
        return haystack.withUTF8 { hay in
            foldedTerms.allSatisfy { term in Self.contains(hay, Array(term.utf8)) }
        }
    }

    /// A byte search. Both sides are already folded, and `String.contains` compares by grapheme,
    /// which measured 17ms for a pass this does in well under one.
    private static func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first else { return true }
        guard hay.count >= needle.count, let base = hay.baseAddress else { return false }
        var start = 0
        let last = hay.count - needle.count
        return needle.withUnsafeBufferPointer { needle in
            while start <= last {
                guard let hit = memchr(base + start, Int32(first), last - start + 1) else { return false }
                let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                if memcmp(base + at, needle.baseAddress!, needle.count) == 0 { return true }
                start = at + 1
            }
            return false
        }
    }

    /// Fields joined on a newline, which no term contains, so a term never matches across two fields.
    public static func haystack(_ fields: [String?]) -> String {
        fold(fields.compactMap(\.self).joined(separator: "\n"))
    }

    private var foldedTerms: [String] { terms.map(Self.fold) }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// What the Task Board's search reaches on a task (SPEC §10). An in-memory filter over the rows the
/// board already observes. Folding the largest real board's text, 235 tasks and 793 KB, costs 17ms
/// in a debug build, so `IndexCache` does it once per change to its inputs; matching costs 2.5ms.
public enum TaskSearch {
    /// Title, body, acceptance criteria, the epic's title, the model (id and display name), and the
    /// rostered agents that last worked and reviewed it. Not the task id: a hex id turns short
    /// words like "bad" or "face" into spurious matches.
    public static func fields(
        of task: BoardTask, epicTitles: [String: String], agentNames: [String: String]
    ) -> [String?] {
        [
            task.title,
            task.body,
            task.acceptance,
            task.epicId.flatMap { epicTitles[$0] },
            task.model,
            task.model.flatMap { ModelCatalog.option(for: $0)?.name },
            task.rosterAgentId.flatMap { agentNames[$0] },
            task.reviewerAgentId.flatMap { agentNames[$0] },
        ]
    }

    public static func filter(
        _ tasks: [BoardTask], query: SearchQuery,
        epicTitles: [String: String], agentNames: [String: String]
    ) -> [BoardTask] {
        guard !query.isEmpty else { return tasks }
        return filter(tasks, query: query, index: Index(tasks, epicTitles: epicTitles, agentNames: agentNames))
    }

    public static func filter(_ tasks: [BoardTask], query: SearchQuery, index: Index) -> [BoardTask] {
        guard !query.isEmpty else { return tasks }
        return tasks.filter { task in index.haystacks[task.id].map(query.matches(folded:)) ?? false }
    }

    /// Every task's searchable text, folded once.
    public struct Index: Sendable, Equatable {
        public let haystacks: [String: String]

        /// How many indexes this process has built, so a test can see a render that builds one.
        public private(set) static var builds = 0

        public init(_ tasks: [BoardTask], epicTitles: [String: String], agentNames: [String: String]) {
            haystacks = Dictionary(
                tasks.map { ($0.id, SearchQuery.haystack(fields(of: $0, epicTitles: epicTitles, agentNames: agentNames))) },
                uniquingKeysWith: { first, _ in first }
            )
            Self.builds += 1
        }
    }

    /// The last `Index` built and the inputs it was built from, so the board rebuilds it only when
    /// its tasks, epic titles or agent names change. A class, so a view can hold it in `@State` and
    /// refresh it from `body` without invalidating itself.
    public final class IndexCache {
        private var inputs: Inputs?
        private var index: Index?

        private struct Inputs: Equatable {
            let tasks: [BoardTask]
            let epicTitles: [String: String]
            let agentNames: [String: String]
        }

        public init() {}

        public func index(
            _ tasks: [BoardTask], epicTitles: [String: String], agentNames: [String: String]
        ) -> Index {
            let inputs = Inputs(tasks: tasks, epicTitles: epicTitles, agentNames: agentNames)
            if let index, inputs == self.inputs { return index }
            let built = Index(tasks, epicTitles: epicTitles, agentNames: agentNames)
            self.inputs = inputs
            index = built
            return built
        }
    }

    /// The query applied to both halves of the archive split. Search does not override Show
    /// Archived: an archived match stays hidden, but is counted, so the board can say it exists.
    public static func narrow(
        _ partition: ArchivePartition, query: SearchQuery,
        epicTitles: [String: String], agentNames: [String: String]
    ) -> ArchivePartition {
        guard !query.isEmpty else { return partition }
        return narrow(partition, query: query, index: Index(
            partition.visible + partition.hidden, epicTitles: epicTitles, agentNames: agentNames
        ))
    }

    public static func narrow(_ partition: ArchivePartition, query: SearchQuery, index: Index) -> ArchivePartition {
        ArchivePartition(
            visible: filter(partition.visible, query: query, index: index),
            hidden: filter(partition.hidden, query: query, index: index)
        )
    }

    public static func hiddenMatchesNote(count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 archived match hidden"
        default: return "\(count) archived matches hidden"
        }
    }
}
