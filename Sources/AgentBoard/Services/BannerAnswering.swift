import AgentBoardCore
import Foundation
import UserNotifications

/// The one Inbox question a banner can answer in place: an approval it can deny, or a pull request
/// decision it can reply to (SPEC §15.6). `questionAt` is the episode the banner announced, so a reply
/// typed into a stale banner never answers a newer asking.
struct BannerQuestion: Equatable, Hashable {
    enum Kind: String, CaseIterable {
        case approval
        case prDecision

        var inboxKind: InboxItemKind {
            switch self {
            case .approval: .approval
            case .prDecision: .prDecision
            }
        }

        var verdict: InboxVerdict {
            switch self {
            case .approval: .deny
            case .prDecision: .reply
            }
        }

        var categoryIdentifier: String { "agentboard.answer.\(rawValue)" }
        var actionIdentifier: String { "agentboard.answer.\(rawValue).\(verdict.title)" }

        var category: UNNotificationCategory {
            let action = switch self {
            case .approval:
                UNTextInputNotificationAction(
                    identifier: actionIdentifier, title: "Deny…", options: [],
                    textInputButtonTitle: "Deny", textInputPlaceholder: "Why you are denying it"
                )
            case .prDecision:
                UNTextInputNotificationAction(
                    identifier: actionIdentifier, title: "Reply…", options: [],
                    textInputButtonTitle: "Record reply", textInputPlaceholder: "Your answer, posted only by Post reply"
                )
            }
            return UNNotificationCategory(identifier: categoryIdentifier, actions: [action], intentIdentifiers: [])
        }
    }

    var kind: Kind
    var subjectId: String
    var questionAt: Int64

    init(kind: Kind, subjectId: String, questionAt: Int64) {
        self.kind = kind
        self.subjectId = subjectId
        self.questionAt = questionAt
    }

    init?(_ item: InboxItem) {
        guard let kind = Kind.allCases.first(where: { $0.inboxKind == item.kind }) else { return nil }
        self.init(kind: kind, subjectId: item.subjectId, questionAt: item.questionAt)
    }

    static var categories: Set<UNNotificationCategory> { Set(Kind.allCases.map(\.category)) }

    func matches(_ item: InboxItem) -> Bool {
        item.kind == kind.inboxKind && item.subjectId == subjectId && item.questionAt == questionAt
    }

    enum Key {
        static let kind = "agentboard.question.kind"
        static let subjectId = "agentboard.question.subjectId"
        static let questionAt = "agentboard.question.at"
    }

    var userInfo: [String: String] {
        [Key.kind: kind.rawValue, Key.subjectId: subjectId, Key.questionAt: String(questionAt)]
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = (userInfo[Key.kind] as? String).flatMap(Kind.init(rawValue:)),
              let subjectId = userInfo[Key.subjectId] as? String, !subjectId.isEmpty,
              let questionAt = (userInfo[Key.questionAt] as? String).flatMap(Int64.init)
        else { return nil }
        self.init(kind: kind, subjectId: subjectId, questionAt: questionAt)
    }
}

/// Answers a banner's question through `InboxAnswering`, the Inbox Answer zone's own path, so the two
/// cannot drift. Writes nothing unless that exact episode is still open in the Inbox.
@MainActor
struct BannerAnswering {
    enum Outcome: Equatable {
        case answered
        /// Answered in the Inbox or from another banner, resolved by Approve, or asked again since.
        case notOpen
        case needsNote
        case failed(String)
    }

    let db: AppDatabase
    let supervisor: any WorkerSupervising

    func answer(_ question: BannerQuestion, text: String) async -> Outcome {
        guard let note = text.nilIfBlank else { return .needsNote }
        do {
            guard let item = try InboxStore(db).items().first(where: question.matches) else { return .notOpen }
            let context = try InboxRowContext.load(db, item: item)
            try await InboxAnswering(db: db, supervisor: supervisor)
                .answer(question.kind.verdict, to: item, context: context, note: note)
            return .answered
        } catch {
            return .failed(String(describing: error))
        }
    }
}
