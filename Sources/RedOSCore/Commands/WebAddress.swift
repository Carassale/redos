import Foundation

public enum WebAddress {
    /// "google.com" or "https://google.com/x" as an https/http URL; nil for anything else (other schemes included).
    public static func url(from text: String) -> URL? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(where: \.isWhitespace) else { return nil }
        let candidate = address.contains("://") ? address : "https://\(address)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return url
    }
}
