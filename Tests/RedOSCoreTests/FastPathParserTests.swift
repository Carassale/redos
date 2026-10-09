import Testing
@testable import RedOSCore

struct FastPathParserTests {
    private let parser = FastPathParser()

    @Test(arguments: [
        ("apri Safari", ActionRequest("app.open", ["name": "Safari"])),
        ("Open Visual Studio Code", ActionRequest("app.open", ["name": "Visual Studio Code"])),
        ("chiudi Slack", ActionRequest("app.quit", ["name": "Slack"])),
        ("chiudi Spotify per favore", ActionRequest("app.quit", ["name": "Spotify"])),
        ("open Xcode, please", ActionRequest("app.open", ["name": "Xcode"])),
        ("vai su google.com", ActionRequest("url.open", ["url": "google.com"])),
        ("apri github.com/apple", ActionRequest("url.open", ["url": "github.com/apple"])),
        ("go to the bottom", nil),
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
        ("clicca su Salva", ActionRequest("ui.press", ["target": "Salva"])),
        ("clicca sul pulsante Invia", ActionRequest("ui.press", ["target": "Invia"])),
        ("press the Login button", ActionRequest("ui.press", ["target": "Login"])),
        ("apri il menu File", ActionRequest("ui.press", ["target": "File"])),
        ("clicca 300, 200", ActionRequest("mouse.click", ["x": "300", "y": "200"])),
        ("scrivi mario nel campo Utente", ActionRequest("ui.fill", ["target": "Utente", "text": "mario"])),
        ("type pizza in the Search field", ActionRequest("ui.fill", ["target": "Search", "text": "pizza"])),
        ("type I live in the UK", ActionRequest("text.type", ["text": "I live in the UK"])),
        ("leggimi lo schermo", ActionRequest("ui.read")),
        ("what's on the screen?", ActionRequest("ui.read")),
        ("esegui il comando git status", ActionRequest("shell.run", ["command": "git status"])),
    ])
    func recognizes(_ input: String, _ expected: ActionRequest?) {
        #expect(parser.parse(input) == expected)
    }

    @Test(arguments: [
        ("google.com", "https://google.com"),
        ("https://github.com/apple", "https://github.com/apple"),
        ("http://example.org", "http://example.org"),
    ])
    func normalizesWebAddresses(_ text: String, _ expected: String) {
        #expect(WebAddress.url(from: text)?.absoluteString == expected)
    }

    @Test(arguments: ["", "Safari", "google com", "file:///etc/passwd", "javascript:alert(1)", "localhost", "a."])
    func rejectsNonWebAddresses(_ text: String) {
        #expect(WebAddress.url(from: text) == nil)
    }

    @Test(arguments: [
        "", "   ", "apri", "apriti sesamo", "what's the weather?", "clicca col tasto destro", "scroll the page",
        "apri il progetto, fai pull e lancia i test", "open the repo and run the tests", "apri Mail poi scrivi",
        "apri chrom e naviga su google.com", "apri il primo menu", "premi invio", "press the mouse button",
        "clicca qui",
    ])
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
