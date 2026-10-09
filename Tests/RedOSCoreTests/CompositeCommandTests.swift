import Testing
@testable import RedOSCore

struct CompositeCommandTests {
    private let parser = FastPathParser()

    @Test(arguments: [
        (
            "apri chrome e vai su google.com",
            [ActionRequest("url.open", ["url": "google.com", "app": "chrome"])]
        ),
        (
            "Apri Chrome e vai sul sito bip.red",
            [ActionRequest("url.open", ["url": "bip.red", "app": "Chrome"])]
        ),
        (
            "apri chrome, apri il sito bip.red",
            [ActionRequest("url.open", ["url": "bip.red", "app": "chrome"])]
        ),
        (
            "apri Note e poi scrivi lista della spesa",
            [ActionRequest("app.open", ["name": "Note"]), ActionRequest("text.type", ["text": "lista della spesa"])]
        ),
        (
            "open Safari and then scroll down",
            [ActionRequest("app.open", ["name": "Safari"]), ActionRequest("scroll", ["direction": "down"])]
        ),
        (
            "chiudi Slack e apri Teams",
            [ActionRequest("app.quit", ["name": "Slack"]), ActionRequest("app.open", ["name": "Teams"])]
        ),
    ])
    func splitsIntoFastPathSteps(_ input: String, _ expected: [ActionRequest]) {
        #expect(parser.parsePlan(input) == expected)
    }

    @Test(arguments: [
        "apri Pages e Numbers", "apri il progetto, fai pull e lancia i test", "apri Safari",
        "manda una mail e archiviala",
    ])
    func leavesOtherCommandsToTheModels(_ input: String) {
        #expect(parser.parsePlan(input) == nil)
    }

    @Test func singleCommandsWithConnectorsInTextStayWhole() {
        #expect(parser.parse("scrivi pane e latte") == ActionRequest("text.type", ["text": "pane e latte"]))
    }

    @Test func simplifierFoldsBrowserLaunchesAndRepeats() {
        let steps = [
            ActionRequest("app.open", ["name": "Google Chrome"]),
            ActionRequest("url.open", ["url": "bip.red"]),
            ActionRequest("app.open", ["name": "Google Chrome"]),
        ]
        let folded = [ActionRequest("url.open", ["url": "bip.red", "app": "Google Chrome"])]
        #expect(PlanSimplifier.simplify(steps) == folded)

        let notBrowser = [ActionRequest("app.open", ["name": "Notes"]), ActionRequest("url.open", ["url": "a.com"])]
        #expect(PlanSimplifier.simplify(notBrowser) == notBrowser)
    }

    @Test(arguments: [
        ("Sì.", true), ("ok", true), ("conferma", true), ("Yes!", true),
        ("no", false), ("annulla", false), ("cancel", false), ("apri Safari", nil),
    ] as [(String, Bool?)])
    func understandsSpokenConfirmations(_ reply: String, _ expected: Bool?) {
        #expect(ConfirmationReply.parse(reply) == expected)
    }

    @MainActor @Test func webAddressParametersAreValidated() {
        let registry = ActionRegistry([
            FakeAction(id: "url.open", parameters: [ActionParameter("url", .webAddress)], recorder: RunRecorder())
        ])
        #expect(throws: ActionError.invalidArgument("url", "bipd")) {
            try registry.validate(ActionRequest("url.open", ["url": "bipd"]))
        }
        #expect((try? registry.validate(ActionRequest("url.open", ["url": "bip.red"]))) != nil)
    }
}
