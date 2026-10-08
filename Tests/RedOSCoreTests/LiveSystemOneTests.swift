import Foundation
import RedOSActions
import Testing
@testable import RedOSCore

/// Runs against a real Ollama: `make test-live`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REDOS_LIVE_MODEL"] != nil), .serialized)
struct LiveSystemOneTests {
    private let router: SystemOneRouter = {
        let ollama = OllamaClient(model: ProcessInfo.processInfo.environment["REDOS_LIVE_MODEL"] ?? "")
        return SystemOneRouter(
            registry: ActionRegistry(SystemActions.all),
            systemOne: OllamaSystemOne(client: ollama),
            extractor: ArgumentExtractor(client: ollama),
            warmUp: ollama
        )
    }()

    @Test(arguments: [
        ("bring up my terminal please", "app.open"),
        ("fammi vedere il browser di Apple", "app.open"),
        ("chiudi Spotify per favore", "app.quit"),
        ("vai in fondo alla pagina", "scroll"),
        ("scrivi buongiorno a tutti", "text.type"),
        ("che tempo fa domani a Milano?", SystemOneRouter.noneLabel),
    ])
    func routes(_ input: String, _ expected: String) async throws {
        await router.prepare()
        let start = ContinuousClock.now
        let decision = try await router.route(input)
        let elapsed = ContinuousClock.now - start
        let seconds = elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))
        print("[live] \(seconds) \(input) -> \(decision)")

        switch decision {
        case .action(let request, _): #expect(request.actionID == expected)
        case .noAction: #expect(expected == SystemOneRouter.noneLabel)
        case .uncertain(let actionID, _): Issue.record("Uncertain: \(actionID)")
        }
    }
}
