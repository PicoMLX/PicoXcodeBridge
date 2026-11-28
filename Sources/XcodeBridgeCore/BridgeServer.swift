import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import ServiceLifecycle
import Synchronization

/// What the bridge listens on and what it launches for each session.
public struct BridgeConfiguration: Sendable {
    /// The port Pico expects when the bridge hasn't published one yet.
    public static let defaultPort = 7428

    /// Ports to try, in order, until one is free. 0 means any free port.
    public var ports: [Int]
    public var childExecutable = URL(filePath: "/usr/bin/xcrun")
    public var childArguments = ["mcpbridge"]
    /// `nil` passes the bridge's own environment, which `xcrun` uses to pick the Xcode.
    public var childEnvironment: [String: String]?
    /// A session with no open stream is stopped after this long without a request.
    public var idleTimeout: Duration = .seconds(30 * 60)
    /// How often open SSE streams get a comment line, to keep clients' idle timers from firing.
    public var heartbeatInterval: Duration = .seconds(15)
    /// The most children at once. Beyond it a new session replaces the least recently used idle one.
    public var maxSessions = 8
    public var maxRequestBytes = 32 * 1024 * 1024

    /// Tries `preferredPort` (the port the bridge used last time, so Pico's saved URL keeps
    /// working), then the default port and the nine after it, then any free port.
    public init(preferredPort: Int? = nil) {
        var ports = [preferredPort].compactMap { $0 }.filter { $0 > 0 }
        for port in Self.defaultPort..<(Self.defaultPort + 10) where !ports.contains(port) {
            ports.append(port)
        }
        self.ports = ports + [0]
    }

    public init(ports: [Int]) {
        self.ports = ports
    }
}

/// The checks every request passes before it reaches a session.
public enum RequestGuard {
    public enum Rejection: Equatable, Sendable {
        /// Browsers send `Origin`; MCP clients outside a browser don't. 403.
        case originNotAllowed
        /// Anything but `127.0.0.1:<port>` or `localhost:<port>`, the defense against DNS
        /// rebinding. 421.
        case hostNotAllowed
        /// A missing or wrong bearer token. 401.
        case unauthorized
    }

    /// The Host and Origin checks come first, so a web page learns nothing about the token.
    public static func check(host: String?, origin: String?, authorization: String?, port: Int, token: String) -> Rejection? {
        if origin != nil { return .originNotAllowed }
        guard let host, isAllowedHost(host, port: port) else { return .hostNotAllowed }
        guard let authorization, isAuthorized(authorization, token: token) else { return .unauthorized }
        return nil
    }

    static func isAllowedHost(_ host: String, port: Int) -> Bool {
        guard let colon = host.lastIndex(of: ":") else { return false }
        let name = host[..<colon].lowercased()
        guard name == "127.0.0.1" || name == "localhost" else { return false }
        return Int(host[host.index(after: colon)...]) == port
    }

    static func isAuthorized(_ authorization: String, token: String) -> Bool {
        let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer", !token.isEmpty else { return false }
        return constantTimeEqual(Array(parts[1].utf8), Array(token.utf8))
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}

extension HTTPField.Name {
    static let mcpSessionID = Self("Mcp-Session-Id")!
}

/// MCP streamable HTTP on `127.0.0.1`, passed through to one `xcrun mcpbridge` per session.
///
/// - `POST /mcp` with `initialize` starts a session and its child; the response carries
///   `Mcp-Session-Id`.
/// - `POST /mcp` with a request answers with an SSE stream of every line the child writes for
///   it (`notifications/progress` included), ending with the response.
/// - `POST /mcp` with a notification or a response answers 202.
/// - `GET /mcp` opens the session's stream for the child's other messages.
/// - `DELETE /mcp` stops the session's child.
public final class BridgeServer: Sendable {
    public let configuration: BridgeConfiguration
    private let token: Mutex<String>
    private let boundPort = Mutex<Int?>(nil)
    let sessions: SessionStore

