import Foundation
import Testing
@testable import RedOSCore

@MainActor
final class RunRecorder {
    private(set) var runs: [ActionArguments] = []
    func append(_ arguments: ActionArguments) { runs.append(arguments) }
}

struct FakeAction: Action {
    var id: String
    var summary = "Fake"
    var risk = RiskLevel.safe
    var parameters: [ActionParameter] = []
    var requiredPermissions: [Permission] = []
    var error: ActionError?
    let recorder: RunRecorder

    @MainActor
    func run(_ arguments: ActionArguments) async throws {
        recorder.append(arguments)
        if let error { throw error }
    }
}

actor MemoryAuditLog: AuditLogging {
    private(set) var entries: [AuditEntry] = []
    func record(_ entry: AuditEntry) { entries.append(entry) }
}

private struct StaticPermissions: PermissionChecking {
    var granted: Set<Permission>
    func status(of permission: Permission) -> PermissionStatus { granted.contains(permission) ? .granted : .denied }
    func request(_ permission: Permission) async -> PermissionStatus { status(of: permission) }
}

@MainActor
struct CommandEngineTests {
    let recorder = RunRecorder()
    let audit = MemoryAuditLog()

    private func engine(
        _ actions: [any Action],
        router: (any CommandRouting)? = nil,
        granted: Set<Permission> = Set(Permission.allCases)
    ) -> CommandEngine {
        CommandEngine(
            registry: ActionRegistry(actions),
            router: router,
            permissions: StaticPermissions(granted: granted),
            audit: audit
        )
    }

    @Test func unrecognizedInputIsAudited() async {
        let result = await engine([]).resolve("make me a sandwich")
        #expect(result == .unrecognized)
        #expect(await audit.entries.map(\.outcome) == [.unrecognized])
    }

    @Test func dangerousActionNeedsConfirmation() async {
        let action = FakeAction(
            id: "app.quit", risk: .dangerous, parameters: [ActionParameter("name")], recorder: recorder
        )
        let result = await engine([action]).resolve("chiudi Slack")
        let command = ResolvedCommand(
            input: "chiudi Slack",
            request: ActionRequest("app.quit", ["name": "Slack"]),
            route: .fastPath,
            confidence: nil
        )
        #expect(result == .ready(command, needsConfirmation: true))
        #expect(recorder.runs.isEmpty)
    }

    @Test func executeRunsActionAndRedactsSensitiveArguments() async {
        let action = FakeAction(
            id: "text.type", parameters: [ActionParameter("text", sensitive: true)], recorder: recorder
        )
        let engine = engine([action])
        guard case .ready(let command, false) = await engine.resolve("scrivi segreto") else {
            Issue.record("Expected a ready command")
            return
        }
        let result = await engine.execute(command)

        #expect(throws: Never.self) { try result.get() }
        #expect(recorder.runs == [["text": "segreto"]])
        let entry = await audit.entries.last
        #expect(entry?.outcome == .completed)
        #expect(entry?.route == .fastPath)
        #expect(entry?.input == CommandEngine.redacted)
        #expect(entry?.arguments == ["text": CommandEngine.redacted])
    }

    @Test func missingPermissionPreventsExecution() async {
        let action = FakeAction(id: "mouse.click", requiredPermissions: [.accessibility], recorder: recorder)
        let command = ResolvedCommand(
            input: "clicca", request: ActionRequest("mouse.click"), route: .fastPath, confidence: nil
        )
        let result = await engine([action], granted: []).execute(command)

        #expect(throws: ActionError.permissionMissing(.accessibility)) { try result.get() }
        #expect(recorder.runs.isEmpty)
        #expect(await audit.entries.map(\.outcome) == [.failed])
    }

    @Test func disabledActionIsDenied() async {
        var engine = engine([FakeAction(id: "mouse.click", recorder: recorder)])
        engine.policy.disabledActions = ["mouse.click"]
        #expect(await engine.resolve("clicca") == .denied(ActionRequest("mouse.click")))
    }

    @Test func unmatchedInputIsRoutedBySystemOne() async {
        let action = FakeAction(id: "app.open", parameters: [ActionParameter("name")], recorder: recorder)
        let router = StubRouter(decision: .action(ActionRequest("app.open", ["name": "Terminal"]), confidence: 0.97))
        let result = await engine([action], router: router).resolve("bring up my terminal")

        guard case .ready(let command, false) = result else {
            Issue.record("Expected a ready command, got \(result)")
            return
        }
        #expect(command.route == .systemOne)
        #expect(command.confidence == 0.97)
        #expect(command.request.arguments == ["name": "Terminal"])
    }

