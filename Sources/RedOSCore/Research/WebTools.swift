import Foundation

/// A tool result: text for the model, plus what the answer can show.
public struct ToolOutput: Sendable, Equatable {
    public let text: String
    public var chart: ChartSpec?
    public var image: URL?

    public init(_ text: String, chart: ChartSpec? = nil, image: URL? = nil) {
        self.text = text
        self.chart = chart
        self.image = image
    }
}

/// Web sources for the research agent; every result is compact plain text for a model.
public protocol WebResearching: Sendable {
    func search(_ query: String) async throws -> String
    func news(_ query: String) async throws -> String
    /// Page text, and its preview image (og:image) if any.
    func read(_ url: URL) async throws -> ToolOutput
    /// Forecast text and a temperature chart.
    func weather(_ place: String) async throws -> ToolOutput
    func exchangeRate(from: String, to: String) async throws -> (rate: Double, date: String)
    /// The last month of daily rates, as a chart.
    func rateHistory(from: String, to: String) async throws -> ChartSpec
}

public enum WebError: Error, LocalizedError, Equatable {
    case blockedAddress(String)
    case httpStatus(Int)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .blockedAddress(let url): String(localized: "Blocked address: \(url)")
        case .httpStatus(let status): String(localized: "The website replied HTTP \(status).")
        case .notFound(let what): String(localized: "Not found: \(what)")
        }
    }
}

/// DuckDuckGo (search), Google News RSS (news), Open-Meteo (weather), Frankfurter/ECB (currencies): no keys.
public struct WebTools: WebResearching {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let maxPageBytes = 2_000_000
    private let language: String
    private let region: String
    private let session: URLSession

    /// `locale` like "it_IT": language and country of search and news results.
    public init(locale: String = Locale.current.identifier, session: URLSession = .shared) {
        let parts = locale.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        language = parts.first?.lowercased() ?? "en"
        region = parts.count > 1 ? parts[1].uppercased() : (language == "en" ? "US" : language.uppercased())
        self.session = session
    }