    public init(
        configuration: BridgeConfiguration,
        token: String,
        onSessionCountChange: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.token = Mutex(token)
        self.sessions = SessionStore(configuration: configuration, onCountChange: onSessionCountChange)
    }

    /// The port the bridge listens on, once it does.
    public var port: Int? { boundPort.withLock { $0 } }

    public var sessionCount: Int {
        get async { await sessions.count }
    }

    /// Replaces the token and ends every session, so clients holding the old one are cut off.
    public func resetToken(to newToken: String) async {
        token.withLock { $0 = newToken }
        await sessions.closeAll()
    }

    /// Listens until the task is cancelled. Calls `onListening` with the port it got.
    public func run(onListening: @escaping @Sendable (Int) async -> Void = { _ in }) async throws {
        let reaper = Task { [sessions, configuration] in
            let interval = min(configuration.idleTimeout / 4, .seconds(30))
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await sessions.closeIdle(idleTimeout: configuration.idleTimeout)
            }
        }
        defer { reaper.cancel() }

        var lastError: (any Error)?
        for candidate in configuration.ports {
            let app = Application(
                responder: CallbackResponder { [self] (request: Request, _: BasicRequestContext) in
                    await respond(to: request)
                },
                configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: candidate)),
                onServerRunning: { [self] channel in
                    let port = channel.localAddress?.port ?? candidate
                    boundPort.withLock { $0 = port }
                    await onListening(port)
                }
            )
            // The group runs in its own task so that cancelling `run` shuts the server down
            // gracefully instead of cancelling its connections mid-write.
            let group = ServiceGroup(services: [app], logger: app.logger)
            let running = Task { try await group.run() }
            do {
                try await withTaskCancellationHandler {
                    try await running.value
                } onCancel: { [sessions] in
                    Task {
                        // Open SSE streams would otherwise hold up the shutdown.
                        await sessions.closeAll()
                        await group.triggerGracefulShutdown()
                    }
                }
                await sessions.closeAll()
                return
            } catch let error as IOError where error.errnoCode == EADDRINUSE && port == nil {
                lastError = error
                continue
            } catch {
                await sessions.closeAll()
                throw error
            }
        }
        throw lastError ?? CancellationError()
    }

    // MARK: Routing

    func respond(to request: Request) async -> Response {
        if let rejection = RequestGuard.check(
            host: request.head.authority,
            origin: request.headers[.origin],
            authorization: request.headers[.authorization],
            port: port ?? -1,
            token: token.withLock { $0 }
        ) {
            switch rejection {
            case .originNotAllowed:
                return Self.error(.forbidden, "Requests with an Origin header are refused.")
            case .hostNotAllowed:
                return Self.error(.misdirectedRequest, "Use http://127.0.0.1:\(port ?? 0)/mcp.")
            case .unauthorized:
                var response = Self.error(.unauthorized, "Missing or wrong bearer token.")
                response.headers[.wwwAuthenticate] = "Bearer"
                return response
            }
        }
        guard request.uri.path == "/mcp" else {
            return Self.error(.notFound, "Not found. The MCP endpoint is /mcp.")
        }
        switch request.method {
        case .post: return await post(request)
        case .get: return await get(request)
        case .delete: return await delete(request)
        default:
            var response = Self.error(.methodNotAllowed, "Use GET, POST or DELETE.")
            response.headers[.allow] = "GET, POST, DELETE"
            return response
        }
    }

    private func post(_ request: Request) async -> Response {
        var request = request
        let body: ByteBuffer
        do {
            body = try await request.collectBody(upTo: configuration.maxRequestBytes)
        } catch {
            return Self.error(.contentTooLarge, "The request body is too large.")
        }
        // stdio framing is one message per line. Outside strings, where JSON escapes them,
        // newlines are only whitespace, so they become spaces.
        let line = Data(body.readableBytesView.map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
        if line.first(where: { !LineSplitter.isWhitespace($0) }) == UInt8(ascii: "[") {
            return Self.error(.badRequest, "JSON-RPC batches aren't supported.")
        }
        guard let message = JSONRPCMessage(line) else {
            return Self.error(.badRequest, "The body isn't a JSON-RPC message.", code: BridgeErrorCode.parseError)
        }

        if case .request(let id) = message.kind, message.method == "initialize" {
            let session: MCPSession
            do {
                session = try await sessions.create()
            } catch {
                switch error {
                case .tooManySessions:
                    return Self.error(.serviceUnavailable, "Too many open sessions. Close one and try again.", id: id)
                case .launchFailed(let reason):
                    return Self.error(.badGateway, "Couldn't start xcrun mcpbridge: \(reason)", id: id, code: BridgeErrorCode.xcodeUnavailable)
                }
            }
            return await stream(for: line, id: id, progressToken: message.progressToken, in: session)
        }

        guard let sessionID = request.headers[.mcpSessionID] else {
            return Self.error(.badRequest, "The Mcp-Session-Id header is required. Send initialize first.")
        }
        guard let session = await sessions.session(sessionID) else {
            return Self.sessionNotFound
        }
        switch message.kind {
        case .request(let id):
            return await stream(for: line, id: id, progressToken: message.progressToken, in: session)
        case .notification, .response:
            guard await session.forward(line, cancelling: message.cancelledRequest) else { return Self.sessionNotFound }
            return Response(status: .accepted)
        }
    }

    private func stream(for line: Data, id: JSONRPCID, progressToken: JSONRPCID?, in session: MCPSession) async -> Response {
        switch await session.open(request: line, id: id, progressToken: progressToken) {
        case .stream(let stream):
            return Self.eventStream(stream, sessionID: session.id)
        case .duplicateID:
            return Self.error(.conflict, "A request with this id is already in progress.", id: id)
        case .closed:
            return Self.sessionNotFound
        }
    }

    private func get(_ request: Request) async -> Response {
        guard let sessionID = request.headers[.mcpSessionID] else {
            return Self.error(.badRequest, "The Mcp-Session-Id header is required.")
        }
        guard let session = await sessions.session(sessionID), let stream = await session.openServerStream() else {
            return Self.sessionNotFound
        }
        return Self.eventStream(stream, sessionID: sessionID)
    }

    private func delete(_ request: Request) async -> Response {
        guard let sessionID = request.headers[.mcpSessionID] else {
            return Self.error(.badRequest, "The Mcp-Session-Id header is required.")
        }
        guard let session = await sessions.remove(sessionID) else { return Self.sessionNotFound }
        await session.close()
        return Response(status: .ok)
    }

    // MARK: Responses

    private static func eventStream(_ stream: AsyncStream<Data>, sessionID: String) -> Response {
        var headers: HTTPFields = [.contentType: "text/event-stream", .cacheControl: "no-cache"]
        headers[.mcpSessionID] = sessionID
        return Response(status: .ok, headers: headers, body: ResponseBody { writer in
            // Hummingbird sends the headers with the first bytes of the body. Without this the
            // client would wait for them until the child wrote something or a heartbeat came.
            try await writer.write(ByteBuffer(bytes: SSE.opened))
            for await chunk in stream {
                try await writer.write(ByteBuffer(bytes: chunk))
            }
            try await writer.finish(nil)
        })
    }

    private static let sessionNotFound = error(.notFound, "Session not found. Send initialize to start a new one.", code: BridgeErrorCode.sessionNotFound)

    private static func error(_ status: HTTPResponse.Status, _ message: String, id: JSONRPCID? = nil, code: Int = BridgeErrorCode.badRequest) -> Response {
        let body = JSONRPCMessage.errorLine(id: id, code: code, message: message)
        return Response(status: status, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: body)))
    }
}
