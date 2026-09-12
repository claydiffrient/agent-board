import Foundation
import GRDB

public struct TokenGrantStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func issue(projectId: String, scope: TokenScope, taskId: String?) throws -> TokenGrant {
        let grant = TokenGrant(
            token: Self.randomToken(),
            sessionId: nil,
            projectId: projectId,
            scope: scope,
            taskId: taskId,
            createdAt: .nowMillis
        )
        try db.writer.write { db in try grant.insert(db) }
        return grant
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public func bind(token: String, sessionId: String) throws {
        try db.writer.write { db in
            let updated = try Self.bind(db, token: token, sessionId: sessionId)
            if !updated { throw BoardError.tokenNotFound(token) }
        }
    }

    static func bind(_ db: Database, token: String, sessionId: String) throws -> Bool {
        try db.execute(
            sql: "UPDATE token_grant SET session_id = ? WHERE token = ?",
            arguments: [sessionId, token]
        )
        return db.changesCount > 0
    }

    public func resolve(token: String) throws -> TokenGrant? {
        try db.reader.read { db in
            try TokenGrant.fetchOne(
                db,
                sql: "SELECT * FROM token_grant WHERE token = ? AND revoked_at IS NULL",
                arguments: [token]
            )
        }
    }

    public func revoke(token: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE token_grant SET revoked_at = ? WHERE token = ? AND revoked_at IS NULL",
                arguments: [Int64.nowMillis, token]
            )
        }
    }

    public func revokeAll(sessionId: String) throws {
        try db.writer.write { db in
            try Self.revokeAll(db, sessionId: sessionId)
        }
    }

    static func revokeAll(_ db: Database, sessionId: String) throws {
        try db.execute(
            sql: "UPDATE token_grant SET revoked_at = ? WHERE session_id = ? AND revoked_at IS NULL",
            arguments: [Int64.nowMillis, sessionId]
        )
    }

    public func forSession(_ sessionId: String) throws -> [TokenGrant] {
        try db.reader.read { db in
            try TokenGrant.fetchAll(
                db,
                sql: "SELECT * FROM token_grant WHERE session_id = ? ORDER BY created_at",
                arguments: [sessionId]
            )
        }
    }
}
