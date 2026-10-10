import Foundation

/// Spoken yes/no answers to a pending confirmation.
public enum ConfirmationReply {
    private static let yesReplies: Set<String> = [
        "sì", "si", "conferma", "confermo", "ok", "okay", "vai", "procedi", "esegui", "certo",
        "yes", "yeah", "yep", "confirm", "go", "go ahead", "do it", "sure",
    ]
    private static let noReplies: Set<String> = [
        "no", "annulla", "lascia stare", "stop", "fermati", "cancel", "nope", "never mind",
    ]

    /// true = confirm, false = cancel, nil = not a yes/no reply.
    public static func parse(_ text: String) -> Bool? {
        let reply = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if yesReplies.contains(reply) { return true }
        if noReplies.contains(reply) { return false }
        return nil
    }
}

/// Phrases that end a spoken conversation ("grazie", "basta così").
public enum ClosingReply {
    private static let replies: Set<String> = [
        "grazie", "grazie mille", "ok grazie", "perfetto grazie", "basta", "basta così", "basta cosi",
        "niente", "nient'altro", "niente altro", "no grazie", "a posto", "è tutto", "fine",
        "thanks", "thank you", "thanks a lot", "ok thanks", "that's all", "that's it", "nothing", "no thanks",
        "nothing else", "done",
    ]

    public static func matches(_ text: String) -> Bool {
        let reply = text.lowercased()
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return replies.contains(reply)
    }
}
