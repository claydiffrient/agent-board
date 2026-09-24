import Foundation

/// A GitHub pull request URL found in text, such as the progress row an approved
/// `open_pull_request` writes or an open landing's detail.
public struct PullRequestReference: Sendable, Equatable {
    public var url: String
    public var number: Int

    public init(url: String, number: Int) {
        self.url = url
        self.number = number
    }

    public init?(in text: String) {
        guard let match = text.firstMatch(of: #/https://[^\s()]+/pull/(\d+)/#),
              let number = Int(match.1)
        else { return nil }
        self.init(url: String(match.0), number: number)
    }
}
