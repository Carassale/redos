import Foundation

public enum NameMatcher {
    /// Index of the best candidate: exact match, then shortest prefix match, then shortest substring match.
    public static func bestMatch(for query: String, in candidates: [String]) -> Int? {
        let target = normalize(query)
        guard !target.isEmpty else { return nil }
        let names = candidates.map(normalize)
        if let exact = names.firstIndex(of: target) { return exact }
        return shortest(names.indices.filter { names[$0].hasPrefix(target) }, in: names)
            ?? shortest(names.indices.filter { names[$0].contains(target) }, in: names)
    }

    private static func shortest(_ indices: [Int], in names: [String]) -> Int? {
        indices.min { names[$0].count < names[$1].count }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
