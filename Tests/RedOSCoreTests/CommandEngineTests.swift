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

    private func engine(_ actions: [any Action], granted: Set<Permission> = Set(Permission.allCases)) -> CommandEngine {
        CommandEngine(
            registry: ActionRegistry(actions),
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
        #expect(result == .ready(ActionRequest("app.quit", ["name": "Slack"]), needsConfirmation: true))
        #expect(recorder.runs.isEmpty)
    }

    @Test func executeRunsActionAndRedactsSensitiveArguments() async {
        let action = FakeAction(
            id: "text.type", parameters: [ActionParameter("text", sensitive: true)], recorder: recorder
        )
        let engine = engine([action])
        guard case .ready(let request, false) = await engine.resolve("scrivi segreto") else {
            Issue.record("Expected a ready request")
            return
        }
        let result = await engine.execute(request, input: "scrivi segreto")

        #expect((try? result.get()) != nil)
        #expect(recorder.runs == [["text": "segreto"]])
        let entry = await audit.entries.last
        #expect(entry?.outcome == .completed)
        #expect(entry?.input == CommandEngine.redacted)
        #expect(entry?.arguments == ["text": CommandEngine.redacted])
    }

    @Test func missingPermissionPreventsExecution() async {
        let action = FakeAction(id: "mouse.click", requiredPermissions: [.accessibility], recorder: recorder)
        let result = await engine([action], granted: []).execute(ActionRequest("mouse.click"), input: "clicca")

        #expect(throws: ActionError.permissionMissing(.accessibility)) { try result.get() }
        #expect(recorder.runs.isEmpty)
        #expect(await audit.entries.map(\.outcome) == [.failed])
    }

    @Test func disabledActionIsDenied() async {
        var engine = engine([FakeAction(id: "mouse.click", recorder: recorder)])
        engine.policy.disabledActions = ["mouse.click"]
        #expect(await engine.resolve("clicca") == .denied(ActionRequest("mouse.click")))
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
}

struct FileAuditLogTests {
    @Test func appendsJSONLines() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "audit.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = FileAuditLog(url: url)
        let entry = AuditEntry(
            date: .now, input: "apri Safari", actionID: "app.open", arguments: ["name": "Safari"],
            risk: .safe, outcome: .completed, error: nil
        )

        await log.record(entry)
        await log.record(entry)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}
