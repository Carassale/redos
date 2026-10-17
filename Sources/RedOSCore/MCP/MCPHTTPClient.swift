import Foundation

/// A remote MCP server over Streamable HTTP: one POST per message, answered with JSON or a short event stream.
public actor MCPHTTPClient: MCPClient {
    private let url: URL
    private let headers: [String: String]
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 0

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    public func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let data = try await post(.object([
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params),
        ]))
        guard let message = Self.messages(in: data).first(where: { $0["id"] == .number(Double(id)) }) else {
            throw ProviderError.commandFailed("MCP server did not answer \(method)")
        }
        if let error = message["error"] {
            throw ProviderError.commandFailed(error["message"]?.string ?? "MCP error")
        }
        let result = message["result"] ?? .null
        if method == "initialize" { protocolVersion = result["protocolVersion"]?.string }
        return result
    }

    public func notify(_ method: String) async throws {
        _ = try await post(.object(["jsonrpc": "2.0", "method": .string(method)]))
    }

    public func stop() {
        sessionID = nil
        protocolVersion = nil
    }

    private func post(_ message: JSONValue) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONEncoder().encode(message)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.commandFailed(status == 401 || status == 403
                ? "MCP server refused the credentials (HTTP \(status))"
                : "MCP server returned HTTP \(status)")
        }
        if let session = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = session
        }
        return data
    }

    /// The JSON-RPC messages of a response body: plain JSON (object or batch) or `data:` lines of an event stream.
    static func messages(in data: Data) -> [JSONValue] {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if case .array(let batch) = value { return batch }
            return [value]
        }
        let text = (String(bytes: data, encoding: .utf8) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        return text.components(separatedBy: "\n\n").compactMap { event in
            let payload = event.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).drop(while: { $0 == " " }) }
                .joined(separator: "\n")
            return try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        }
    }
}
