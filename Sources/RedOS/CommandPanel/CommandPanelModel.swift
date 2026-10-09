import Foundation
import Observation
import RedOSCore

@MainActor
@Observable
final class CommandPanelModel {
    /// Text plus what can be shown with it.
    struct Answer: Equatable {
        var text: String
        var sources: [String] = []
        var image: URL?
        var chart: ChartSpec?
        var diagram: Diagram?
    }

    enum State: Equatable {
        case idle
        case listening
        case working
        case confirming(ResolvedCommand)
        case confirmingPlan(ResolvedPlan)
        case message(String, isError: Bool)
        case answer(Answer)
    }

    var text = ""
    var state = State.idle
    /// What a running request is doing (understanding, searching the web…).
    var activity: Activity?
    var focusRequest = 0
}
