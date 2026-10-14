import Foundation

public enum ProviderError: Error, Equatable, LocalizedError {
    case unreachable(String)
    case http(Int, String)
    case emptyResponse
    case missingAPIKey(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let service): String(localized: "\(service) is not reachable.")
        case .http(let status, let detail): String(localized: "The AI provider returned HTTP \(status): \(detail)")
        case .emptyResponse: String(localized: "The AI provider returned an empty answer.")
        case .missingAPIKey(let provider): String(localized: "Missing API key for \(provider). Add it in Settings.")
        case .commandFailed(let detail): String(localized: "The AI command failed: \(detail)")
        }
    }
}

/// Providers that can list the models available to the user.
public protocol ModelListing: Sendable {
    func listModels() async throws -> [String]
}

enum HTTP {
    static func send(_ request: URLRequest, service: String, session: URLSession) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.unreachable(service)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status, String(bytes: data.prefix(300), encoding: .utf8) ?? "")
        }
        return data
    }

    static func request(
        _ url: URL, method: String = "GET", headers: [String: String], body: JSONValue? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}

enum JSONText {
    /// First JSON object in model output, tolerating code fences and surrounding prose.
    static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        for end in text[start...].indices where text[end] == "}" {
            let candidate = String(text[start...end])
            if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) is [String: Any] {
                return candidate
            }
        }
        return nil
    }
}

extension ChatMessage {
    /// OpenAI chat format: images as data URLs next to the text.
    var jsonValue: JSONValue {
        guard let images, !images.isEmpty else {
            return .object(["role": .string(role), "content": .string(content)])
        }
        let pictures: [JSONValue] = images.map { image in
            .object([
                "type": "image_url",
                "image_url": .object(["url": .string("data:image/jpeg;base64," + image.base64EncodedString())]),
            ])
        }
        return .object([
            "role": .string(role),
            "content": .array([.object(["type": "text", "text": .string(content)])] + pictures),
        ])
    }

    /// Anthropic Messages format.
    var anthropicJSON: JSONValue {
        guard let images, !images.isEmpty else { return jsonValue }
        let pictures: [JSONValue] = images.map { image in
            .object([
                "type": "image",
                "source": .object([
                    "type": "base64", "media_type": "image/jpeg", "data": .string(image.base64EncodedString()),
                ]),
            ])
        }
        return .object([
            "role": .string(role),
            "content": .array(pictures + [.object(["type": "text", "text": .string(content)])]),
        ])
    }
}
