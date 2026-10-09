import Observation
import RedOSCore

@MainActor
@Observable
final class CommandPanelModel {
    enum State: Equatable {
        case idle
        case working
        case confirming(ResolvedCommand)
        case confirmingPlan(ResolvedPlan)
        case message(String, isError: Bool)
        case answer(String)
    }

    var text = ""
    var state = State.idle
    var focusRequest = 0
}
