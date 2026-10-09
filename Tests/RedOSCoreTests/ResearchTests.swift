import Foundation
import Testing
@testable import RedOSCore

private struct FakeWeb: WebResearching {
    func search(_ query: String) async throws -> String {
        "1. Dune - Parte due — https://it.wikipedia.org/wiki/Dune\n   regia di Denis Villeneuve"
    }
    func news(_ query: String) async throws -> String { "- 2026-10-09: Notizia — https://example.com/n" }
    func read(_ url: URL) async throws -> ToolOutput {
        ToolOutput("Pagina \(url.absoluteString)\nImage: https://img.example.com/poster.jpg",
                   image: URL(string: "https://img.example.com/poster.jpg"))
    }
    func weather(_ place: String) async throws -> ToolOutput {
        ToolOutput("\(place): 18°C, overcast", chart: FakeWeb.chart)
    }
    func exchangeRate(from: String, to: String) async throws -> (rate: Double, date: String) { (0.9, "2026-10-08") }
    func rateHistory(from: String, to: String) async throws -> ChartSpec { FakeWeb.chart }

    static let chart = ChartSpec(
        title: "Milano · °C", kind: .line, unit: "°C",
        series: [.init(name: "Max", points: [.init("ven 9", 20), .init("sab 10", 21)])]
    )
}

/// Replies in order and records the user messages it receives.
private actor ScriptedChat: ChatCompleting {
    private var replies: [String]
    private(set) var messages: [String] = []

    init(_ replies: [String]) {
        self.replies = replies
    }

    func chat(
        _ messages: [ChatMessage], format: JSONValue?, maxTokens: Int?, topLogprobs: Int?
    ) async throws -> ChatResponse {
        self.messages.append(messages.last?.content ?? "")
        return ChatResponse(message: .init(content: replies.isEmpty ? "{}" : replies.removeFirst()), logprobs: nil)
    }

    nonisolated func preload() async {}
}

private struct ResearchPlanner: Planning {
    func plan(_ input: String, registry: ActionRegistry) async throws -> PlanResult {
        PlanResult(steps: [], research: "meteo Milano")
    }
}

private struct QuestionRouter: CommandRouting {
    func prepare() async {}
    func route(_ input: String) async throws -> RouteDecision { .noAction(confidence: 0.9) }
}

struct ResearchTests {
    private let italian = Locale(identifier: "it_IT")

    @Test(arguments: [
        ("2+2", "2+2 = 4"), ("quanto fa 3,5 per 4?", "3.5×4 = 14"), ("what is (1 + 2) * 3", "(1+2)×3 = 9"),
        ("20% di 150", "20/100×150 = 30"), ("2^10", "2^10 = 1024"), ("10 / 4", "10/4 = 2,5"),
    ])
    func calculates(_ input: String, _ expected: String) {
        #expect(Calculator.answer(input, locale: italian) == expected)
    }

    @Test(arguments: ["apri Safari", "4", "-5", "+39 333 1234567", "1/0", "2+", "scrivi 2+2 nel campo Nome"])
    func ignoresNonCalculations(_ input: String) {
        #expect(Calculator.answer(input) == nil)
    }

    @Test(arguments: [
        ("converti 10 miglia in km", "10 mi = 16,0934 km"), ("100 fahrenheit in celsius", "100 °F = 37,7778 °C"),
        ("5 lb to kg", "5 lb = 2,268 kg"), ("100 dollari in euro", "100 USD = 90 EUR (ECB, 2026-10-08)"),
    ])
    func converts(_ input: String, _ expected: String) async {
        #expect(await UnitConverter.answer(input, web: FakeWeb(), locale: italian) == expected)
    }

    @Test(arguments: ["10 miglia in kg", "apri 2 finestre in Safari", "chiudi Mail"])
    func ignoresNonConversions(_ input: String) async {
        #expect(await UnitConverter.answer(input, web: FakeWeb()) == nil)
    }

