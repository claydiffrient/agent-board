import AgentBoardCore
import AgentBoardServer
import Foundation

public struct StoreTokenResolver: TokenResolver {
    private let grants: TokenGrantStore

    public init(db: AppDatabase) {
        grants = TokenGrantStore(db)
    }

    public func resolve(token: String) async -> TokenIdentity? {
        guard let grant = try? grants.resolve(token: token),
              let scope = AgentBoardServer.TokenScope(rawValue: grant.scope.rawValue)
        else { return nil }
        return TokenIdentity(
            token: grant.token,
            scope: scope,
            projectId: grant.projectId,
            sessionId: grant.sessionId,
            taskId: grant.taskId
        )
    }
}
