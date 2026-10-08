import Observation
import RedOSCore

@MainActor
@Observable
final class CommandPanelModel {
    enum State: Equatable {
        case idle
        case working
        case confirming(ResolvedCommand)
        case message(String, isError: Bool)
    }

    var text = ""
    var state = State.idle
    var focusRequest = 0
}
