import Foundation

/// What the Notes search field hands `NoteStore.search` (SPEC §10, Notes).
public enum NoteSearch {
    /// A search field's text as an FTS5 query that always parses: every whitespace-separated term
    /// a quoted literal matched as a token prefix, all of them required. So "idl" already finds
    /// "idle", and `cap:`, `AND` or an unbalanced quote are searched for rather than parsed. A term
    /// with no letter or digit gives the tokenizer nothing to match and is dropped; nil when no
    /// term is left, which means "no query", not "no match".
    public static func ftsQuery(_ text: String) -> String? {
        let terms = text.split(whereSeparator: \.isWhitespace).filter { term in
            term.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        guard !terms.isEmpty else { return nil }
        return terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }
}
