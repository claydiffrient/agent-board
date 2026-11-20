/// How every pull request or issue number is shown: `#13408` or `owner/repo#13408`, never with a
/// locale's grouping separator. A SwiftUI literal interpolating the Int would format it as `#13,408`.
public enum IssueReference {
    public static func short(_ number: some BinaryInteger) -> String { "#" + String(number) }

    public static func short(_ number: Int?) -> String { number.map { short($0) } ?? "#?" }

    public static func full(owner: String, repo: String, _ number: some BinaryInteger) -> String {
        full(repository: owner + "/" + repo, number)
    }

    public static func full(owner: String?, repo: String?, _ number: Int?) -> String {
        full(repository: (owner ?? "?") + "/" + (repo ?? "?"), number)
    }

    public static func full(repository: String, _ number: some BinaryInteger) -> String { repository + short(number) }

    public static func full(repository: String?, _ number: Int?) -> String { (repository ?? "?") + short(number) }
}
