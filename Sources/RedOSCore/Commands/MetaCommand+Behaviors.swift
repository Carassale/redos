import Foundation

// MARK: - Standing instructions ("d'ora in poi…")

extension MetaCommand {
    private static let fromNow = #"(?:d['’]ora\s+in\s+(?:poi|avanti)|da\s+(?:ora|adesso|oggi)\s+in\s+poi"#
        + #"|from\s+now\s+on|going\s+forward)"#
    private static let whenUsing = #"(?:quando\s+(?:sono\s+(?:in|su)|uso|lavoro\s+(?:in|su|con))"#
        + #"|when\s+(?:i'm|i\s+am)\s+(?:in|using)|when\s+i\s+use)"#

    static let behaviorPatterns: [(String, @Sendable ([String]) -> MetaCommand?)] = [
        // "quando uso Slack, scrivi in inglese" / "d'ora in poi, quando uso Slack, …".
        ("^(?:\(fromNow)\\s*,?\\s+)?\(whenUsing)\\s+(.+)$", { scoped($0[0]) }),
        ("^\(fromNow)\\s*[,:]?\\s+(.+)$", { .addBehavior(rule: $0[0], app: nil) }),
        (
            "^(?:(?:quali|che)\\s+regole\\s+(?:hai|segui|ci\\s+sono)"
                + "|(?:elenca|mostra|mostrami)\\s+(?:le\\s+)?regole"
                + "|(?:list|show)\\s+(?:your\\s+|my\\s+|the\\s+)?rules"
                + "|what\\s+rules\\s+do\\s+you\\s+(?:have|follow))\\??$",
            { _ in .listBehaviors }
        ),
        (
            "^(?:dimentica|rimuovi|elimina|cancella|togli)\\s+tutte\\s+le\\s+regole"
                + "|(?:forget|remove|delete)\\s+all\\s+(?:the\\s+|your\\s+)?rules$",
            { _ in .removeBehaviors("") }
        ),
        (
            "^(?:dimentica|rimuovi|elimina|cancella|togli)\\s+(?:la\\s+)?regola\\s+"
                + "(?:sulle\\s+|sulla\\s+|sul\\s+|sui\\s+|su\\s+|di\\s+|che\\s+|per\\s+)?(.+)$",
            { .removeBehaviors($0[0]) }
        ),
        ("^(?:forget|remove|delete)\\s+the\\s+rule\\s+(?:about\\s+|for\\s+|on\\s+)?(.+)$", { .removeBehaviors($0[0]) }),
        (
            "^(?:(?:fammi|dammi|fai)\\s+(?:il\\s+|un\\s+)?briefing|briefing(?:\\s+(?:del\\s+mattino|di\\s+oggi))?"
                + "|com['’]è\\s+(?:la\\s+)?(?:mia\\s+)?giornata(?:\\s+di\\s+oggi)?"
                + "|come\\s+si\\s+presenta\\s+(?:la\\s+)?giornata"
                + "|(?:give\\s+me\\s+)?(?:my\\s+|the\\s+)?(?:daily|morning)\\s+briefing"
                + "|what(?:'s|\\s+is)\\s+my\\s+day\\s+(?:like|looking\\s+like))\\??$",
            { _ in .briefing }
        ),
    ]

    /// "Slack, scrivi in inglese" -> app "Slack"; without a comma the app is the first word.
    private static func scoped(_ text: String) -> MetaCommand? {
        let app: Substring
        var rule: Substring
        if let comma = text.firstIndex(of: ",") {
            app = text[..<comma]
            rule = text[text.index(after: comma)...]
        } else {
            let parts = text.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            (app, rule) = (parts[0], parts[1])
        }
        rule = rule.drop { $0 == " " || $0 == "," }
        // swiftlint:disable:next force_try
        let leading = try! Regex("\(fromNow)\\s*,?\\s*").ignoresCase()
        if let match = rule.prefixMatch(of: leading) {
            rule = rule[match.range.upperBound...]
        }
        let name = app.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !rule.isEmpty else { return nil }
        return .addBehavior(rule: String(rule), app: name)
    }
}
