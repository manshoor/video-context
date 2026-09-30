import Foundation
@preconcurrency import Network

enum JamLoopbackCallbackError: Error, LocalizedError, Sendable {
    case listenerFailed(String)
    case invalidRequest
    case requestTooLarge

    var errorDescription: String? {
        switch self {
        case .listenerFailed: "The temporary Jam authorization callback could not start."
        case .invalidRequest: "The Jam authorization callback was invalid."
        case .requestTooLarge: "The Jam authorization callback was too large."
        }
    }
}

/// A one-shot HTTP listener bound to the loopback interface for OAuth callbacks.
/// All mutable state is confined to `queue`; `redirectURI` is assigned before
/// `start()` returns and is immutable for the server's externally visible life.
final class JamLoopbackCallbackServer: JamAuthorizationCallbackReceiving, @unchecked Sendable {
    private static let maximumHeaderBytes = 16 * 1_024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.videocontext.jam-oauth-callback")
    private var waiter: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startResolved = false

    private(set) var redirectURI = URL(string: "http://127.0.0.1/callback")!

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> JamLoopbackCallbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = JamLoopbackCallbackServer(listener: listener)
        try await server.startListening()
        return server
    }

    func receiveRedirect() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let result {
                    continuation.resume(with: result)
                } else if waiter == nil {
                    waiter = continuation
                } else {
                    continuation.resume(throwing: JamLoopbackCallbackError.invalidRequest)
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finish(.failure(CancellationError()))
                continuation.resume()
            }
        }
    }

    private func startListening() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                startContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    self.queue.async {
                        self.handleListenerState(state)
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    self.queue.async {
                        self.accept(connection)
                    }
                }
                listener.start(queue: queue)
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard startResolved == false, let port = listener.port else { return }
            startResolved = true
            redirectURI = URL(string: "http://127.0.0.1:\(port.rawValue)/callback")!
            startContinuation?.resume()
            startContinuation = nil
        case .failed(let error):
            if startResolved == false {
                startResolved = true
                startContinuation?.resume(throwing: JamLoopbackCallbackError.listenerFailed(String(describing: error)))
                startContinuation = nil
            } else {
                finish(.failure(JamLoopbackCallbackError.listenerFailed(String(describing: error))))
            }
        case .cancelled:
            if startResolved == false {
                startResolved = true
                startContinuation?.resume(throwing: CancellationError())
                startContinuation = nil
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveHeaders(from: connection, accumulated: Data())
    }

    private func receiveHeaders(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            self.queue.async {
                var request = accumulated
                if let data { request.append(data) }
                if request.count > Self.maximumHeaderBytes {
                    self.respond(to: connection, status: "431 Request Header Fields Too Large")
                    self.finish(.failure(JamLoopbackCallbackError.requestTooLarge))
                    return
                }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handleRequest(request, from: connection)
                } else if error != nil || complete {
                    self.respond(to: connection, status: "400 Bad Request")
                    self.finish(.failure(JamLoopbackCallbackError.invalidRequest))
                } else {
                    self.receiveHeaders(from: connection, accumulated: request)
                }
            }
        }
    }

    private func handleRequest(_ data: Data, from connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            respond(to: connection, status: "400 Bad Request")
            finish(.failure(JamLoopbackCallbackError.invalidRequest))
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              let callback = URL(string: String(parts[1]), relativeTo: redirectURI)?.absoluteURL,
              callback.scheme == redirectURI.scheme, callback.host == redirectURI.host,
              callback.port == redirectURI.port, callback.path == "/callback" else {
            respond(to: connection, status: "400 Bad Request")
            finish(.failure(JamLoopbackCallbackError.invalidRequest))
            return
        }

        respond(to: connection, status: "200 OK")
        finish(.success(callback))
    }

    private func respond(to connection: NWConnection, status: String) {
        let body = "<html><body>Authorization received. Return to Video Context.</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ newResult: Result<URL, Error>) {
        guard result == nil else { return }
        result = newResult
        listener.cancel()
        waiter?.resume(with: newResult)
        waiter = nil
    }
}

protocol JamAuthorizationCallbackCreating: Sendable {
    func makeCallback() async throws -> any JamAuthorizationCallbackReceiving
}

struct LiveJamAuthorizationCallbackFactory: JamAuthorizationCallbackCreating {
    func makeCallback() async throws -> any JamAuthorizationCallbackReceiving {
        try await JamLoopbackCallbackServer.start()
    }
}