    @Test func lowConfidenceModerateActionNeedsConfirmation() async {
        let action = FakeAction(
            id: "app.quit", risk: .moderate, parameters: [ActionParameter("name")], recorder: recorder
        )
        let router = StubRouter(decision: .action(ActionRequest("app.quit", ["name": "Mail"]), confidence: 0.7))
        let result = await engine([action], router: router).resolve("basta mail")
        guard case .ready(_, let needsConfirmation) = result else {
            Issue.record("Expected a ready command")
            return
        }
        #expect(needsConfirmation)
    }

    @Test func noActionAndRouterFailuresAreAudited() async {
        let noAction = StubRouter(decision: .noAction(confidence: 0.9))
        #expect(await engine([], router: noAction).resolve("ciao") == .unrecognized)
        let failing = StubRouter(decision: nil)
        guard case .unavailable = await engine([], router: failing).resolve("ciao") else {
            Issue.record("Expected unavailable")
            return
        }
        let entries = await audit.entries
        #expect(entries.map(\.outcome) == [.unrecognized, .failed])
        #expect(entries.first?.confidence == 0.9)
    }
}

private struct StubRouter: CommandRouting {
    /// nil simulates an unreachable backend.
    let decision: RouteDecision?

    func prepare() async {}

    func route(_ input: String) async throws -> RouteDecision {
        guard let decision else { throw SystemOneError.unavailable("offline") }
        return decision
    }
}

@MainActor
struct ActionRegistryTests {
    private let registry = ActionRegistry([
        FakeAction(
            id: "scroll",
            parameters: [
                ActionParameter("direction", .oneOf(["up", "down"])),
                ActionParameter("amount", .integer, required: false),
            ],
            recorder: RunRecorder()
        )
    ])

    @Test func acceptsValidRequest() throws {
        #expect(try registry.validate(ActionRequest("scroll", ["direction": "up", "amount": "3"])).id == "scroll")
    }

    @Test(arguments: [
        (ActionRequest("nope"), ActionError.unknownAction("nope")),
        (ActionRequest("scroll"), ActionError.missingArgument("direction")),
        (ActionRequest("scroll", ["direction": "sideways"]), ActionError.invalidArgument("direction", "sideways")),
        (ActionRequest("scroll", ["direction": "up", "amount": "lots"]), ActionError.invalidArgument("amount", "lots")),
        (ActionRequest("scroll", ["direction": "up", "rm": "-rf"]), ActionError.invalidArgument("rm", "-rf")),
    ])
    func rejectsInvalidRequest(_ request: ActionRequest, _ expected: ActionError) {
        #expect(throws: expected) { try registry.validate(request) }
    }
}

@MainActor
struct PolicyTests {
    private func action(_ risk: RiskLevel) -> FakeAction {
        FakeAction(id: "a", risk: risk, recorder: RunRecorder())
    }

    @Test func defaultPolicyConfirmsOnlyDangerous() {
        let policy = Policy()
        #expect(policy.decide(for: action(.safe)) == .allow)
        #expect(policy.decide(for: action(.moderate)) == .allow)
        #expect(policy.decide(for: action(.dangerous)) == .confirm)
    }

    @Test func dangerousIsNeverAutoApproved() {
        #expect(Policy(autoApproveUpTo: .dangerous).decide(for: action(.dangerous)) == .confirm)
        #expect(Policy(autoApproveUpTo: .safe).decide(for: action(.moderate)) == .confirm)
    }

    @Test func modelRoutedActionsNeedConfidenceToAutoRun() {
        let policy = Policy()
        #expect(policy.decide(for: action(.safe), confidence: 0.5) == .allow)
        #expect(policy.decide(for: action(.moderate), confidence: 0.5) == .confirm)
        #expect(policy.decide(for: action(.moderate), confidence: 0.95) == .allow)
    }
}

struct FileAuditLogTests {
    @Test func appendsJSONLines() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "audit.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = FileAuditLog(url: url)
        let entry = AuditEntry(
            date: .now, input: "apri Safari", route: .fastPath, confidence: nil, actionID: "app.open",
            arguments: ["name": "Safari"], risk: .safe, outcome: .completed, error: nil
        )

        await log.record(entry)
        await log.record(entry)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}
