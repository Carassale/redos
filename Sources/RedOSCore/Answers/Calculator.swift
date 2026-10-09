import Foundation

/// Exact arithmetic without a model: "2+2", "quanto fa 3,5 per 4", "what is 20% of 150".
public enum Calculator {
    private static let prefixes = [
        "quanto fa", "quanto è", "quanto e", "calcola", "fammi il calcolo", "what is", "what's", "calculate",
        "compute", "how much is",
    ]
    private static let words: [(String, String)] = [
        ("moltiplicato per", "*"), ("diviso per", "/"), ("divided by", "/"), ("elevato alla", "^"),
        ("to the power of", "^"), ("più", "+"), ("piu", "+"), ("plus", "+"), ("meno", "-"), ("minus", "-"),
        ("per", "*"), ("times", "*"), ("x", "*"), ("diviso", "/"), ("over", "/"),
    ]

    /// "2 + 2 = 4", or nil when the input is not a calculation.
    public static func answer(_ input: String, locale: Locale = .current) -> String? {
        guard let expression = expression(from: input), let value = evaluate(expression) else { return nil }
        return "\(expression.replacingOccurrences(of: "*", with: "×")) = \(format(value, locale: locale))"
    }

    static func expression(from input: String) -> String? {
        var text = input.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?=")))
        for prefix in prefixes where text.hasPrefix(prefix + " ") {
            text = String(text.dropFirst(prefix.count))
            break
        }
        // "20% di 150" / "20% of 150"
        text = text.replacingOccurrences(
            of: #"(\d)\s*%\s*(?:di|of|del|della)\s+"#, with: "$1/100*", options: .regularExpression
        )
        for (word, symbol) in words {
            text = text.replacingOccurrences(
                of: #"(?<=[\d\s)])\#(word)(?=[\s\d(])"#, with: " \(symbol) ", options: .regularExpression
            )
        }
        text = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: ":", with: "/")
        // Italian decimals: "3,5" (then dots are thousands separators).
        if text.range(of: #"\d,\d"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        text = text.replacingOccurrences(of: " ", with: "")
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^()")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(allowed.contains),
              text.contains(where: \.isNumber),
              text.dropFirst().contains(where: { "+-*/^".contains($0) })
        else { return nil }
        return text
    }

    static func evaluate(_ expression: String) -> Double? {
        var parser = Parser(characters: Array(expression))
        guard let value = parser.sum(), parser.isAtEnd, value.isFinite else { return nil }
        return value
    }

    private static func format(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) < 1 ? 8 : 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// sum := product (('+'|'-') product)*; product := power (('*'|'/') power)*; power := unary ('^' power)?
    private struct Parser {
        let characters: [Character]
        var index = 0
        var isAtEnd: Bool { index == characters.count }

        mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let rhs = product() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func product() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                index += 1
                guard let rhs = power(), op == "*" || rhs != 0 else { return nil }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            guard peek() == "^" else { return base }
            index += 1
            guard let exponent = power(), abs(exponent) <= 1000 else { return nil }
            return pow(base, exponent)
        }

        mutating func unary() -> Double? {
            if peek() == "-" {
                index += 1
                return unary().map { -$0 }
            }
            if peek() == "+" {
                index += 1
                return unary()
            }
            return primary()
        }

        mutating func primary() -> Double? {
            if peek() == "(" {
                index += 1
                guard let value = sum(), peek() == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            while let character = peek(), character.isNumber || character == "." { index += 1 }
            return index > start ? Double(String(characters[start..<index])) : nil
        }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }
    }
}
