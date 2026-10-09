import Observation
import RedOSCore

@MainActor
@Observable
final class CommandPanelModel {
    enum State: Equatable {
        case idle
        case listening
        case working
        case confirming(ResolvedCommand)
        case confirmingPlan(ResolvedPlan)
        case message(String, isError: Bool)
        case answer(String)
    }

    var text = ""
    var state = State.idle
    /// What a long-running request is doing, e.g. the web search in progress.
    var progress: String?
    var focusRequest = 0
}
