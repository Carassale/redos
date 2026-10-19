import Testing
@testable import RedOSCore

struct SpokenSentencesTests {
    @Test func cutsLinesAndSentencesAsTheyArrive() {
        var sentences = SpokenSentences()
        #expect(sentences.append("Ho trovato un caso").isEmpty)
        #expect(sentences.append(" per Luxottica:\n\n**CRM App** - piattaforma. Usata in ") == [
            "Ho trovato un caso per Luxottica:", "**CRM App** - piattaforma.",
        ])
        #expect(sentences.append("EMEA e US.").isEmpty)
        #expect(sentences.finish() == "Usata in EMEA e US.")
        #expect(sentences.finish() == nil)
    }

    @Test func keepsBoldLinksAndListNumbersTogether() {
        var sentences = SpokenSentences()
        let pieces = sentences.append(
            "1. **Fase 1. Ricerca** con [Sketchin. Studio](https://sketchin.com) e app. Fine\n"
        )
        #expect(pieces == [
            "1. **Fase 1. Ricerca** con [Sketchin. Studio](https://sketchin.com) e app.", "Fine",
        ])
    }
}
