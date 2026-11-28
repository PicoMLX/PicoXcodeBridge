import Foundation
import os
import Synchronization

let log = Logger(subsystem: "com.starlingprotocol.pico-xcode-bridge", category: "bridge")

// MARK: - JSON-RPC

/// A JSON-RPC id. MCP allows a string or an integer.
enum JSONRPCID: Hashable, Sendable {
    case int(Int64)
    case string(String)

    init?(json: Any?) {
        switch json {
        case let string as String:
            self = .string(string)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let integer = number.int64Value
            guard NSNumber(value: integer) == number else { return nil }
            self = .int(integer)
        default:
            return nil
        }
    }

    var json: Any {
        switch self {
        case .int(let value): value
        case .string(let value): value
        }
    }
}

/// The few fields the bridge reads to route a message. The bridge never rewrites a message: it
/// reads these and forwards the original bytes.
struct JSONRPCMessage: Sendable {
    enum Kind: Equatable, Sendable {
        case request(JSONRPCID)
        case notification
        /// A result or an error. The id is `nil` for an error about a message that had no usable id.
        case response(JSONRPCID?)
    }

    let kind: Kind
    let method: String?
    /// `params._meta.progressToken` on a request, `params.progressToken` on `notifications/progress`.
    let progressToken: JSONRPCID?
    /// `params.requestId` on `notifications/cancelled`.
    let cancelledRequest: JSONRPCID?

    /// `nil` when `data` isn't a JSON-RPC message object. A batch (a JSON array) is not one.
    init?(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let method = object["method"] as? String
        let params = object["params"] as? [String: Any]
        let hasID = object.keys.contains("id")
        let id = JSONRPCID(json: object["id"])

        switch (method, hasID) {
        case (.some, true):
            guard let id else { return nil }
            kind = .request(id)
        case (.some, false):
            kind = .notification
        case (.none, true) where object["result"] != nil || object["error"] != nil:
            kind = .response(id)
        default:
            return nil
        }
        self.method = method
        let meta = params?["_meta"] as? [String: Any]
        progressToken = JSONRPCID(json: params?["progressToken"]) ?? JSONRPCID(json: meta?["progressToken"])
        cancelledRequest = method == "notifications/cancelled" ? JSONRPCID(json: params?["requestId"]) : nil
    }

    /// One compact line: a JSON-RPC error response from the bridge itself.
    static func errorLine(id: JSONRPCID?, code: Int, message: String) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id?.json ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// JSON-RPC error codes for the bridge's own errors, in the implementation-defined range.
enum BridgeErrorCode {
    /// A malformed HTTP request: missing session id, batch, bad body.
    static let badRequest = -32000
    /// Unknown or expired `Mcp-Session-Id`. Same code as the MCP TypeScript SDK.
    static let sessionNotFound = -32001
    /// `xcrun mcpbridge` couldn't start, or exited before it answered.
    static let xcodeUnavailable = -32002
    static let parseError = -32700
}

/// Server-Sent Events framing for the bridge's streams.
enum SSE {
    static func event(_ line: Data) -> Data {
        var event = Data("event: message\ndata: ".utf8)
        event.append(line)
        event.append(contentsOf: Array("\n\n".utf8))
        return event
    }

    /// The comment each stream starts with, so the response headers go out at once.
    static let opened = Data(": open\n\n".utf8)

    /// A comment line. Clients ignore it, but it resets their idle timers (URLSession's
    /// `timeoutIntervalForRequest` defaults to 60 s, and Xcode can stay silent for longer while it
    /// waits for the user to approve a project), and a failed write tells us the client is gone.
    static let heartbeat = Data(": keepalive\n\n".utf8)
}

// MARK: - Line framing

/// Splits a byte stream into newline-delimited lines, MCP's stdio framing. It splits on `\n` only:
/// JSON may carry U+2028 and U+2029 unescaped inside strings, which a Unicode-aware line reader
/// would break apart.
struct LineSplitter {
    private var partial = Data()

