import Foundation

// MARK: - After a call ("manda la minuta", "crea i promemoria delle azioni")

extension MetaCommand {
    private static let lastCall = #"(?:\s+(?:della|dell['’]ultima|di\s+questa|di\s+quella)\s+"#
        + #"(?:call|riunione|chiamata|minuta))?"#
    private static let lastMeeting = #"(?:\s+(?:of|from)\s+(?:the\s+|this\s+|that\s+)?(?:last\s+)?(?:call|meeting))?"#
    private static let italianItems = #"(?:le\s+)?(?:azioni|attività|cose\s+da\s+fare|action\s+items?)"#
    private static let englishItems = #"(?:the\s+)?(?:action\s+items|actions|tasks|to-?dos)"#

    static let notesPatterns: [(String, @Sendable ([String]) -> MetaCommand?)] = [
        (
            #"^(?:manda|invia|spedisci|inoltra|condividi)\s+(?:la\s+|il\s+|gli\s+)?"#
                + #"(?:minuta|verbale|resoconto|appunti)"#
                + lastCall
                + #"(?:\s+(?:ai\s+partecipanti|a\s+tutti(?:\s+i\s+partecipanti)?))?"#
                + #"(?:\s+(?:via|per)\s+(?:e-?mail|mail|posta))?$"#,
            { _ in .sendMinutes }
        ),
        (
            #"^(?:send|email|e-mail|mail|share)\s+(?:out\s+)?(?:the\s+)?(?:minutes|meeting\s+notes|notes)"#
                + lastMeeting
                + #"(?:\s+to\s+(?:everyone|the\s+participants|all\s+(?:the\s+)?participants|the\s+attendees))?"#
                + #"(?:\s+by\s+e-?mail)?$"#,
            { _ in .sendMinutes }
        ),
        (
            #"^(?:crea|aggiungi|metti|fai|imposta)\s+(?:i\s+|dei\s+)?promemoria\s+"#
                + #"(?:per\s+|delle\s+|dalle\s+|con\s+|sulle\s+)?"# + italianItems + lastCall + "$",
            { _ in .minutesReminders }
        ),
        (
            #"^(?:aggiungi|metti|salva|trasforma)\s+"# + italianItems + lastCall
                + #"\s+(?:ai|nei|tra\s+i|in)\s+promemoria$"#,
            { _ in .minutesReminders }
        ),
        (
            #"^(?:create|add|make|set)\s+(?:the\s+|some\s+)?reminders\s+(?:for|from)\s+"# + englishItems
                + lastMeeting + "$",
            { _ in .minutesReminders }
        ),
        (
            #"^(?:add|put|turn)\s+"# + englishItems + lastMeeting + #"\s+(?:to|into)\s+(?:my\s+)?reminders$"#,
            { _ in .minutesReminders }
        ),
    ]
}

/// Questions about past calls: a call word plus a past cue ("cosa abbiamo deciso nella call di ieri?"),
/// not "che riunioni ho oggi?" (the calendar).
public enum MeetingQuestion {
    private static let callWords = #"\b(?:call|riunione|riunioni|meeting|meetings|chiamata|chiamate|minuta|verbale)\b"#
    private static let pastCues = #"\b(?:ieri|stamattina|scors[oa]|ultima|secondo|abbiamo|hanno|avete|detto|"#
        + #"dett[oaie]|decis[oaie]|discuss[oaie]|parlato|concordat[oaie]|stabilit[oaie]|emers[oaie]|minuta|"#
        + #"verbale|yesterday|this\s+morning|last|according\s+to|did|decided|discussed|said|agreed|talked|"#
        + #"came\s+up)\b"#
    private static let questionStart = #"^(?:cosa|che|chi|quando|quale|quali|come|perch[eé]|abbiamo|"#
        + #"riassumi|riassumimi|ricordami\s+(?:cosa|chi|quando)|what|who|when|which|how|why|did|"#
        + #"summari[sz]e|remind\s+me\s+(?:what|who|when))\b"#

    public static func matches(_ input: String) -> Bool {
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(regex(callWords)), text.contains(regex(pastCues)) else { return false }
        return text.hasSuffix("?") || text.contains(regex(questionStart))
    }

    private static func regex(_ pattern: String) -> Regex<AnyRegexOutput> {
        // swiftlint:disable:next force_try
        try! Regex(pattern)
    }
}
