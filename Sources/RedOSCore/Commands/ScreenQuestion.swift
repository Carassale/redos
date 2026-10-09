import Foundation

/// Questions about what is on screen ("a chi è assegnata questa MR?", "riassumi questa pagina"): they are
/// answered by reading the screen, never by acting on it.
public enum ScreenQuestion {
    /// A question or a request for information at the start of the sentence.
    private static var asks: Regex<Substring> {
        // swiftlint:disable:next force_try
        try! Regex(
            #"^(?:a |di |per |con |da |in |su )?(?:chi|cosa|che|quale|quali|quanto|quanti|quante|quanta|quando|"#
                + #"dove|come|perch[eé]|riassumi(?:mi)?|spiega(?:mi)?|dimmi|dammi|traduci|leggimi|elenca|"#
                + #"what|who|whom|whose|which|how|when|where|why|summari[sz]e|explain|tell me|give me|"#
                + #"translate|list)\b"#
        ).ignoresCase()
    }

    /// "questa pagina", "this PR", "sullo schermo" — but not "questa settimana" or "this year".
    private static var refersToScreen: Regex<Substring> {
        // swiftlint:disable:next force_try
        try! Regex(
            #"\bquest[aoei]\s+(?!settiman|mes|ann|sera|mattin|weekend|giorn|volt|notte)\w|"#
                + #"\b(?:this|these)\s+(?!week|month|year|weekend|morning|evening|afternoon|time|night)\w|"#
                + #"\b(?:sullo schermo|on (?:the |my )?screen|pagina (?:visualizzata|aperta|corrente|attuale)|"#
                + #"current page|finestra (?:aperta|corrente|attuale))\b"#
        ).ignoresCase()
    }

    public static func matches(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.firstMatch(of: asks) != nil && text.firstMatch(of: refersToScreen) != nil
    }
}