    /// The complete lines in `chunk` (and what earlier chunks left over), without their `\n` or a
    /// trailing `\r`. Blank lines are dropped.
    mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            partial.append(rest[rest.startIndex..<newline])
            rest = rest[rest.index(after: newline)...]
            if partial.last == 0x0D { partial.removeLast() }
            if partial.contains(where: { !Self.isWhitespace($0) }) { lines.append(partial) }
            partial = Data()
        }
        partial.append(rest)
        return lines
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

// MARK: - Child process

/// The text a child wrote to stderr most recently, for error messages.
private final class StderrTail: Sendable {
    private let text = Mutex("")

    func append(_ line: String) {
        text.withLock { text in
            text += line + "\n"
            if text.count > 2_000 { text = String(text.suffix(1_000)) }
        }
    }

    var lastLine: String? {
        text.withLock { $0.split(separator: "\n").last.map(String.init) }
    }
}

/// Process exit is independent of stdout EOF: a descendant may keep a pipe open. Multiple
/// shutdown waiters must observe the same status without competing for an AsyncStream element.
private final class ChildExit: Sendable {
    private struct State {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }
    private let state = Mutex(State())

    func finish(_ status: Int32) {
        let waiters = state.withLock { state in
            state.status = status
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = state.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }
}

/// One `xcrun mcpbridge` process (or, in tests, a fake) with line-delimited JSON-RPC on its
/// stdin and stdout.
final class StdioChild: @unchecked Sendable {
    // @unchecked: every stored property is set once in `init`. Writes to stdin go through
    // `writeQueue`, so they're serialized and never block a Swift concurrency thread.
    let lines: AsyncStream<Data>
    let pid: Int32
    private let process: Process
    private let stdin: FileHandle
    private let writeQueue = DispatchQueue(label: "com.starlingprotocol.pico-xcode-bridge.stdin")
    private let exit = ChildExit()
    private let stderrClosed: AsyncStream<Void>
    private let stderrTail = StderrTail()

    private static let ignoreSIGPIPE: Void = {
        // A write to a child that already exited must fail with EPIPE, not kill the bridge.
        signal(SIGPIPE, SIG_IGN)
    }()

    init(executable: URL, arguments: [String], environment: [String: String]?) throws {
        _ = Self.ignoreSIGPIPE
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exit = self.exit
        process.terminationHandler = { process in
            exit.finish(process.terminationStatus)
        }
        try process.run()

        self.process = process
        self.pid = process.processIdentifier
        self.stdin = stdinPipe.fileHandleForWriting

        let (lines, linesContinuation) = AsyncStream<Data>.makeStream()
        self.lines = lines
        let stdout = stdoutPipe.fileHandleForReading
        Thread.detachNewThread {
            var splitter = LineSplitter()
            while case let chunk = stdout.availableData, !chunk.isEmpty {
                for line in splitter.append(chunk) { linesContinuation.yield(line) }
            }
            linesContinuation.finish()
        }
        let (stderrClosed, stderrContinuation) = AsyncStream<Void>.makeStream()
        self.stderrClosed = stderrClosed
        let stderr = stderrPipe.fileHandleForReading
        let tail = stderrTail
        let pid = pid
        Thread.detachNewThread {
            var splitter = LineSplitter()
            while case let chunk = stderr.availableData, !chunk.isEmpty {
                for line in splitter.append(chunk) {
                    let text = String(decoding: line, as: UTF8.self)
                    log.info("child \(pid) stderr: \(text, privacy: .public)")
                    tail.append(text)
                }
            }
            stderrContinuation.finish()
        }
    }

