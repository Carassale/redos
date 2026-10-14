import AppKit
import RedOSCore

// MARK: - Speaking up without being asked

extension CommandPanelController {
    /// RedOS speaks first ("Tra 5 minuti: Standup"): the panel shows it, the voice says it, the microphone stays
    /// open for an answer and the conversation remembers it ("aprilo" then refers to it). False while RedOS is
    /// busy with the user.
    @discardableResult
    func announce(_ text: String, spoken: String? = nil) -> Bool {
        guard model.state != .working, model.state != .listening, listening == nil, !isDrivingMac else { return false }
        isVoiceCommand = true
        model.text = ""
        show()
        model.state = .answer(.init(text: text))
        say(spoken ?? text)
        Task { [engine] in await engine.conversation?.record("(RedOS spoke first)", reply: text) }
        followUpIfUseful()
        return true
    }
}
