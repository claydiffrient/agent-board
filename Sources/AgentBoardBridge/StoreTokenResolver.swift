import AgentBoardCore
import AgentBoardServer
import Foundation

public struct StoreTokenResolver: TokenResolver {
    private let grants: TokenGrantStore

    public init(db: AppDatabase) {
        grants = TokenGrantStore(db)
    }

    public func resolve(token: String) async -> TokenIdentity? {
        Self.identity(try? grants.resolve(token: token))
    }

    public func resolveIncludingRevoked(token: String) async -> TokenIdentity? {
        Self.identity(try? grants.lookup(token: token))
    }

    private static func identity(_ grant: TokenGrant?) -> TokenIdentity? {
        guard let grant, let scope = AgentBoardServer.TokenScope(rawValue: grant.scope.rawValue) else { return nil }
        return TokenIdentity(
            token: grant.token,
            scope: scope,
            projectId: grant.projectId ?? "",
            sessionId: grant.sessionId,
            taskId: grant.taskId,
            revoked: grant.isRevoked
        )
    }
}
