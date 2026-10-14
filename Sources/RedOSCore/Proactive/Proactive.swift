import Foundation

/// Something RedOS could tell the user without being asked.
public enum ProactiveEvent: Sendable, Equatable {
    case meetingSoon(title: String, minutes: Int, link: URL?)
    case batteryLow(percent: Int)
    /// A call app was opened: notes may be wanted.
    case callAppOpened(String)
    case briefing

    /// For the decision and the logs.
    var summary: String {
        switch self {
        case .meetingSoon(let title, let minutes, let link):
            "Meeting \"\(title)\" starts in \(minutes) minutes" + (link.map { ", call link \($0.host() ?? "")" } ?? "")
        case .batteryLow(let percent): "Battery at \(percent)%, not charging"
        case .callAppOpened(let app): "The user just opened \(app), a video call app"
        case .briefing: "Morning briefing: the user's first activity of the day"
        }
    }
}

/// How to deliver a proactive event.
public enum Interruption: String, Sendable, Equatable {
    /// Speak and show the panel.
    case interrupt
    /// A quiet system notification.
    case notify
    case skip
}

/// What the user is doing, for deciding whether to interrupt.
public struct UserContext: Sendable, Equatable {
    public let now: Date
    public let frontmost: String?
    /// RedOS is taking notes of a call.
    public let inCall: Bool
    /// Seconds since the last keyboard or mouse input.
    public let idleSeconds: Double

    public init(now: Date, frontmost: String?, inCall: Bool, idleSeconds: Double) {
        self.now = now
        self.frontmost = frontmost
        self.inCall = inCall
        self.idleSeconds = idleSeconds
    }
}

/// Jev decides whether an event is worth interrupting for; without Jev (or unsure), fixed rules. RedOS never
/// speaks during a call.
public struct InterruptionPolicy: Sendable {
    static let minimumProbability = 0.6
    private let jev: (any JevDeciding)?

    public init(jev: (any JevDeciding)?) {
        self.jev = jev
    }

    public func decide(_ event: ProactiveEvent, context: UserContext) async -> Interruption {
        var decision = Self.rule(for: event, context: context)
        if let jev, let answer = try? await jev.decide(
            state: Self.state(event, context: context), questions: ["delivery": Self.question]
        )["delivery"], answer.probability >= Self.minimumProbability,
           let choice = answer.choice.flatMap(Interruption.init(rawValue:)) {
            decision = choice
        }
        // Even a confident model does not get to talk over a call.
        return context.inCall && decision == .interrupt ? .notify : decision
    }

    static func rule(for event: ProactiveEvent, context: UserContext) -> Interruption {
        switch event {
        case .meetingSoon(_, let minutes, _): minutes <= 5 ? .interrupt : .notify
        case .batteryLow(let percent): percent <= 10 ? .interrupt : .notify
        case .callAppOpened: context.inCall ? .skip : .interrupt
        case .briefing: context.inCall ? .skip : .interrupt
        }
    }

    static let question = JevQuestion.choice(
        instructions: "RedOS, the user's Mac assistant, could tell the user about the event below. How should it"
            + " deliver it, given what the user is doing?",
        options: [
            JevOption(label: "interrupt", description: "Say it aloud now: time-sensitive and the user can listen."),
            JevOption(label: "notify", description: "A quiet notification: useful but not worth interrupting."),
            JevOption(label: "skip", description: "Not worth telling now."),
        ]
    )

    static func state(_ event: ProactiveEvent, context: UserContext) -> String {
        let time = context.now.formatted(.dateTime.weekday(.wide).hour().minute())
        return """
            Now: \(time)
            User: \(context.frontmost.map { "working in \($0)" } ?? "no app in front"), \
            idle for \(Int(context.idleSeconds)) s\(context.inCall ? ", in a call" : "")
            Event: \(event.summary)
            """
    }
}

/// Links to video calls in calendar events (URL, location or notes).
public enum MeetingLink {
    private static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"]

    public static func find(in texts: [String?]) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in texts.compactMap(\.self) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                if let url = match.url, let host = url.host(), hosts.contains(where: host.hasSuffix) { return url }
            }
        }
        return nil
    }
}
