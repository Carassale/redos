import Foundation

public struct ResolvedPlan: Sendable, Equatable {
    public let input: String
    public let steps: [ActionRequest]
    public var route: AuditEntry.Route = .systemTwo
}

/// System Two output: actions to run, or a short reply when nothing should be run.
public struct PlanResult: Sendable, Equatable {
    public let steps: [ActionRequest]
    public let answer: String?
    /// The request needs to look at the screen between steps (handled by the agent).
    public let needsScreen: Bool
    /// A web search query: the question needs current or checkable information (handled by the research agent).
    public let research: String?

    public init(steps: [ActionRequest], answer: String? = nil, needsScreen: Bool = false, research: String? = nil) {
        self.steps = steps
        self.answer = answer
        self.needsScreen = needsScreen
        self.research = research
    }
}

/// System Two: handles what System One cannot (multi-step tasks, questions, unclear commands).
public protocol Planning: Sendable {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult
}

public enum PlanError: Error, Equatable, LocalizedError {
    case tooManySteps(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .tooManySteps(let count): String(localized: "The plan has too many steps (\(count)).")
        case .unreadable: String(localized: "System Two replied with an unreadable plan.")
        }
    }
}

/// Works with any provider: local Ollama, Copilot, OpenAI, Claude, Gemini.
public struct ModelPlanner: Planning {
    public static let maxSteps = 6
    private let client: any ChatCompleting

    public init(client: any ChatCompleting) {
        self.client = client
    }

    private struct Plan: Decodable {
        struct Step: Decodable {
            let action: String
            let arguments: [String: JSONValue]?
        }

        let steps: [Step]?
        let answer: String?
        let agent: Bool?
        let research: String?
    }

    /// Constant prompt over ~512 tokens: Gemma-style models then reuse the KV cache (~1 s saved).
    static func systemPrompt(for registry: ActionRegistry) -> String {
        let catalog = registry.all.map { action in
            let parameters = action.parameters
                .map { "\($0.name)\(ArgumentExtractor.typeHint($0))\($0.isRequired ? "" : " optional")" }
                .joined(separator: ", ")
            return "- \(action.id)(\(parameters)): \(action.summary)"
        }.joined(separator: "\n")
        return """
                    You automate a Mac. Break the user's request into the shortest ordered list of these actions:
                    \(catalog)
                    Use only these actions and parameters, and only the steps the user asked for.
                    A website for a named browser is one url.open step with the app argument.
                    On-screen buttons, links, menus and fields named by the user are ui.press / ui.fill steps.
                    Reply with compact JSON only: {"steps":[{"action":"<id>","arguments":{"<parameter>":<value>}}]}
                    If the request needs to look at the screen to decide what to press or fill (elements described
                    by position, order or look, forms, several clicks inside an app), reply {"steps":[],"agent":true}.
                    If the user asks a question or chats, or any part of the request needs something these actions
                    cannot do, reply {"steps":[],"answer":"<a short answer in the user's language>"} (max 3 sentences).
                    Answer stable general knowledge directly (definitions, history, books, classic films, science).
                    Questions about anything current or worth checking online (news, weather, prices, exchange rates,
                    sports results, recent or upcoming releases, schedules, who holds a role now, facts you are unsure
                    of) need the web: reply {"steps":[],"research":"<web search query in the user's language>"}.
                    Never invent real-time facts.
                    Examples:
                    "apri Note e scrivi ciao" -> {"steps":[{"action":"app.open","arguments":{"name":"Notes"}},\
                    {"action":"text.type","arguments":{"text":"ciao"}}]}
                    "open github.com in Firefox" -> {"steps":[{"action":"url.open","arguments":\
                    {"url":"github.com","app":"Firefox"}}]}
                    "lancia il Terminale e scorri in basso" -> {"steps":[{"action":"app.open","arguments":\
                    {"name":"Terminal"}},{"action":"scroll","arguments":{"direction":"down"}}]}
                    "chiudi Slack e apri Teams" -> {"steps":[{"action":"app.quit","arguments":{"name":"Slack"}},\
                    {"action":"app.open","arguments":{"name":"Microsoft Teams"}}]}
                    "manda un messaggio a Luca su Slack" -> {"steps":[],"answer":"Non posso ancora inviare \
                    messaggi, ma posso aprire Slack."}
                    "press the Login button" -> {"steps":[{"action":"ui.press","arguments":{"target":"Login"}}]}
                    "apri il primo menu" -> {"steps":[],"agent":true}
                    "apri il terzo link della pagina" -> {"steps":[],"agent":true}
                    "compila il modulo con nome Mario" -> {"steps":[],"agent":true}
                    "porta il puntatore in alto a destra" -> {"steps":[],"answer":"Dimmi le coordinate, ad \
                    esempio 1200, 50."}
                    "quanto spazio libero ho sul disco?" -> {"steps":[{"action":"shell.run","arguments":\
                    {"command":"df -h /"}}]}
                    "quanto fa 12 per 12?" -> {"steps":[],"answer":"144."}
                    "chi ha scritto i Promessi Sposi?" -> {"steps":[],"answer":"Alessandro Manzoni."}
                    "what's the weather in Rome?" -> {"steps":[],"research":"weather Rome"}
                    "ultime notizie sull'Ucraina" -> {"steps":[],"research":"Ucraina notizie"}
                    "quando esce il prossimo film di Nolan?" -> {"steps":[],"research":\
                    "prossimo film Christopher Nolan data di uscita"}
                    "di cosa parla Inception?" -> {"steps":[],"answer":"Un ladro che ruba segreti nei sogni deve \
                    invece impiantare un'idea nella mente di un erede: film di Christopher Nolan del 2010."}
                    """
    }

    public func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        let response = try await client.chat(
            [.system(Self.systemPrompt(for: registry)), .user(input)],
            format: .string("json"),
            maxTokens: 512,
            topLogprobs: nil
        )
        guard let json = JSONText.firstObject(in: response.message.content),
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(json.utf8))
        else { throw PlanError.unreadable }
        let steps = plan.steps ?? []
        guard steps.count <= Self.maxSteps else { throw PlanError.tooManySteps(steps.count) }
        let requests = steps.map { step in
            let arguments = registry.action(for: step.action).map {
                ArgumentExtractor.arguments(from: step.arguments ?? [:], for: $0, input: input)
            }
            return ActionRequest(step.action, arguments ?? [:])
        }
        let answer = plan.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let research = plan.research?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlanResult(
            steps: requests, answer: answer?.isEmpty == false ? answer : nil, needsScreen: plan.agent == true,
            research: research?.isEmpty == false ? research : nil
        )
    }
}