    /// Writes one message and its newline. JSON-RPC messages from the bridge never contain one.
    func send(_ line: Data) {
        var line = line
        line.append(0x0A)
        writeQueue.async { [stdin, pid, framed = line] in
            do {
                try stdin.write(contentsOf: framed)
            } catch {
                log.error("child \(pid): write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Closes stdin, which `mcpbridge` takes as the end of the session, and sends SIGTERM if it's
    /// still running two seconds later.
    func terminate() {
        writeQueue.async { [stdin] in try? stdin.close() }
        // A blocked stdin write must not hold up termination escalation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [self] in
            // The user has ended this server session. A child that ignores SIGTERM must not
            // survive token revocation or prevent the companion from quitting.
            if process.isRunning { _ = kill(pid, SIGKILL) }
        }
    }

    func waitForTermination() async { _ = await exit.value() }

    /// The output pump also waits briefly for stderr so errors can quote the child's last words.
    func waitForExit() async -> Int32 {
        let status = await exit.value()
        // Give the stderr reader a moment to catch up, so an error message can quote the child's
        // last words, but don't wait on a grandchild that kept stderr open.
        await withTaskGroup { [stderrClosed] group in
            group.addTask { for await _ in stderrClosed {} }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
        return status
    }

    var lastStderrLine: String? { stderrTail.lastLine }
}

// MARK: - Session

/// One MCP session: one child process, the POST streams waiting for its responses, and the GET
/// stream for everything else it sends.
actor MCPSession {
    nonisolated let id: String
    nonisolated let childPID: Int32
    nonisolated let profileID: String
    private let profileName: String
    private let child: StdioChild
    private let heartbeatInterval: Duration
    private let onExit: @Sendable (String) async -> Void

    private struct Stream {
        let token = UUID()
        let continuation: AsyncStream<Data>.Continuation
    }

    /// POST streams by the id of the request they wait on.
    private var pending: [JSONRPCID: Stream] = [:]
    /// Progress tokens by request id, so `notifications/progress` reaches the right POST stream.
    private var progressTokens: [JSONRPCID: JSONRPCID] = [:]
    private var serverStream: Stream?
    /// Server-initiated messages that arrived while no stream was open.
    private var backlog: [Data] = []
    private static let backlogLimit = 256

    private(set) var lastActivity = ContinuousClock.now
    private(set) var isClosed = false
    private var heartbeat: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?

    init(id: String, child: StdioChild, profile: BridgeProfile, heartbeatInterval: Duration, onExit: @escaping @Sendable (String) async -> Void) {
        self.id = id
        self.childPID = child.pid
        self.profileID = profile.id
        self.profileName = profile.name
        self.child = child
        self.heartbeatInterval = heartbeatInterval
        self.onExit = onExit
    }

    /// Starts reading the child's output and sending heartbeats.
    func start() {
        pumpTask = Task { await pump() }
        heartbeat = Task { [weak self, heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeatInterval)
                await self?.beat()
            }
        }
    }

    var hasOpenStreams: Bool { !pending.isEmpty || serverStream != nil }
    var pendingRequestCount: Int { pending.count }

    enum OpenResult {
        case stream(AsyncStream<Data>)
        case duplicateID
        case closed
    }

    /// Sends a request to the child and returns the stream that carries what the child writes
    /// for it, ending with the response.
    func open(request line: Data, id requestID: JSONRPCID, progressToken: JSONRPCID?) -> OpenResult {
        guard !isClosed else { return .closed }
        guard pending[requestID] == nil else { return .duplicateID }
        lastActivity = .now
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let entry = Stream(continuation: continuation)
        pending[requestID] = entry
        if let progressToken { progressTokens[progressToken] = requestID }
        continuation.onTermination = { [weak self, token = entry.token] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.requestStreamDropped(requestID, token: token) }
        }
        child.send(line)
        return .stream(stream)
    }

    /// Sends a notification, or a response to a request the child made. Returns `false` when the
    /// session is closed.
    func forward(_ line: Data, cancelling cancelled: JSONRPCID?) -> Bool {
        guard !isClosed else { return false }
        lastActivity = .now
        child.send(line)
        // The child won't answer a cancelled request, so its stream would never end.
        if let cancelled { finishRequest(cancelled) }
        return true
    }

    /// Opens the stream for server-initiated messages. A newer GET stream replaces an older one.
    func openServerStream() -> AsyncStream<Data>? {
        guard !isClosed else { return nil }
        lastActivity = .now
        serverStream?.continuation.finish()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let entry = Stream(continuation: continuation)
        serverStream = entry
        continuation.onTermination = { [weak self, token = entry.token] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.serverStreamDropped(token: token) }
        }
        for line in backlog { continuation.yield(SSE.event(line)) }
        backlog.removeAll()
        return stream
    }

    /// Ends every stream and stops the child. Used for DELETE, idle timeout, token reset and quit.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        heartbeat?.cancel()
        for entry in pending.values { entry.continuation.finish() }
        pending.removeAll()
        progressTokens.removeAll()
        serverStream?.continuation.finish()
        serverStream = nil
        child.terminate()
        pumpTask?.cancel()
    }

