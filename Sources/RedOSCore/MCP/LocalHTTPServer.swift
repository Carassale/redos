import Foundation
import Network

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    /// Lowercased names.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// A complete request, or nil while more bytes are needed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...]
            headers[line[..<colon].lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(
            method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length))
        )
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A minimal HTTP/1.1 server on the loopback interface: one request per connection.
public final class LocalHTTPServer: @unchecked Sendable {
    private static let maxRequestSize = 4_000_000
    private let listener: NWListener
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "dev.redos.http")

    public init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        // Bound to 127.0.0.1 only: other machines cannot connect.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Calls `onFailure` if the port cannot be used (e.g. already taken).
    public func start(onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                onFailure(error.localizedDescription)
            // A port still held by another process leaves the listener waiting: report it so the caller retries.
            case .waiting(.posix(.EADDRINUSE)):
                self?.listener.cancel()
                onFailure(POSIXError(.EADDRINUSE).localizedDescription)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let request = HTTPRequest.parse(buffer) {
                let handler = handler
                Task {
                    let response = await handler(request)
                    let reply = response.serialized
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if done || error != nil || buffer.count > Self.maxRequestSize {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer)
            }
        }
    }
}
