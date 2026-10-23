import Foundation
import Network

/// Minimal HTTP/1.1 server bound to 127.0.0.1.
///
/// If the preferred port is taken, it tries the next ones (`portAttempts` in all), unless the
/// occupant is another Claude Pet: then `onDuplicate` fires instead, so two pets never run at once.
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
    /// Called on the main queue with the port actually bound.
    var onReady: ((UInt16) -> Void)?
    /// Another Claude Pet answers on this port. Called on the main queue.
    var onDuplicate: ((UInt16) -> Void)?

    static let portAttempts = 20

    private let preferredPort: UInt16
    private(set) var port: UInt16?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "claude-pet.server")

    init(preferredPort: UInt16) {
        self.preferredPort = preferredPort
    }

    func start() {
        listen(on: preferredPort, attempt: 0)
    }

    private func listen(on port: UInt16, attempt: Int) {
        let status: (String) -> Void = { message in DispatchQueue.main.async { self.onStatusChange?(message) } }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            // No reuse: a port held by anyone else must fail here, not be silently shared.
            params.allowLocalEndpointReuse = false
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = port
                    status("écoute sur 127.0.0.1:\(port)")
                    DispatchQueue.main.async { self.onReady?(port) }
                case .failed(let error):
                    listener?.cancel()
                    guard case .posix(.EADDRINUSE) = error else {
                        status("erreur port \(port) : \(error)")
                        return
                    }
                    self.probe(port) { isPet in
                        if isPet {
                            DispatchQueue.main.async { self.onDuplicate?(port) }
                        } else if attempt + 1 < Self.portAttempts, port < UInt16.max {
                            self.listen(on: port + 1, attempt: attempt + 1)
                        } else {
                            status("aucun port libre entre \(self.preferredPort) et \(port)")
                        }
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status("erreur : \(error)")
        }
    }

    /// Asks whoever holds `port` whether it is a Claude Pet (`GET /health`). Raw TCP rather than
    /// URLSession, so App Transport Security never gets in the way.
    private func probe(_ port: UInt16, completion: @escaping (Bool) -> Void) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var done = false
        let finish: (Bool) -> Void = { isPet in
            guard !done else { return }
            done = true
            connection.cancel()
            completion(isPet)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    finish(data.map { String(decoding: $0, as: UTF8.self).contains(#""app":"claude-pet""#) } ?? false)
                }
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 0.5) { finish(false) }
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
