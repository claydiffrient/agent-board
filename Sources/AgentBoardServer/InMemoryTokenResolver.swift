import Foundation

public actor InMemoryTokenResolver: TokenResolver {
    private var identities: [String: TokenIdentity] = [:]

    public init(_ identities: [TokenIdentity] = []) {
        for identity in identities {
            self.identities[identity.token] = identity
        }
    }

    public func add(_ identity: TokenIdentity) {
        identities[identity.token] = identity
    }

    public func remove(token: String) {
        identities[token] = nil
    }

    public func resolve(token: String) -> TokenIdentity? {
        identities[token]
    }
}
