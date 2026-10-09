import Foundation

/// What RedOS is doing while a request runs, shown in the panel.
public enum Activity: Sendable, Equatable {
    case understanding
    case thinking
    case searching(String)
    case readingNews(String)
    case reading(String)
    case checkingWeather(String)
    case checkingRates(String)
    case writing
    case drawing(String)
    /// A long reply is streaming in.
    case receiving(characters: Int)
    case readingScreen(String)

    public var title: String {
        switch self {
        case .understanding: String(localized: "Understanding the request…")
        case .thinking: String(localized: "Thinking…")
        case .searching(let query): String(localized: "Searching the web: \(query)")
        case .readingNews(let query): String(localized: "Reading the news: \(query)")
        case .reading(let site): String(localized: "Reading \(site)")
        case .checkingWeather(let place): String(localized: "Checking the weather: \(place)")
        case .checkingRates(let pair): String(localized: "Checking exchange rates: \(pair)")
        case .writing: String(localized: "Writing the answer…")
        case .drawing(let type): String(localized: "Drawing the diagram (\(type))…")
        case .receiving(let characters): String(localized: "Writing… \(characters) characters")
        case .readingScreen(let app): String(localized: "Reading the screen: \(app)")
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .understanding: "ear"
        case .thinking: "brain"
        case .searching: "magnifyingglass"
        case .readingNews: "newspaper"
        case .reading: "doc.text.magnifyingglass"
        case .checkingWeather: "cloud.sun"
        case .checkingRates: "arrow.left.arrow.right.circle"
        case .writing: "text.cursor"
        case .drawing: "chart.xyaxis.line"
        case .receiving: "text.append"
        case .readingScreen: "macwindow"
        }
    }
}

public typealias ActivityHandler = @MainActor @Sendable (Activity) -> Void

/// Reports activities to whoever started the task (the panel), without threading a callback everywhere.
public enum ActivityReporter {
    @TaskLocal public static var handler: ActivityHandler?

    public static func report(_ activity: Activity) async {
        await handler?(activity)
    }
}
