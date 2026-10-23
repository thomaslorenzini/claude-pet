import Foundation
import Network

/// Minimal HTTP/1.1 server bound to 127.0.0.1.
///
/// - `POST /event`: body is a JSON object (the Claude Code hook stdin as-is, or anything with
///   `hook_event_name` / `pet_state`). Always answers 200 quickly.
/// - `POST /control`: app settings, e.g. `{"notch": true}`.
/// - `GET /state`: current aggregated state, for debugging.
final class EventServer {
    static let maxBodySize = 32 * 1024 * 1024

    var onEvent: (([String: Any]) -> Void)?
    /// `POST /control`, e.g. `{"notch": true}`.
    var onControl: (([String: Any]) -> Void)?
    /// Called on the main queue.
    var stateProvider: (() -> [String: Any])?
    var onStatusChange: ((String) -> Void)?

    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "claude-pet.server")

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let status: String
                switch state {
                case .ready: status = "écoute sur 127.0.0.1:\(self.port)"
                case .failed(let error): status = "erreur port \(self.port) : \(error)"
                default: return
                }
                DispatchQueue.main.async { self.onStatusChange?(status) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStatusChange?("erreur : \(error)")
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let request = HTTPRequest(parsing: buffer) {
                self.respond(to: request, on: connection)
            } else if buffer.count > Self.maxBodySize {
                self.send(status: "413 Payload Too Large", body: #"{"ok":false}"#, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        // A browser page could reach localhost; real hooks never send an Origin header.
        if request.headers["origin"] != nil {
            send(status: "403 Forbidden", body: #"{"ok":false}"#, on: connection)
            return
        }
        switch (request.method, request.path) {
        case ("POST", "/event"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                send(status: "400 Bad Request", body: #"{"ok":false,"error":"expected a JSON object"}"#, on: connection)
                return
            }
            DispatchQueue.main.async { self.onEvent?(object) }
            send(status: "200 OK", body: #"{"ok":true}"#, on: connection)
        case ("POST", "/control"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                send(status: "400 Bad Request", body: #"{"ok":false,"error":"expected a JSON object"}"#, on: connection)
                return
            }
            DispatchQueue.main.async { self.onControl?(object) }
            send(status: "200 OK", body: #"{"ok":true}"#, on: connection)
        case ("GET", "/state"):
            DispatchQueue.main.async {
                let state = self.stateProvider?() ?? [:]
                let data = (try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                self.queue.async {
                    self.send(status: "200 OK", body: String(decoding: data, as: UTF8.self), on: connection)
                }
            }
        case ("GET", "/health"):
            send(status: "200 OK", body: #"{"ok":true,"app":"claude-pet"}"#, on: connection)
        default:
            send(status: "404 Not Found", body: #"{"ok":false}"#, on: connection)
        }
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil until the buffer holds the full headers and `Content-Length` bytes of body.
    init?(parsing buffer: Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1].split(separator: "?").first ?? "")
        self.headers = headers
        body = buffer[bodyStart..<(bodyStart + length)]
    }
}
