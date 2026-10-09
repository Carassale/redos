import Foundation

/// A small chart attached to an answer: weather, exchange rates, or a numeric series found on the web.
public struct ChartSpec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case line
        case bar
    }

    public struct Point: Codable, Sendable, Equatable {
        public let label: String
        public let value: Double

        public init(_ label: String, _ value: Double) {
            self.label = label
            self.value = value
        }
    }

    public struct Series: Codable, Sendable, Equatable {
        public let name: String
        public let points: [Point]

        public init(name: String, points: [Point]) {
            self.name = name
            self.points = points
        }
    }

    public let title: String
    public let kind: Kind
    public let unit: String?
    public let series: [Series]

    public init(title: String, kind: Kind, unit: String? = nil, series: [Series]) {
        self.title = title
        self.kind = kind
        self.unit = unit
        self.series = series
    }

    /// Model-written charts are checked before display.
    public var isValid: Bool {
        !series.isEmpty && series.count <= 4 && series.allSatisfy { series in
            (2...40).contains(series.points.count)
                && series.points.allSatisfy { $0.value.isFinite && !$0.label.isEmpty }
        }
    }
}
