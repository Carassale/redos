import Foundation

/// Commands about RedOS itself: routines and memory. Recognized before any action, in Italian and English.
public enum MetaCommand: Sendable, Equatable {
    case createRoutine(name: String, body: String)
    case runRoutine(String)
    case deleteRoutine(String)
    case listRoutines
    case scheduleRoutine(String, Schedule)
    case runRoutineOnLaunch(String, app: String)
    case remember(String)
    case forget(String)
    case recall
    /// "segnala un problema: …", "richiesta allo sviluppatore: …"; the text may be empty.
    case feedback(Feedback.Kind, String)
    /// "prendi appunti" (true) / "smetti di prendere appunti" (false).
    case takeNotes(Bool)
    /// "d'ora in poi rispondimi breve", "quando uso Slack, scrivi in inglese".
    case addBehavior(rule: String, app: String?)
    case listBehaviors
    /// "dimentica la regola sulle risposte brevi"; "" removes them all.
    case removeBehaviors(String)
    /// "fammi il briefing", "com'è la mia giornata?".
    case briefing
    /// "manda la minuta ai partecipanti": a Mail draft with the last call's minutes.
    case sendMinutes
    /// "crea i promemoria delle azioni": one reminder per action item of the last call.
    case minutesReminders
    private typealias Builder = @Sendable ([String]) -> MetaCommand?

    private static let quote = "[\"'“”«»]?"
    private static let weekdays = "(\\s+(?:nei\\s+)?giorni\\s+(?:feriali|lavorativi)|\\s+on\\s+weekdays)?"
    private static let time = "(\\d{1,2})(?:[:.](\\d{2}))?\\s*(am|pm)?"

    /// Order matters: the trigger and schedule forms must win over a plain "run routine X", rules over "forget X".
    private static let patterns: [(String, Builder)] = behaviorPatterns + notesPatterns + corePatterns