    func waitForTermination() async { await child.waitForTermination() }

    // MARK: Child output

    private func pump() async {
        for await line in child.lines { receive(line) }
        let status = await child.waitForExit()
        childExited(status: status)
        await onExit(id)
    }

    private func receive(_ line: Data) {
        lastActivity = .now
        guard let message = JSONRPCMessage(line) else {
            log.error("session \(self.id, privacy: .public): dropped a line that isn't JSON-RPC")
            return
        }
        switch message.kind {
        case .response(let requestID?) where pending[requestID] != nil:
            pending[requestID]?.continuation.yield(SSE.event(line))
            finishRequest(requestID)
        case .notification where message.method == "notifications/progress":
            if let token = message.progressToken, let requestID = progressTokens[token], let entry = pending[requestID] {
                entry.continuation.yield(SSE.event(line))
            } else {
                sendServerMessage(line)
            }
        case .response(let requestID?):
            log.info("session \(self.id, privacy: .public): dropped the response to \(String(describing: requestID), privacy: .public); its client stream is gone")
        default:
            sendServerMessage(line)
        }
    }

    /// Sends a message that isn't tied to one request: on the GET stream, or, while the client
    /// has none open, on a POST stream (MCP allows both), or else later, when a GET stream opens.
    private func sendServerMessage(_ line: Data) {
        if let serverStream {
            serverStream.continuation.yield(SSE.event(line))
        } else if let entry = pending.values.first {
            entry.continuation.yield(SSE.event(line))
        } else {
            backlog.append(line)
            if backlog.count > Self.backlogLimit { backlog.removeFirst() }
        }
    }

    private func finishRequest(_ requestID: JSONRPCID) {
        pending.removeValue(forKey: requestID)?.continuation.finish()
        progressTokens = progressTokens.filter { $0.value != requestID }
    }

    private func childExited(status: Int32) {
        guard !isClosed else { return }
        var reason = "\(profileName) MCP server exited with status \(status)"
        if let detail = child.lastStderrLine { reason += ": \(detail)" }
        log.error("session \(self.id, privacy: .public): \(reason, privacy: .public)")
        for (requestID, entry) in pending {
            let error = JSONRPCMessage.errorLine(id: requestID, code: BridgeErrorCode.xcodeUnavailable, message: reason)
            entry.continuation.yield(SSE.event(error))
        }
        close()
    }

    private func requestStreamDropped(_ requestID: JSONRPCID, token: UUID) {
        guard pending[requestID]?.token == token else { return }
        // A closed connection isn't a cancellation (MCP says so), so the child keeps working;
        // its response is dropped when it arrives.
        pending.removeValue(forKey: requestID)
        progressTokens = progressTokens.filter { $0.value != requestID }
        lastActivity = .now
    }

    private func serverStreamDropped(token: UUID) {
        guard serverStream?.token == token else { return }
        serverStream = nil
        lastActivity = .now
    }

