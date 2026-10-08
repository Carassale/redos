import Testing
@testable import RedOSCore

struct FastPathParserTests {
    private let parser = FastPathParser()

    @Test(arguments: [
        ("apri Safari", ActionRequest("app.open", ["name": "Safari"])),
        ("Open Visual Studio Code", ActionRequest("app.open", ["name": "Visual Studio Code"])),
        ("chiudi Slack", ActionRequest("app.quit", ["name": "Slack"])),
        ("esci da Mail", ActionRequest("app.quit", ["name": "Mail"])),
        ("scrivi \"ciao mondo\"", ActionRequest("text.type", ["text": "ciao mondo"])),
        ("type open safari", ActionRequest("text.type", ["text": "open safari"])),
        ("scroll up", ActionRequest("scroll", ["direction": "up"])),
        ("scrolla giù 10", ActionRequest("scroll", ["direction": "down", "amount": "10"])),
        ("scorri in basso di 3 righe", ActionRequest("scroll", ["direction": "down", "amount": "3"])),
        ("SCROLLA GIU", ActionRequest("scroll", ["direction": "down"])),
        ("clicca", ActionRequest("mouse.click")),
        ("click at 100, 200", ActionRequest("mouse.click", ["x": "100", "y": "200"])),
        ("muovi il mouse a 300 400", ActionRequest("mouse.move", ["x": "300", "y": "400"])),
    ])
    func recognizes(_ input: String, _ expected: ActionRequest) {
        #expect(parser.parse(input) == expected)
    }

    @Test(arguments: ["", "   ", "apri", "apriti sesamo", "what's the weather?", "clicca su Salva", "scroll the page"])
    func ignores(_ input: String) {
        #expect(parser.parse(input) == nil)
    }
}

struct NameMatcherTests {
    private let apps = ["Safari", "Visual Studio Code", "Calcolatrice", "Slack", "Visual Studio Code - Insiders"]

    @Test func prefersExactThenShortestPrefix() {
        #expect(NameMatcher.bestMatch(for: "safari", in: apps) == 0)
        #expect(NameMatcher.bestMatch(for: "visual studio", in: apps) == 1)
        #expect(NameMatcher.bestMatch(for: "calcolatrice", in: apps) == 2)
        #expect(NameMatcher.bestMatch(for: "insiders", in: apps) == 4)
        #expect(NameMatcher.bestMatch(for: "xcode", in: apps) == nil)
    }
}
