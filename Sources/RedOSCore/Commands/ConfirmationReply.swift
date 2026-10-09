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
