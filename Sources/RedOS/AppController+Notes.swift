import Foundation
import RedOSCore

extension AppController {
    /// Starts or stops the notes. Returns what to tell the user, or nil once the notes window took over.
    @discardableResult
    func setTakingNotes(_ start: Bool) async -> String? {
        if start {
            guard !notes.isListening else { return String(localized: "Already taking notes.") }
            notesWindow.show()
            do {
                try await notes.start()
            } catch {
                return error.localizedDescription
            }
            // Nobody wants RedOS talking over a call.
            commandPanel.isQuiet = true
            return nil
        }
        guard notes.isListening else { return String(localized: "I'm not taking notes.") }
        notesWindow.show()
        let meeting = await notes.stop()
        commandPanel.isQuiet = false
        return meeting.map { String(localized: "Minutes saved: \($0.title).") }
            ?? String(localized: "Nothing was said: no minutes saved.")
    }
}