    private func beat() {
        for entry in pending.values { entry.continuation.yield(SSE.heartbeat) }
        serverStream?.continuation.yield(SSE.heartbeat)
    }
}

// MARK: - Sessions

/// The live sessions, by `Mcp-Session-Id`.
actor SessionStore {
    private var sessions: [String: MCPSession] = [:]
    private var terminating: [String: MCPSession] = [:]
    private var isStopping = false
    private let configuration: BridgeConfiguration
    private let onCountChange: @Sendable (Int) -> Void

    init(configuration: BridgeConfiguration, onCountChange: @escaping @Sendable (Int) -> Void) {
        self.configuration = configuration
        self.onCountChange = onCountChange
    }

    enum CreateError: Error {
        case tooManySessions
        case launchFailed(String)
    }

    /// Starts a child process for a new session. At the session limit it stops the least recently
    /// used session that has no open streams, or fails when every session is busy.
    func create(profile: BridgeProfile) async throws(CreateError) -> MCPSession {
        guard !isStopping else { throw .tooManySessions }
        if sessions.count >= configuration.maxSessions {
            var candidate: (session: MCPSession, lastActivity: ContinuousClock.Instant)?
            for session in sessions.values where await !session.hasOpenStreams {
                let lastActivity = await session.lastActivity
                if candidate == nil || lastActivity < candidate!.lastActivity { candidate = (session, lastActivity) }
            }
            guard let candidate else { throw .tooManySessions }
            await remove(candidate.session.id)?.close()
        }
        // BridgeConfiguration.childEnvironment historically replaces Xcode's entire environment.
        // Preserve that contract; additional profiles use documented overrides of the inherited one.
        let environment = profile.id == "xcode" ? profile.environment
            : profile.environment.map { ProcessInfo.processInfo.environment.merging($0) { _, value in value } }
        guard !isStopping else { throw .tooManySessions }
        let child: StdioChild
        do {
            child = try StdioChild(
                executable: URL(filePath: profile.executable),
                arguments: profile.arguments,
                environment: environment
            )
        } catch {
            throw .launchFailed(error.localizedDescription)
        }
        let session = MCPSession(id: UUID().uuidString, child: child, profile: profile, heartbeatInterval: configuration.heartbeatInterval) { [weak self] id in
            await self?.childExited(id)
        }
        sessions[session.id] = session
        await session.start()
        log.info("session \(session.id, privacy: .public): started child \(child.pid)")
        onCountChange(sessions.count)
        return session
    }

    func session(_ id: String, profileID: String = "xcode") -> MCPSession? {
        guard let session = sessions[id], session.profileID == profileID else { return nil }
        return session
    }

    @discardableResult
    func remove(_ id: String, profileID: String? = nil) -> MCPSession? {
        guard let session = sessions[id], profileID == nil || session.profileID == profileID else { return nil }
        sessions.removeValue(forKey: id)
        terminating[id] = session
        log.info("session \(id, privacy: .public): ended")
        onCountChange(sessions.count)
        return session
    }

    private func childExited(_ id: String) {
        if sessions.removeValue(forKey: id) != nil { onCountChange(sessions.count) }
        terminating.removeValue(forKey: id)
    }

    func closeAll() async {
        let all = Array(sessions.values) + Array(terminating.values)
        sessions.removeAll()
        for session in all { terminating[session.id] = session }
        for session in all { await session.close() }
        if !all.isEmpty { onCountChange(sessions.count) }
        await withTaskGroup { group in
            for session in all { group.addTask { await session.waitForTermination() } }
        }
        for session in all { terminating.removeValue(forKey: session.id) }
    }

    func shutdown() async {
        isStopping = true
        await closeAll()
    }

    /// Stops sessions that have no open stream and no activity for `idleTimeout`.
    func closeIdle(idleTimeout: Duration) async {
        let deadline = ContinuousClock.now - idleTimeout
        for session in sessions.values {
            if await !session.hasOpenStreams, await session.lastActivity < deadline {
                await remove(session.id)?.close()
            }
        }
    }

    var count: Int { sessions.count }
}