    public func search(_ query: String) async throws -> String {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            .init(name: "q", value: query), .init(name: "kl", value: "\(region.lowercased())-\(language)"),
        ]
        let html = try await text(at: components.url!)
        let results = Self.searchResults(in: html).prefix(8)
        guard !results.isEmpty else { throw WebError.notFound(query) }
        return results.enumerated()
            .map { "\($0.offset + 1). \($0.element.title) — \($0.element.url)\n   \($0.element.snippet)" }
            .joined(separator: "\n")
    }

    public func news(_ query: String) async throws -> String {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            .init(name: "q", value: query), .init(name: "hl", value: language), .init(name: "gl", value: region),
            .init(name: "ceid", value: "\(region):\(language)"),
        ]
        let items = Self.newsItems(in: try await text(at: components.url!)).prefix(10)
        guard !items.isEmpty else { throw WebError.notFound(query) }
        // Google News links are long opaque redirects: the title already ends with the source name.
        return items.map { "- \($0.date): \($0.title)" }.joined(separator: "\n")
    }

    public func read(_ url: URL) async throws -> ToolOutput {
        guard Self.isPublicWebAddress(url) else { throw WebError.blockedAddress(url.absoluteString) }
        let html = try await text(at: url)
        let image = Self.previewImage(in: html, base: url)
        let text = String(HTMLText.plain(from: html).prefix(5000))
        return ToolOutput(text + (image.map { "\nImage: \($0.absoluteString)" } ?? ""), image: image)
    }

    /// The page's og:image / twitter:image, if it is a public https address.
    static func previewImage(in html: String, base: URL) -> URL? {
        let meta = html.matches(of: /(?i)<meta\b[^>]*>/).map { String($0.output) }
        for tag in meta where tag.range(of: #"(?:og|twitter):image(?::url)?["']"#, options: .regularExpression) != nil {
            guard let content = tag.firstMatch(of: /(?i)content=["']([^"']+)["']/)?.1,
                  let url = URL(string: HTMLText.decodeEntities(String(content)), relativeTo: base)?.absoluteURL,
                  url.scheme == "https", isPublicWebAddress(url)
            else { continue }
            return url
        }
        return nil
    }

    public func weather(_ place: String) async throws -> ToolOutput {
        var geocode = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geocode.queryItems = [
            .init(name: "name", value: place), .init(name: "count", value: "10"),
            .init(name: "language", value: language),
        ]
        let found = try JSONDecoder().decode(GeocodeResponse.self, from: try await data(at: geocode.url!))
        // With count=1 "Milano" is Milano, Texas (421 people): the most populated match is meant.
        guard let location = found.results?.max(by: { ($0.population ?? 0) < ($1.population ?? 0) }) else {
            throw WebError.notFound(place)
        }
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            .init(name: "latitude", value: String(location.latitude)),
            .init(name: "longitude", value: String(location.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
            .init(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            ),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "4"),
        ]
        let response = try JSONDecoder().decode(ForecastResponse.self, from: try await data(at: forecast.url!))
        let name = [location.name, location.country].compactMap(\.self).joined(separator: ", ")
        return ToolOutput(response.summary(for: name), chart: response.chart(for: location.name, language: language))
    }

    public func rateHistory(from: String, to: String) async throws -> ChartSpec {
        let start = Date.now.addingTimeInterval(-30 * 86400).formatted(.iso8601.year().month().day())
        var components = URLComponents(string: "https://api.frankfurter.dev/v1/\(start)..")!
        components.queryItems = [
            .init(name: "base", value: from.uppercased()), .init(name: "symbols", value: to.uppercased()),
        ]
        let response = try JSONDecoder().decode(HistoryResponse.self, from: try await data(at: components.url!))
        let points = response.rates.sorted { $0.key < $1.key }.compactMap { day, rates in
            rates[to.uppercased()].map { ChartSpec.Point(String(day.suffix(5)), $0) }
        }
        return ChartSpec(
            title: "\(from.uppercased()) → \(to.uppercased())", kind: .line, unit: to.uppercased(),
            series: [.init(name: to.uppercased(), points: points)]
        )
    }

    public func exchangeRate(from: String, to: String) async throws -> (rate: Double, date: String) {
        var components = URLComponents(string: "https://api.frankfurter.dev/v1/latest")!
        components.queryItems = [
            .init(name: "base", value: from.uppercased()), .init(name: "symbols", value: to.uppercased()),
        ]
        let response = try JSONDecoder().decode(RatesResponse.self, from: try await data(at: components.url!))
        guard let rate = response.rates[to.uppercased()] else { throw WebError.notFound("\(from)→\(to)") }
        return (rate, response.date)
    }

    // MARK: - HTTP

    /// One retry on temporary server errors (Open-Meteo answers 503 now and then).
    private func data(at url: URL) async throws -> Data {
        do {
            return try await fetch(url)
        } catch WebError.httpStatus(let status) where (502...504).contains(status) {
            try await Task.sleep(for: .seconds(1))
            return try await fetch(url)
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(language)-\(region),\(language);q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebError.httpStatus(http.statusCode)
        }
        // Redirects must not lead to the local network either.
        if let final = response.url, !Self.isPublicWebAddress(final) {
            throw WebError.blockedAddress(final.absoluteString)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.maxPageBytes { break }
        }
        return data
    }

    private func text(at url: URL) async throws -> String {
        let data = try await data(at: url)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Parsing

    struct SearchResult: Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    static func searchResults(in html: String) -> [SearchResult] {
        let blocks = html.components(separatedBy: "class=\"result__a\"").dropFirst()
        return blocks.compactMap { block in
            guard let href = block.firstMatch(of: /href="([^"]+)"/)?.1,
                  let title = block.firstMatch(of: />([^<]*(?:<b>[^<]*<\/b>[^<]*)*)<\/a>/)?.1
            else { return nil }
            let snippet = block.firstMatch(of: /class="result__snippet"[^>]*>(.*?)<\/a>/)?.1 ?? ""
            let url = resolvedLink(String(href))
            guard !url.contains("duckduckgo.com/y.js") else { return nil } // ads
            return SearchResult(
                title: HTMLText.plain(from: String(title)), url: url, snippet: HTMLText.plain(from: String(snippet))
            )
        }
    }

    /// DuckDuckGo sometimes wraps links: //duckduckgo.com/l/?uddg=<encoded url>.
    private static func resolvedLink(_ href: String) -> String {
        let decoded = HTMLText.decodeEntities(href)
        let absolute = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        guard decoded.contains("uddg="), let components = URLComponents(string: absolute),
              let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return decoded }
        return target
    }

    struct NewsItem: Equatable {
        let title: String
        let link: String
        let date: String
    }

    static func newsItems(in rss: String) -> [NewsItem] {
        rss.components(separatedBy: "<item>").dropFirst().compactMap { item -> NewsItem? in
            guard let title = item.firstMatch(of: /<title>(.*?)<\/title>/)?.1,
                  let link = item.firstMatch(of: /<link>(.*?)<\/link>/)?.1
            else { return nil }
            let date = item.firstMatch(of: /<pubDate>(.*?)<\/pubDate>/).map { String($0.1) } ?? ""
            return NewsItem(
                title: HTMLText.decodeEntities(String(title)), link: String(link), date: Self.shortDate(date)
            )
        }
    }

    private static func shortDate(_ rfc822: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = parser.date(from: rfc822) else { return rfc822 }
        return date.formatted(.iso8601.year().month().day())
    }

    /// http(s) on default ports, not localhost, .local or private / link-local IP addresses.
    static func isPublicWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.port == nil || url.port == 443 || url.port == 80,
              let host = url.host(percentEncoded: false)?.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty, host != "localhost", host.contains(".") || host.contains(":"),
              ![".local", ".internal", ".localhost"].contains(where: host.hasSuffix)
        else { return false }
        if host.contains(":") { return isPublicIPv6(host) }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }) else { return true }
        return isPublicIPv4(octets[0], octets[1])
    }

    private static func isPublicIPv4(_ first: Int, _ second: Int) -> Bool {
        switch (first, second) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (100, 64...127), (172, 16...31): false
        default: true
        }
    }

    /// Loopback, unique-local, link-local and IPv4-mapped literals are not on the web.
    private static func isPublicIPv6(_ host: String) -> Bool {
        !["fc", "fd", "fe80", "::"].contains(where: host.hasPrefix)
    }
}