    private static let corePatterns: [(String, Builder)] = [
        (
            "^(?:crea|salva|registra|create|save|make|record)\\s+(?:la\\s+|una\\s+|a\\s+|the\\s+|new\\s+)?routine\\s+"
                + "\(quote)(.+?)\(quote)\\s*(?::|\\s+che\\s+|\\s+con\\s+|\\s+that\\s+|\\s+to\\s+)\\s*(.+)$",
            { .createRoutine(name: $0[0], body: $0[1]) }
        ),
        (
            "^(?:avvia|esegui|lancia|run|start)\\s+(?:la\\s+|the\\s+|my\\s+)?routine\\s+\(quote)(.+?)\(quote)\\s+"
                + "(?:quando\\s+(?:apro|avvio|si\\s+apre|parte)|when\\s+(?:i\\s+open|i\\s+launch|opening))\\s+(.+?)"
                + "(?:\\s+(?:opens|starts|launches))?$",
            { .runRoutineOnLaunch($0[0], app: $0[1]) }
        ),
        (
            "^(?:programma|pianifica|schedule)\\s+(?:la\\s+|the\\s+|my\\s+)?routine\\s+\(quote)(.+?)\(quote)\\s+"
                + "(?:ogni\\s+giorno\\s+)?(?:alle|per\\s+le|at|daily\\s+at|every\\s+day\\s+at)\\s+\(time)\(weekdays)$",
            { parts in schedule(parts).map { .scheduleRoutine(parts[0], $0) } }
        ),
        (
            "^(?:avvia|esegui|lancia|fai\\s+partire|run|start|play)\\s+(?:la\\s+|the\\s+|my\\s+)?routine\\s+"
                + "\(quote)(.+?)\(quote)$",
            { .runRoutine($0[0]) }
        ),
        ("^routine\\s+\(quote)(.+?)\(quote)$", { .runRoutine($0[0]) }),
        (
            "^(?:elimina|cancella|rimuovi|delete|remove)\\s+(?:la\\s+|the\\s+|my\\s+)?routine\\s+"
                + "\(quote)(.+?)\(quote)$",
            { .deleteRoutine($0[0]) }
        ),
        (
            "^(?:(?:quali|che)\\s+routine\\s+(?:ho|ci\\s+sono)|(?:elenca|mostra|mostrami)\\s+(?:le\\s+)?routine"
                + "|(?:list|show)\\s+(?:my\\s+|the\\s+)?routines|what\\s+routines\\s+do\\s+i\\s+have)\\??$",
            { _ in .listRoutines }
        ),
        ("^(?:ricorda|ricordati|tieni\\s+a\\s+mente)\\s+che\\s+(.+)$", { .remember($0[0]) }),
        ("^remember\\s+(?:that\\s+)?(.+)$", { .remember($0[0]) }),
        ("^(?:dimentica|scordati|forget)\\s+(?:che\\s+|that\\s+|di\\s+|about\\s+)?(.+)$", { .forget($0[0]) }),
        (
            "^(?:(?:che\\s+)?cosa\\s+(?:ricordi|sai\\s+di\\s+me)"
                + "|what\\s+do\\s+you\\s+(?:remember|know\\s+about\\s+me))\\??$",
            { _ in .recall }
        ),
        (
            "^(?:segnala|riporta|invia|manda)\\s+(?:un\\s+|il\\s+|questo\\s+|lo\\s+)?"
                + "(?:problema|errore|bug|feedback)(?:\\s+allo\\s+sviluppatore)?\\s*[:,.-]?\\s*(.*)$",
            { .feedback(.problem, $0[0]) }
        ),
        (
            "^(?:report|send)\\s+(?:a\\s+|the\\s+|this\\s+)?(?:problem|bug|issue|error|feedback)"
                + "(?:\\s+to\\s+the\\s+developer)?\\s*[:,.-]?\\s*(.*)$",
            { .feedback(.problem, $0[0]) }
        ),
        (
            "^(?:(?:invia|manda|fai|scrivi)\\s+(?:una\\s+|un\\s+)?)?(?:richiesta|proposta|suggerimento|idea)"
                + "\\s+(?:allo|al|per\\s+lo)\\s+sviluppatore\\s*[:,.-]?\\s*(.*)$",
            { .feedback(.request, $0[0]) }
        ),
        ("^chiedi\\s+allo\\s+sviluppatore\\s+(?:di\\s+)?(.+)$", { .feedback(.request, $0[0]) }),
        (
            "^(?:feature\\s+request|request\\s+a\\s+feature|suggest\\s+a\\s+feature"
                + "|send\\s+a\\s+request\\s+to\\s+the\\s+developer|ask\\s+the\\s+developer(?:\\s+to)?)"
                + "\\s*[:,.-]?\\s*(.*)$",
            { .feedback(.request, $0[0]) }
        ),
        (
            "^(?:prendi|inizia\\s+a\\s+prendere|comincia\\s+a\\s+prendere)\\s+(?:gli\\s+|degli\\s+|le\\s+)?"
                + "(?:appunti|note)(?:\\s+(?:della|di\\s+questa|in\\s+questa)\\s+(?:call|riunione|chiamata))?$",
            { _ in .takeNotes(true) }
        ),
        (
            "^(?:take|start\\s+taking)\\s+(?:some\\s+)?(?:notes|minutes)"
                + "(?:\\s+(?:of|for|in|during)\\s+(?:this|the)\\s+(?:call|meeting))?$",
            { _ in .takeNotes(true) }
        ),
        (
            "^(?:(?:smetti|finisci|termina)\\s+di\\s+prendere"
                + "|(?:basta|stop|fine)\\s+(?:con\\s+)?(?:gli\\s+|degli\\s+)?)"
                + "\\s*(?:gli\\s+)?appunti$",
            { _ in .takeNotes(false) }
        ),
        ("^(?:stop|finish|end)\\s+(?:taking\\s+)?(?:the\\s+)?(?:notes|minutes)$", { _ in .takeNotes(false) }),
    ]

    public static func parse(_ input: String) -> MetaCommand? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        for (pattern, build) in patterns {
            guard let regex = try? Regex(pattern).ignoresCase(),
                  let match = try? regex.wholeMatch(in: text)
            else { continue }
            let captures = match.output.dropFirst().map { $0.substring.map(String.init) ?? "" }
            if let command = build(captures.map { $0.trimmingCharacters(in: .whitespaces) }) {
                return command
            }
        }
        return nil
    }

    /// Captures: name, hour, minute, am/pm, weekdays.
    private static func schedule(_ parts: [String]) -> Schedule? {
        guard var hour = Int(parts[1]) else { return nil }
        let minute = Int(parts[2]) ?? 0
        switch parts[3].lowercased() {
        case "pm" where hour < 12: hour += 12
        case "am" where hour == 12: hour = 0
        default: break
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return Schedule(hour: hour, minute: minute, weekdaysOnly: !parts[4].isEmpty)
    }
}
