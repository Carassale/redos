import Foundation

/// Unit and currency conversions without a model: "converti 10 miglia in km", "100 USD to EUR".
public enum UnitConverter {
    // swiftlint:disable:next large_tuple
    private static var pattern: Regex<(Substring, Substring, Substring, Substring)> {
        let verbs = #"(?:converti|convertire|trasforma|convert|quanto (?:fa|fanno|sono|è)|how much is"#
            + #"|how many \w+ (?:is|are|in))?"#
        let body = #"\s*(-?\d+(?:[.,]\d+)?)\s*(.+?)\s+(?:in|to|into|a|=)\s+(.+?)\??"#
        // swiftlint:disable:next force_try
        return try! Regex("^" + verbs + body + "$", as: (Substring, Substring, Substring, Substring).self)
            .ignoresCase()
    }

    /// nil when the input is not a conversion; currencies need `web`.
    public static func answer(
        _ input: String, web: (any WebResearching)?, locale: Locale = .current
    ) async -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?")))
        guard let match = try? pattern.wholeMatch(in: text),
              let amount = Double(match.1.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let fromName = normalized(String(match.2)), toName = normalized(String(match.3))
        if let from = units[fromName], let to = units[toName], type(of: from) == type(of: to) {
            let value = to.converter.value(fromBaseUnitValue: from.converter.baseUnitValue(fromValue: amount))
            return "\(format(amount, locale)) \(from.symbol) = \(format(value, locale)) \(to.symbol)"
        }
        guard let from = currencies[fromName], let to = currencies[toName], let web,
              let (rate, date) = try? await web.exchangeRate(from: from, to: to)
        else { return nil }
        return "\(format(amount, locale)) \(from) = \(format(amount * rate, locale)) \(to) (ECB, \(date))"
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: #"^(?:di |of |the |i |le |gli |dei |delle )"#, with: "", options: .regularExpression
        )
    }

    private static func format(_ value: Double, _ locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)).locale(locale))
    }

    private static let units: [String: Dimension] = {
        let groups: [(Dimension, [String])] = [
            (UnitLength.meters, ["m", "metro", "metri", "meter", "meters", "metre", "metres"]),
            (UnitLength.kilometers, ["km", "chilometro", "chilometri", "kilometer", "kilometers", "kilometre"]),
            (UnitLength.centimeters, ["cm", "centimetro", "centimetri", "centimeter", "centimeters"]),
            (UnitLength.millimeters, ["mm", "millimetro", "millimetri", "millimeter", "millimeters"]),
            (UnitLength.miles, ["mi", "miglio", "miglia", "mile", "miles"]),
            (UnitLength.nauticalMiles, ["nmi", "miglio nautico", "miglia nautiche", "nautical mile", "nautical miles"]),
            (UnitLength.feet, ["ft", "piede", "piedi", "foot", "feet"]),
            (UnitLength.inches, ["in", "\"", "pollice", "pollici", "inch", "inches"]),
            (UnitLength.yards, ["yd", "iarda", "iarde", "yard", "yards"]),
            (UnitMass.kilograms, [
                "kg", "chilo", "chili", "chilogrammo", "chilogrammi", "kilogram", "kilograms", "kilo", "kilos",
            ]),
            (UnitMass.grams, ["g", "grammo", "grammi", "gram", "grams"]),
            (UnitMass.milligrams, ["mg", "milligrammo", "milligrammi", "milligram", "milligrams"]),
            (UnitMass.pounds, ["lb", "lbs", "libbra", "libbre", "pound", "pounds"]),
            (UnitMass.ounces, ["oz", "oncia", "once", "ounce", "ounces"]),
            (UnitMass.metricTons, ["t", "tonnellata", "tonnellate", "ton", "tons", "tonne", "tonnes"]),
            (UnitTemperature.celsius, ["°c", "c", "celsius", "gradi", "gradi celsius", "degrees celsius"]),
            (UnitTemperature.fahrenheit, ["°f", "f", "fahrenheit", "gradi fahrenheit", "degrees fahrenheit"]),
            (UnitTemperature.kelvin, ["k", "kelvin"]),
            (UnitVolume.liters, ["l", "litro", "litri", "liter", "liters", "litre", "litres"]),
            (UnitVolume.milliliters, ["ml", "millilitro", "millilitri", "milliliter", "milliliters"]),
            (UnitVolume.gallons, ["gal", "gallone", "galloni", "gallon", "gallons"]),
            (UnitVolume.cups, ["cup", "cups", "tazza", "tazze"]),
            (UnitVolume.fluidOunces, ["fl oz", "fluid ounce", "fluid ounces", "oncia liquida", "once liquide"]),
            (UnitSpeed.kilometersPerHour, ["km/h", "kmh", "chilometri orari", "chilometri all'ora", "kph"]),
            (UnitSpeed.milesPerHour, ["mph", "miglia orarie", "miles per hour"]),
            (UnitSpeed.metersPerSecond, ["m/s", "metri al secondo", "meters per second"]),
            (UnitSpeed.knots, ["kn", "nodi", "nodo", "knot", "knots"]),
            (UnitArea.squareMeters, ["m2", "m²", "mq", "metri quadri", "metri quadrati", "square meters"]),
            (UnitArea.squareKilometers, ["km2", "km²", "chilometri quadrati", "square kilometers"]),
            (UnitArea.hectares, ["ha", "ettaro", "ettari", "hectare", "hectares"]),
            (UnitArea.acres, ["acro", "acri", "acre", "acres"]),
            (UnitArea.squareFeet, ["ft2", "ft²", "piedi quadrati", "square feet", "sq ft"]),
            (UnitDuration.seconds, ["s", "sec", "secondo", "secondi", "second", "seconds"]),
            (UnitDuration.minutes, ["min", "minuto", "minuti", "minute", "minutes"]),
            (UnitDuration.hours, ["h", "ora", "ore", "hour", "hours"]),
            (UnitInformationStorage.megabytes, ["mb", "megabyte", "megabytes"]),
            (UnitInformationStorage.gigabytes, ["gb", "gigabyte", "gigabytes"]),
            (UnitInformationStorage.terabytes, ["tb", "terabyte", "terabytes"]),
            (UnitInformationStorage.gibibytes, ["gib", "gibibyte", "gibibytes"]),
        ]
        return lookup(groups)
    }()

    private static let currencies: [String: String] = {
        let groups: [(String, [String])] = [
            ("EUR", ["eur", "euro", "€"]),
            ("USD", ["usd", "dollaro", "dollari", "dollar", "dollars", "$", "dollari americani"]),
            ("GBP", ["gbp", "sterlina", "sterline", "pound sterling", "british pounds", "£"]),
            ("CHF", ["chf", "franco svizzero", "franchi svizzeri", "swiss franc", "swiss francs"]),
            ("JPY", ["jpy", "yen", "¥"]), ("CNY", ["cny", "yuan", "renminbi"]),
            ("CAD", ["cad", "dollari canadesi", "canadian dollars"]),
            ("AUD", ["aud", "dollari australiani", "australian dollars"]),
            ("SEK", ["sek", "corone svedesi", "swedish kronor"]),
            ("NOK", ["nok", "corone norvegesi", "norwegian kroner"]),
            ("DKK", ["dkk", "corone danesi", "danish kroner"]), ("PLN", ["pln", "zloty"]),
            ("INR", ["inr", "rupie", "rupees"]), ("BRL", ["brl", "real", "reais"]),
            ("MXN", ["mxn", "pesos messicani", "mexican pesos"]),
        ]
        return lookup(groups)
    }()

    /// Name -> value, the first group winning on duplicates.
    private static func lookup<Value>(_ groups: [(Value, [String])]) -> [String: Value] {
        let pairs = groups.flatMap { value, names in names.map { ($0, value) } }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
}
