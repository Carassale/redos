public enum RouteDecision: Sendable, Equatable {
    case action(ActionRequest, confidence: Double)
    /// No single action fits: a question, a conversation or something not supported.
    case noAction(confidence: Double)
    /// Several actions in sequence: handed to the System Two planner.
    case multiStep(confidence: Double)
    case uncertain(actionID: String, confidence: Double)
    /// Request kinds recognized by `JevIntentRouter`: handled without a System Two planning call.
    case screenQuestion(confidence: Double)
    case screenTask(confidence: Double)
    case research(confidence: Double)
    case diagram(confidence: Double)
}

public protocol CommandRouting: Sendable {
    func prepare() async
    func route(_ input: String) async throws -> RouteDecision
}

public struct SystemOneRouter: CommandRouting {
    public static let noneLabel = "none"
    public static let multiStepLabel = "multi_step"

    private let registry: ActionRegistry
    private let systemOne: any SystemOne
    private let extractor: ArgumentExtractor
    private let warmUp: [any ChatCompleting]
    private let threshold: Double
    private let chainsExtraction: Bool
    private let examples: [(command: String, label: String)]

    /// `chainsExtraction` reuses the decision conversation for the argument call (same model only).
    public init(
        registry: ActionRegistry,
        systemOne: any SystemOne,
        extractor: ArgumentExtractor,
        warmUp: [any ChatCompleting],
        threshold: Double = 0.5,
        chainsExtraction: Bool = true,
        examples: [(command: String, label: String)] = SystemOneRouter.defaultExamples
    ) {
        self.registry = registry
        self.systemOne = systemOne
        self.extractor = extractor
        self.warmUp = warmUp
        self.threshold = threshold
        self.chainsExtraction = chainsExtraction
        self.examples = examples
    }

    public var question: JevChoiceQuestion {
        let actions = registry.all.map { JevOption(label: $0.id, description: $0.summary) }
        let multiStep = JevOption(
            label: Self.multiStepLabel,
            description: "Several of the actions above in sequence (e.g. open an app and then go to a website in it),"
                + " or on-screen elements described by position or look (e.g. the first result)."
        )
        let none = JevOption(
            label: Self.noneLabel,
            description: "None of the above: questions, conversation, or actions not listed"
                + " (e.g. screenshots, emptying the trash, shutting down)."
        )
        let options = actions + [multiStep, none]
        let labels = Set(options.map(\.label))
        let examples = self.examples.filter { labels.contains($0.label) }
            .map { "- \"\($0.command)\" -> \($0.label)" }
            .joined(separator: "\n")
        return JevChoiceQuestion(
            instructions: "Pick the single action that fulfils the user's command on their Mac."
                + (examples.isEmpty ? "" : "\nExamples (command -> option):\n\(examples)"),
            options: options
        )
    }

    /// Few-shot guidance in Italian and English; with prefix caching it costs nothing after the first command.
    /// Kept distinct from eval/commands.jsonl.
    public static let defaultExamples: [(command: String, label: String)] = [
        ("lancia Spotify", "app.open"), ("I want to use Xcode", "app.open"), ("mostrami Finder", "app.open"),
        ("chiudi Telegram", "app.quit"), ("get out of Zoom", "app.quit"), ("spegni Music", "app.quit"),
        ("apri il sito ansa.it", "url.open"), ("load nytimes.com", "url.open"),
        ("digita ciao Marco", "text.type"), ("write: on my way", "text.type"),
        ("type hello in this box", "text.type"), ("scrivi qui a domani", "text.type"),
        ("scendi di qualche riga", "scroll"), ("torna in cima", "scroll"), ("scroll a bit left", "scroll"),
        ("clicca col tasto destro", "mouse.click"), ("do a click", "mouse.click"), ("clicca lì adesso", "mouse.click"),
        ("sposta il puntatore a 300, 200", "mouse.move"),
        ("tocca il bottone Invia", "ui.press"), ("hit Cancel", "ui.press"), ("apri il menu Modifica", "ui.press"),
        ("metti mario nel campo utente", "ui.fill"), ("enter my email in the Email box", "ui.fill"),
        ("cosa dice questa finestra?", "ui.read"), ("read me this page", "ui.read"),
        ("fai git status nel terminale", "shell.run"), ("list the files in Downloads", "shell.run"),
        ("apri Mail e scrivi ciao", "multi_step"), ("open Notes then type groceries", "multi_step"),
        ("apri il primo risultato", "multi_step"), ("compila il modulo", "multi_step"),
        ("che giorno è oggi?", "none"), ("tell me a joke", "none"), ("svuota il cestino", "none"),
        ("abbassa un po' l'audio", "volume.set"), ("volume at 70", "volume.set"), ("togli l'audio", "volume.set"),
        ("abbassa la luminosità", "brightness.set"), ("make the screen brighter", "brightness.set"),
        ("metti un po' di musica", "media.control"), ("skip this song", "media.control"),
        ("attiva il tema scuro", "appearance.set"), ("lock my Mac", "screen.lock"),
        ("esegui il comando rapido Casa", "shortcut.run"), ("run the Focus shortcut", "shortcut.run"),
        ("affianca la finestra a destra", "window.arrange"), ("minimize the window", "window.arrange"),
        ("dov'è il file del contratto?", "file.find"), ("apri il documento preventivo", "file.open"),
        ("cosa ho in agenda oggi?", "calendar.agenda"), ("remind me to buy milk tomorrow", "reminder.add"),
        ("scrivi una mail a Paolo per il pranzo", "mail.draft"),
    ]

    public func prepare() async {
        await withTaskGroup { group in
            for client in warmUp {
                group.addTask { await client.preload() }
            }
        }
    }

    public func route(_ input: String) async throws -> RouteDecision {
        let question = question
        let answer = try await systemOne.choose(question, state: input)
        if answer.choice == Self.noneLabel {
            return .noAction(confidence: answer.probability)
        }
        if answer.choice == Self.multiStepLabel {
            return .multiStep(confidence: answer.probability)
        }
        guard answer.probability >= threshold, let action = registry.action(for: answer.choice) else {
            return .uncertain(actionID: answer.choice, confidence: answer.probability)
        }
        let context = chainsExtraction ? systemOne.transcript(for: question, state: input, answer: answer) : []
        let arguments = try await extractor.arguments(for: action, input: input, context: context)
        return .action(ActionRequest(action.id, arguments), confidence: answer.probability)
    }
}
