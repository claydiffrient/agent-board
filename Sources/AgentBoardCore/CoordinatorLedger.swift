import Foundation

/// One request as the Coordinator page's Requests section draws it (SPEC §10).
public struct CoordinatorLedgerRow: Identifiable, Sendable, Equatable {
    public struct EpicLink: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public let id: Int64
    public let projectId: String
    public let projectName: String
    public let summary: String
    public let state: RequestState
    /// The newest text an orchestrator wrote for this request; nil until it has replied.
    public let latestReply: String?
    public let epics: [EpicLink]

    public init(
        id: Int64, projectId: String, projectName: String, summary: String, state: RequestState,
        latestReply: String?, epics: [EpicLink]
    ) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.summary = summary
        self.state = state
        self.latestReply = latestReply
        self.epics = epics
    }
}

public enum CoordinatorLedger {
    public static let summaryLength = 120

    /// Keeps the ledger's order. An epic link whose epic is not in `epics` is dropped.
    public static func rows(_ entries: [RequestLedgerEntry], epics: [Epic]) -> [CoordinatorLedgerRow] {
        let titles = Dictionary(epics.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return entries.compactMap { entry in
            guard let id = entry.request.id else { return nil }
            return CoordinatorLedgerRow(
                id: id,
                projectId: entry.request.projectId,
                projectName: entry.projectName,
                summary: summary(entry.request.body),
                state: entry.request.state,
                latestReply: entry.history.last(where: { $0.author == .orchestrator })?.body,
                epics: entry.epicIds.compactMap { epicId in
                    titles[epicId].map { CoordinatorLedgerRow.EpicLink(id: epicId, title: $0) }
                }
            )
        }
    }

    /// The first non-empty line, cut at `summaryLength` characters with an ellipsis.
    public static func summary(_ body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > summaryLength else { return line }
        return String(line.prefix(summaryLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension RequestState {
    public var title: String {
        switch self {
        case .sent: "Sent"
        case .accepted: "Accepted"
        case .declined: "Declined"
        case .done: "Done"
        case .withdrawn: "Withdrawn"
        }
    }
}