    @Test func parsesSearchResultsAndNews() {
        let html = """
            <a rel="nofollow" class="result__a" href="https://it.wikipedia.org/wiki/Dune_-_Parte_due">Dune - Parte \
            <b>due</b></a> <a class="result__snippet" href="x">Un <b>film</b> del 2024 &amp; altro</a>
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=1">Altro</a>
            """
        #expect(WebTools.searchResults(in: html) == [
            .init(title: "Dune - Parte due", url: "https://it.wikipedia.org/wiki/Dune_-_Parte_due",
                  snippet: "Un film del 2024 & altro"),
            .init(title: "Altro", url: "https://example.com/a", snippet: ""),
        ])
        let rss = "<item><title>Titolo &amp; co - La Stampa</title><link>https://news.google.com/a</link>"
            + "<pubDate>Fri, 09 Oct 2026 08:00:00 GMT</pubDate></item>"
        #expect(WebTools.newsItems(in: rss) == [
            .init(title: "Titolo & co - La Stampa", link: "https://news.google.com/a", date: "2026-10-09"),
        ])
    }

    @Test func extractsReadableText() {
        let html = "<html><script>var x = 1;</script><nav>menu</nav><article><h1>Titolo</h1><p>Primo &egrave; "
            + "<b>uno</b></p><p>Secondo&#33;</p></article></html>"
        #expect(HTMLText.plain(from: html) == "Titolo\nPrimo è uno\nSecondo!")
    }

    @Test(arguments: [
        ("https://example.com/a", true), ("http://news.example.org", true), ("http://localhost:11434/api", false),
        ("http://127.0.0.1/x", false), ("http://192.168.1.1", false), ("http://10.0.0.5", false),
        ("http://172.20.1.1", false), ("http://169.254.169.254/latest", false), ("http://router.local", false),
        ("file:///etc/passwd", false), ("https://example.com:8443/", false), ("http://[::1]/", false),
    ])
    func allowsOnlyPublicWebAddresses(_ address: String, _ allowed: Bool) throws {
        #expect(WebTools.isPublicWebAddress(try #require(URL(string: address))) == allowed)
    }

    @Test func researchAgentUsesToolsThenAnswers() async throws {
        let chat = ScriptedChat([
            #"{"tool":"weather","place":"Milano"}"#,
            #"{"answer":"A Milano ci sono 18 gradi.","sources":["https://open-meteo.com","http://localhost/x"]}"#,
        ])
        let agent = ResearchAgent(client: chat, tools: FakeWeb())
        let answer = try await agent.answer("che tempo fa a Milano?", query: "meteo Milano")

        #expect(answer.text == "A Milano ci sono 18 gradi.")
        #expect(answer.sources == [URL(string: "https://open-meteo.com")!])
        #expect(answer.display.hasSuffix("open-meteo.com"))
        #expect(answer.chart == FakeWeb.chart)
        let messages = await chat.messages
        // Weather questions start with the model, which picks the place.
        #expect(messages.first?.hasSuffix("Findings:\nnone") == true)
        #expect(messages.last?.contains("[weather Milano]\nMilano: 18°C, overcast") == true)
    }

    @Test func researchAgentIsForcedToAnswer() async throws {
        let replies = Array(repeating: #"{"tool":"search","query":"x"}"#, count: ResearchAgent.maxToolCalls)
            + [#"{"answer":"Non ho trovato abbastanza."}"#]
        let chat = ScriptedChat(replies)
        let answer = try await ResearchAgent(client: chat, tools: FakeWeb()).answer("?", query: nil)
        #expect(answer.text == "Non ho trovato abbastanza.")
        #expect(await chat.messages.last?.contains("No more tools") == true)
    }

    @Test func questionsNeedingTheWebBecomeResearch() async {
        let engine = CommandEngine(
            registry: ActionRegistry([]), router: QuestionRouter(), planner: ResearchPlanner(),
            researcher: ResearchAgent(client: ScriptedChat([]), tools: FakeWeb()), audit: MemoryAuditLog()
        )
        let question = "che tempo fa a Milano?"
        #expect(await engine.resolve(question) == .research(question, query: "meteo Milano"))
        #expect(await engine.resolve("2+2") == .answer("2+2 = 4"))
    }

    @Test func answersShowOnlyImagesFoundAndValidCharts() async throws {
        let chat = ScriptedChat([
            #"{"tool":"read","url":"https://it.wikipedia.org/wiki/Dune"}"#,
            #"{"answer":"Villeneuve.","image":"https://evil.example.com/x.jpg","#
                + #""chart":{"title":"t","kind":"bar","points":[{"label":"a","value":1}]}}"#,
        ])
        let answer = try await ResearchAgent(client: chat, tools: FakeWeb()).answer("chi ha diretto Dune?", query: nil)
        // Not in the findings: the page's own image is used instead; a one-point chart is dropped.
        #expect(answer.image == URL(string: "https://img.example.com/poster.jpg"))
        #expect(answer.chart == nil)
    }

    @Test func activitiesReachTheReporter() async throws {
        let seen = ActivityLog()
        let chat = ScriptedChat([#"{"tool":"weather","place":"Roma"}"#, #"{"answer":"Sole."}"#])
        _ = try await ActivityReporter.$handler.withValue({ seen.append($0) }, operation: {
            try await ResearchAgent(client: chat, tools: FakeWeb()).answer("meteo Roma?", query: "meteo Roma")
        })
        #expect(await seen.items.contains(.checkingWeather("Roma")))
        #expect(await seen.items.contains(.writing))
    }

    @Test func findsPreviewImages() throws {
        let base = try #require(URL(string: "https://example.com/film"))
        let html = #"<meta property="og:image" content="https://cdn.example.com/a.jpg"><meta name="x">"#
        #expect(WebTools.previewImage(in: html, base: base) == URL(string: "https://cdn.example.com/a.jpg"))
        let local = #"<meta content="http://192.168.1.2/a.jpg" property="og:image">"#
        #expect(WebTools.previewImage(in: local, base: base) == nil)
    }

    @Test func plannerRoutesDiagrams() async throws {
        let chat = ScriptedChat([#"{"steps":[],"diagram":"Flusso di login"}"#])
        let result = try await ModelPlanner(client: chat).plan("disegna il login", registry: ActionRegistry([]))
        #expect(result.diagram == "Flusso di login")
    }

    @Test func diagramLibraryReadsTheBundledSkill() throws {
        let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/DiagramDesign")
        let library = try #require(DiagramLibrary(directory: directory))
        #expect(library.types.count == 44)
        #expect(library.types.contains { $0.id == "flowchart" && $0.name == "Flowchart" })
        let prompt = DiagramDesigner(client: ScriptedChat([]), library: library)
            .designPrompt(for: try #require(library.types.first { $0.id == "bar" }))
        #expect(prompt.contains("# Visual type: Bar chart"))
        #expect(prompt.contains("<svg"))
    }

    @Test func extractsDiagramHTML() {
        let reply = "Ecco:\n```html\n<!DOCTYPE html><html><body><svg></svg><script>alert(1)</script></body></html>\n```"
        #expect(DiagramDesigner.document(in: reply) == "<!DOCTYPE html><html><body><svg></svg></body></html>")
        #expect(DiagramDesigner.document(in: "<svg viewBox='0 0 1 1'></svg>")?.hasPrefix("<!DOCTYPE html>") == true)
        #expect(DiagramDesigner.document(in: "no diagram") == nil)
    }
}

private final class ActivityLog: Sendable {
    @MainActor private(set) var items: [Activity] = []
    @MainActor func append(_ activity: Activity) { items.append(activity) }
}
