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
    /// The microphone is open for a follow-up while the last reply stays on screen.
    var isFollowingUp = false
    /// What a running request is doing (understanding, searching the web…).
    var activity: Activity?
    var focusRequest = 0
    /// The island is grown out of the notch; false while it shrinks back before the panel hides.
    var isOpen = false
    var notch = NotchGeometry()
    /// Microphone level, 0...1.
    var level: Float = 0
    var isSpeaking = false
}
