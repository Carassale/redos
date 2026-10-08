import Observation
import RedOSCore

@MainActor
@Observable
final class CommandPanelModel {
    enum State: Equatable {
        case idle
        case working
        case confirming(ActionRequest, input: String)
        case message(String, isError: Bool)
    }

    var text = ""
    var state = State.idle
    var focusRequest = 0
}