/// HTML to readable text, without a web view.
enum HTMLText {
    static func plain(from html: String) -> String {
        var text = html
        // Prefer the article body when the page has one.
        if let main = text.firstMatch(of: /(?is)<(?:article|main)\b[^>]*>(.*)<\/(?:article|main)>/)?.1 {
            text = String(main)
        }
        text = text.replacing(/(?is)<(script|style|noscript|svg|nav|footer|header|form)\b.*?<\/\1>/, with: " ")
        text = text.replacing(/(?is)<!--.*?-->/, with: " ")
        text = text.replacing(/(?i)<(?:br|\/p|\/div|\/li|\/h[1-6]|\/tr)\b[^>]*>/, with: "\n")
        text = text.replacing(/<[^>]+>/, with: " ")
        text = decodeEntities(text)
        text = text.replacing(/[ \t\u{00A0}]+/, with: " ")
        text = text.replacing(/\s*\n\s*/, with: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
            ("&apos;", "'"), ("&nbsp;", " "), ("&egrave;", "è"), ("&agrave;", "à"), ("&ograve;", "ò"),
            ("&ugrave;", "ù"), ("&igrave;", "ì"), ("&eacute;", "é"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.replacing(/&#(x?)([0-9a-fA-F]+);/) { match in
            let value = UInt32(match.2, radix: match.1.isEmpty ? 10 : 16)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
    }
}

// MARK: - Open-Meteo / Frankfurter payloads

private struct GeocodeResponse: Decodable {
    struct Place: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let population: Int?
    }

    let results: [Place]?
}

private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let time: String
        let temperature2m: Double
        let weatherCode: Int
        let windSpeed10m: Double

        // Explicit: snake_case conversion turns "temperature_2m" into "temperature2M".
        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case windSpeed10m = "wind_speed_10m"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double]
        let temperature2mMin: [Double]
        let precipitationProbabilityMax: [Int?]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperature2mMax = "temperature_2m_max"
            case temperature2mMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }

    let current: Current
    let daily: Daily

    func summary(for place: String) -> String {
        var lines = [
            "\(place), now (\(current.time)): \(current.temperature2m)°C, \(Self.describe(current.weatherCode)), "
                + "wind \(current.windSpeed10m) km/h"
        ]
        for index in daily.time.indices {
            let rain = daily.precipitationProbabilityMax[index].map { ", rain \($0)%" } ?? ""
            lines.append(
                "\(daily.time[index]): \(daily.temperature2mMin[index])–\(daily.temperature2mMax[index])°C, "
                    + Self.describe(daily.weatherCode[index]) + rain
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Daily minimum and maximum temperatures, labelled with short weekdays.
    func chart(for place: String, language: String) -> ChartSpec {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        let labels = daily.time.map { day in
            parser.date(from: day).map {
                $0.formatted(.dateTime.weekday(.abbreviated).day().locale(Locale(identifier: language)))
            } ?? day
        }
        let series = [("Max", daily.temperature2mMax), ("Min", daily.temperature2mMin)].map { name, values in
            ChartSpec.Series(name: name, points: zip(labels, values).map { ChartSpec.Point($0, $1) })
        }
        return ChartSpec(title: "\(place) · °C", kind: .line, unit: "°C", series: series)
    }

    /// WMO weather interpretation codes.
    private static let descriptions: [(ClosedRange<Int>, String)] = [
        (0...0, "clear sky"), (1...2, "partly cloudy"), (3...3, "overcast"), (45...48, "fog"),
        (51...57, "drizzle"), (61...67, "rain"), (71...77, "snow"), (80...82, "rain showers"),
        (85...86, "snow showers"), (95...99, "thunderstorm"),
    ]

    private static func describe(_ code: Int) -> String {
        descriptions.first { $0.0.contains(code) }?.1 ?? "code \(code)"
    }
}

private struct RatesResponse: Decodable {
    let date: String
    let rates: [String: Double]
}

private struct HistoryResponse: Decodable {
    let rates: [String: [String: Double]]
}
