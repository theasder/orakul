import AppKit
import Foundation
import Network

/// One-shot localhost HTTP listener that catches an OAuth redirect
/// (`http://127.0.0.1:<port>/callback?...`) during an MCP authorization flow.
///
/// Why loopback and not a `meetgpt://` scheme: some MCP authorization servers
/// (live-verified: Fireflies) reject custom-scheme redirect URIs at /authorize,
/// while every probed server accepts loopback — so loopback is the one pattern
/// that works everywhere. This is the standard desktop-client approach
/// (mcp-remote style): open the system browser, listen once, hand back the URL.
final class LoopbackRedirectServer: @unchecked Sendable {
    enum LoopbackError: LocalizedError {
        case portBusy
        case timeout
        case cancelled
        var errorDescription: String? {
            switch self {
            case .portBusy: return "Local sign-in port is busy — try connecting again."
            case .timeout:  return "Sign-in timed out. Please try again."
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    private let port: UInt16
    private let queue = DispatchQueue(label: "meetgpt.mcp.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    /// Buffers a result that arrives before the awaiting continuation registers.
    private var pendingResult: Result<URL, Error>?
    /// First finish wins; everything after is dropped.
    private var finished = false

    init(port: UInt16) { self.port = port }

    /// Start listening, open the authorization URL in the default browser, and
    /// resolve with the full callback URL when the browser redirects back.
    func run(opening authorizationURL: URL, timeout: TimeInterval = 300) async throws -> URL {
        let params = NWParameters.tcp
        // Bind to loopback only — never expose the callback port to the network.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else { throw LoopbackError.portBusy }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(.failure(LoopbackError.portBusy)) }
        }
        listener.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(LoopbackError.timeout))
        }

        await MainActor.run { NSApp.activate(ignoringOtherApps: false) }
        _ = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let ready = pendingResult {
                    pendingResult = nil
                    lock.unlock()
                    cont.resume(with: ready)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Stop an in-flight browser flow. Idempotent and safe to call from any
    /// queue; the same first-result-wins gate protects timeout/callback races.
    func cancel() {
        finish(.failure(LoopbackError.cancelled))
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            // The request line ends at the first CRLF; that's all we need.
            if let lineEnd = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
                self.route(line, on: connection)
            } else if error == nil, buffer.count < 16 * 1024 {
                self.receiveRequest(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    /// Decide whether an HTTP request line is THE OAuth callback, and rebuild
    /// the URL it carries.
    ///
    /// Pure and separate from the socket because this is a security boundary
    /// that deserves direct tests: it decides which single request gets to
    /// deliver an authorization code and consume the one-shot continuation. A
    /// browser aims several requests at this port — the callback itself, then
    /// `/favicon.ico`, sometimes a preflight — and letting the wrong one
    /// through ends the flow with no code.
    ///
    /// The path match is exact rather than a prefix: `hasPrefix("/callback")`
    /// also accepted `/callbackanything`, which is not a path any provider is
    /// configured to redirect to and only widened what could consume the flow.
    static func callbackURL(fromRequestLine line: String, port: UInt16) -> URL? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let path = String(parts[1])
        guard path == "/callback" || path.hasPrefix("/callback?") else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    /// Parse "GET /callback?code=…&state=… HTTP/1.1"; ignore anything else
    /// (favicon probes etc.) so a stray request can't consume the one-shot.
    private func route(_ requestLine: String, on connection: NWConnection) {
        guard let url = Self.callbackURL(fromRequestLine: requestLine, port: port) else {
            respond(connection, status: "404 Not Found", body: "Not found.")
            return
        }
        respond(connection, status: "200 OK",
                body: "<html><body style=\"font-family:-apple-system;padding:2em\">" +
                      "<h2>Cruxwing is connected.</h2><p>You can close this tab and return to the app.</p></body></html>")
        finish(.success(url))
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n" +
                      "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Resume the continuation exactly once (buffering if it isn't registered
    /// yet) and tear the listener down. Later calls are dropped.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        if cont == nil { pendingResult = result }
        let activeListener = listener
        listener = nil
        lock.unlock()

        activeListener?.cancel()
        cont?.resume(with: result)
    }
}
