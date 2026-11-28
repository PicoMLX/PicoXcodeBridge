import Foundation
import Testing
@testable import XcodeBridgeCore

// MARK: - Line framing and JSON-RPC

@Suite struct FramingTests {
    @Test func splitsLinesAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data(#"{"a":"#.utf8)).isEmpty)
        let lines = splitter.append(Data("1}\r\n\n  \n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map(string) == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(splitter.append(Data(":3}\n".utf8)).map(string) == [#"{"c":3}"#])
    }

    @Test func keepsUnicodeLineSeparatorsInsideALine() {
        var splitter = LineSplitter()
        let line = "{\"t\":\"a\u{2028}b\u{2029}c\u{85}d\"}"
        #expect(splitter.append(Data((line + "\n").utf8)).map(string) == [line])
    }

    @Test func classifiesMessages() throws {
        let call = try #require(message(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x","_meta":{"progressToken":"p1"}}}"#))
        #expect(call.kind == .request(.int(7)))
        #expect(call.method == "tools/call")
        #expect(call.progressToken == .string("p1"))

        #expect(message(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)?.kind == .request(.string("abc")))
        #expect(message(#"{"jsonrpc":"2.0","id":1,"method":"x","params":[1,2]}"#)?.kind == .request(.int(1)))
        #expect(message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)?.kind == .notification)

        let progress = try #require(message(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":5,"progress":1}}"#))
        #expect(progress.progressToken == .int(5))

        let cancelled = try #require(message(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#))
        #expect(cancelled.cancelledRequest == .int(9))

        #expect(message(#"{"jsonrpc":"2.0","id":3,"result":{}}"#)?.kind == .response(.int(3)))
        #expect(message(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"x"}}"#)?.kind == .response(nil))
    }

    @Test func rejectsWhatIsNotAMessage() {
        #expect(message("[1,2]") == nil)
        #expect(message("not json") == nil)
        #expect(message(#"{"jsonrpc":"2.0","id":true,"method":"x"}"#) == nil)
        #expect(message(#"{"jsonrpc":"2.0","id":1.5,"method":"x"}"#) == nil)
        #expect(message(#"{"jsonrpc":"2.0","id":1}"#) == nil)
    }

    private func message(_ json: String) -> JSONRPCMessage? { JSONRPCMessage(Data(json.utf8)) }
}

// MARK: - Host, Origin and token

@Suite struct RequestGuardTests {
    let port = 7428
    let token = "s3cret"

    func check(host: String? = "127.0.0.1:7428", origin: String? = nil, authorization: String? = "Bearer s3cret") -> RequestGuard.Rejection? {
        RequestGuard.check(host: host, origin: origin, authorization: authorization, port: port, token: token)
    }

    @Test func acceptsLoopbackHostsOnTheBridgePort() {
        #expect(check() == nil)
        #expect(check(host: "localhost:7428") == nil)
        #expect(check(host: "LocalHost:7428") == nil)
        #expect(check(authorization: "bearer s3cret") == nil)
    }

    @Test func refusesAnyOrigin() {
        #expect(check(origin: "http://localhost:7428") == .originNotAllowed)
        #expect(check(origin: "null") == .originNotAllowed)
        // The Origin check runs before the token check.
        #expect(check(origin: "https://evil.example", authorization: nil) == .originNotAllowed)
    }

    @Test func refusesOtherHosts() {
        for host in ["evil.example:7428", "127.0.0.1:7429", "127.0.0.1", "localhost", "[::1]:7428",
                     "localhost.evil.example:7428", "127.0.0.1:7428.evil", "0.0.0.0:7428"] {
            #expect(check(host: host) == .hostNotAllowed, "\(host)")
        }
        #expect(check(host: nil) == .hostNotAllowed)
        // The Host check runs before the token check.
        #expect(check(host: "evil.example:7428", authorization: nil) == .hostNotAllowed)
    }

    @Test func refusesMissingOrWrongTokens() {
        for authorization in [nil, "", "Bearer", "Bearer ", "Bearer wrong", "Bearer s3cre", "Bearer s3cretx", "Basic s3cret", "s3cret"] {
            #expect(check(authorization: authorization) == .unauthorized, "\(String(describing: authorization))")
        }
        #expect(RequestGuard.check(host: "127.0.0.1:7428", origin: nil, authorization: "Bearer ", port: port, token: "") == .unauthorized)
    }
}

// MARK: - Discovery

@Suite struct DiscoveryTests {
    @Test func keysAreThePicoContract() {
        #expect(Discovery.appGroup == "group.com.starlingprotocol.pico")
        #expect(Discovery.Key.port == "xcodeBridge.port")
        #expect(Discovery.Key.token == "xcodeBridge.token")
        #expect(Discovery.Key.status == "xcodeBridge.status")
    }

    @Test func tokenPersistsUntilReset() throws {
        let suite = "XcodeBridgeTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let discovery = Discovery(suiteName: suite)

        let token = discovery.token()
        #expect(token.count == 43)
        #expect(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(Discovery(suiteName: suite).token() == token)

        let reset = discovery.resetToken()
        #expect(reset != token)
        #expect(discovery.token() == reset)

        discovery.publish(port: 7430)
        discovery.publish(status: .running)
        discovery.publish(xcode: .reachable)
        let defaults = try #require(UserDefaults(suiteName: suite))
        #expect(defaults.integer(forKey: "xcodeBridge.port") == 7430)
        #expect(defaults.string(forKey: "xcodeBridge.token") == reset)
        #expect(defaults.string(forKey: "xcodeBridge.status") == "running")
        #expect(defaults.string(forKey: "xcodeBridge.xcode") == "reachable")
        #expect(defaults.object(forKey: "xcodeBridge.updatedAt") is Date)
        #expect(Discovery(suiteName: suite).lastPort == 7430)
    }

    @Test func triesTheLastPortFirst() {
        #expect(BridgeConfiguration(preferredPort: 7500).ports == [7500] + Array(7428...7437) + [0])
        #expect(BridgeConfiguration(preferredPort: 7430).ports == [7430, 7428, 7429] + Array(7431...7437) + [0])
        #expect(BridgeConfiguration().ports == Array(7428...7437) + [0])
    }
}

// MARK: - The bridge over HTTP, with the fake MCP server as the child

@Suite(.timeLimit(.minutes(1)))
struct BridgeServerTests {
    @Test func initializeStartsASessionAndToolsListPassesThrough() async throws {
        try await withBridge { bridge in
            var client = Client(bridge)
            let (response, events) = try await client.post(initializeBody)
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
            client.sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
            #expect(client.sessionID?.isEmpty == false)

            let initialize = try await events.allMessages()
            #expect(initialize.count == 1)
            #expect(initialize.first?["id"] as? Int == 1)
            #expect(serverInfo(initialize.first)?["name"] as? String == "fake-mcp-server")

            let (accepted, _) = try await client.data(initializedNotification)
            #expect(accepted.statusCode == 202)

            let (_, list) = try await client.post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            let tools = try await list.allMessages().first.flatMap { result($0)?["tools"] as? [[String: Any]] }
            #expect(tools?.compactMap { $0["name"] as? String }.contains("echo") == true)
            #expect(await bridge.server.sessionCount == 1)
        }
    }

    @Test func refusesMissingAndWrongTokens() async throws {
        try await withBridge { bridge in
            for token in [nil, "wrong"] {
                var client = Client(bridge)
                client.token = token
                let (response, _) = try await client.data(initializeBody)
                #expect(response.statusCode == 401)
                #expect(response.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")
            }
            #expect(await bridge.server.sessionCount == 0)
        }
    }

    @Test func refusesOriginsAndForeignHosts() async throws {
        try await withBridge { bridge in
            let port = bridge.port
            func request(host: String, token: String = bridge.token, origin: String? = nil) -> String {
                let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
                var head = "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(token)\r\n"
                if let origin { head += "Origin: \(origin)\r\n" }
                head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                return head + body
            }
            let cases: [(request: String, status: Int)] = [
                (request(host: "evil.example:\(port)"), 421),
                (request(host: "127.0.0.1:\(port + 1)"), 421),
                (request(host: "localhost:\(port)", origin: "http://localhost:\(port)"), 403),
                (request(host: "localhost:\(port)", token: "wrong"), 401),
                // Past the checks, a ping without a session is a bad request.
                (request(host: "localhost:\(port)"), 400),
            ]
            for (request, expected) in cases {
                let status = try await rawStatus(port: port, request)
                #expect(status == expected, "\(request)")
            }
            #expect(await bridge.server.sessionCount == 0)
        }
    }

    @Test func enforcesSessionsAndMethods() async throws {
        try await withBridge { bridge in
            var client = Client(bridge)
            let ping = #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#
            #expect(try await client.data(ping).0.statusCode == 400)
            #expect(try await client.data(nil, method: "GET").0.statusCode == 400)

            client.sessionID = "no-such-session"
            let (notFound, body) = try await client.data(ping)
            #expect(notFound.statusCode == 404)
            #expect((json(body)?["error"] as? [String: Any])?["code"] as? Int == -32001)
            #expect(try await client.data(nil, method: "DELETE").0.statusCode == 404)
            #expect(try await client.data(nil, method: "PUT").0.statusCode == 405)
            #expect(try await client.data(ping, path: "/other").0.statusCode == 404)

            #expect(try await client.data("[\(ping)]").0.statusCode == 400)
            #expect(try await client.data("not json").0.statusCode == 400)
        }
    }

    @Test func streamsProgressBeforeTheResponse() async throws {
        try await withBridge { bridge in
            let (client, _) = try await initializedClient(bridge)
            let (response, events) = try await client.post(callBody(id: 5, tool: "slow", progressToken: "build-1"))
            #expect(response.statusCode == 200)

            var progress: [[String: Any]] = []
            var firstProgressAt: ContinuousClock.Instant?
            var final: [String: Any]?
            var finalAt: ContinuousClock.Instant?
            while let message = try await events.nextMessage() {
                if message["method"] as? String == "notifications/progress" {
                    progress.append(message)
                    firstProgressAt = firstProgressAt ?? .now
                } else {
                    final = message
                    finalAt = .now
                }
            }
            #expect(progress.map { ($0["params"] as? [String: Any])?["progress"] as? Int } == [1, 2, 3])
            #expect(progress.allSatisfy { ($0["params"] as? [String: Any])?["progressToken"] as? String == "build-1" })
            #expect(final?["id"] as? Int == 5)
            // The fake waits 600 ms between its first progress and its result. Seeing that gap
            // proves the bridge forwards lines as they come instead of collecting them.
            let gap = try #require(finalAt) - (try #require(firstProgressAt))
            #expect(gap >= .milliseconds(400))
        }
    }

    @Test func sendsServerMessagesOnTheGETStream() async throws {
        try await withBridge { bridge in
            let (client, _) = try await initializedClient(bridge)
            let (get, serverEvents) = try await client.stream(nil, method: "GET")
            #expect(get.statusCode == 200)

            let (_, notify) = try await client.post(callBody(id: 6, tool: "notify"))
            let notifyMessages = try await notify.allMessages()
            #expect(notifyMessages.count == 1)
            #expect(notifyMessages.first?["id"] as? Int == 6)
            #expect(try await serverEvents.nextMessage()?["method"] as? String == "notifications/tools/list_changed")

            // A request from the server reaches the client on the GET stream, and the client's
            // POSTed answer reaches the server.
            let (_, ask) = try await client.post(callBody(id: 7, tool: "ask"))
            let roots = try await serverEvents.nextMessage()
            #expect(roots?["method"] as? String == "roots/list")
            #expect(roots?["id"] as? String == "srv-1")
            let (accepted, _) = try await client.data(#"{"jsonrpc":"2.0","id":"srv-1","result":{"roots":[]}}"#)
            #expect(accepted.statusCode == 202)
            let answer = try await ask.allMessages()
            #expect(answer.count == 1)
            #expect(text(answer.first) == #"{"roots":[]}"#)
        }
    }

    @Test func routesConcurrentRequestsByIDAndEndsCancelledOnes() async throws {
        try await withBridge { bridge in
            let (client, _) = try await initializedClient(bridge)
            let (_, hang) = try await client.post(callBody(id: 10, tool: "hang"))
            let (_, echo) = try await client.post(callBody(id: 11, tool: "echo", arguments: #"{"x":1}"#))
            let echoMessages = try await echo.allMessages()
            #expect(echoMessages.first?["id"] as? Int == 11)
            #expect(text(echoMessages.first) == #"{"x":1}"#)
            #expect(await pendingCount(bridge, client) == 1)

            #expect(try await client.data(callBody(id: 10, tool: "echo")).0.statusCode == 409)

            let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":10,"reason":"user"}}"#
            #expect(try await client.data(cancel).0.statusCode == 202)
            #expect(try await hang.allMessages().isEmpty)
            #expect(await pendingCount(bridge, client) == 0)
        }
    }

    @Test func deleteStopsTheChild() async throws {
        try await withBridge { bridge in
            let (client, pid) = try await initializedClient(bridge)
            #expect(pid > 0)
            #expect(kill(pid, 0) == 0)
            #expect(try await client.data(nil, method: "DELETE").0.statusCode == 200)
            #expect(await eventually { kill(pid, 0) != 0 })
            #expect(await bridge.server.sessionCount == 0)
            #expect(try await client.data(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#).0.statusCode == 404)
        }
    }

    @Test func idleSessionsTimeOutButConnectedOnesDoNot() async throws {
        try await withBridge(configure: { $0.idleTimeout = .milliseconds(300) }) { bridge in
            let (idle, idlePID) = try await initializedClient(bridge)
            let (connected, _) = try await initializedClient(bridge)
            let (_, serverEvents) = try await connected.stream(nil, method: "GET")

            #expect(await eventually { kill(idlePID, 0) != 0 })
            #expect(try await idle.data(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#).0.statusCode == 404)
            try await Task.sleep(for: .milliseconds(500))
            #expect(await bridge.server.sessionCount == 1)
            #expect(try await connected.post(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#).0.statusCode == 200)
            serverEvents.cancel()
        }
    }

    @Test func aCrashedChildFailsItsPendingRequests() async throws {
        try await withBridge { bridge in
            let (client, _) = try await initializedClient(bridge)
            let (_, crash) = try await client.post(callBody(id: 12, tool: "crash"))
            let messages = try await crash.allMessages()
            let error = try #require(messages.first?["error"] as? [String: Any])
            #expect(messages.first?["id"] as? Int == 12)
            #expect(error["code"] as? Int == -32002)
            #expect((error["message"] as? String)?.contains("status 3: fake crash") == true)
            #expect(await eventually { await bridge.server.sessionCount == 0 })
        }
    }

    @Test func heartbeatsFlowAndADroppedClientIsForgotten() async throws {
        try await withBridge(configure: { $0.heartbeatInterval = .milliseconds(100) }) { bridge in
            let (client, _) = try await initializedClient(bridge)
            let (_, hang) = try await client.post(callBody(id: 20, tool: "hang"))
            #expect(try await hang.next() == .comment("open"))
            #expect(try await hang.next() == .comment("keepalive"))
            #expect(await pendingCount(bridge, client) == 1)
            hang.cancel()
            // The next heartbeat fails to write, which ends the stream.
            #expect(await eventually { await pendingCount(bridge, client) == 0 })
            #expect(await bridge.server.sessionCount == 1)
        }
    }

    @Test func resettingTheTokenEndsSessions() async throws {
        try await withBridge { bridge in
            var (client, pid) = try await initializedClient(bridge)
            let (_, serverEvents) = try await client.stream(nil, method: "GET")
            await bridge.server.resetToken(to: "new-token")
            #expect(try await serverEvents.allMessages().isEmpty)
            #expect(await bridge.server.sessionCount == 0)
            #expect(await eventually { kill(pid, 0) != 0 })

            let ping = #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#
            #expect(try await client.data(ping).0.statusCode == 401)
            client.token = "new-token"
            #expect(try await client.data(ping).0.statusCode == 404)
        }
    }

    @Test func largeMessagesPassIntact() async throws {
        try await withBridge { bridge in
            let (client, _) = try await initializedClient(bridge)
            let (_, big) = try await client.post(callBody(id: 30, tool: "big"))
            let content = try #require(text(try await big.allMessages().first))
            #expect(content.count == 300_001)
            #expect(content.contains("\u{2028}"))
        }
    }

    @Test func fallsBackWhenThePortIsTaken() async throws {
        try await withBridge { first in
            try await withBridge(configure: { $0.ports = [first.port, 0] }) { second in
                #expect(second.port != first.port)
            }
            await #expect(throws: (any Error).self) {
                try await withBridge(configure: { $0.ports = [first.port] }) { _ in }
            }
        }
    }
}

// MARK: - Helpers

enum Fixtures {
    /// The FakeMCPServer executable SwiftPM built next to the test bundle.
    static let fakeServer: URL = {
        if let path = ProcessInfo.processInfo.environment["FAKE_MCP_SERVER"] { return URL(filePath: path) }
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appending(path: "FakeMCPServer")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return packageRoot.appending(path: ".build/debug/FakeMCPServer")
    }()
}

final class TestBridge: Sendable {
    let server: BridgeServer
    let port: Int
    let token: String
    private let task: Task<Void, any Error>

    init(configuration: BridgeConfiguration) async throws {
        let token = Discovery.makeToken()
        let server = BridgeServer(configuration: configuration, token: token)
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            try await server.run { continuation.yield($0) }
        }
        var iterator = ports.makeAsyncIterator()
        guard let port = await iterator.next() else {
            try await task.value
            throw CancellationError()
        }
        self.server = server
        self.port = port
        self.token = token
        self.task = task
    }

    func stop() async {
        task.cancel()
        _ = await task.result
    }
}

/// Runs `body` against a bridge whose sessions launch the fake MCP server.
func withBridge(
    configure: (inout BridgeConfiguration) -> Void = { _ in },
    _ body: (TestBridge) async throws -> Void
) async throws {
    var configuration = BridgeConfiguration(ports: [0])
    configuration.childExecutable = Fixtures.fakeServer
    configuration.childArguments = []
    configure(&configuration)
    let bridge = try await TestBridge(configuration: configuration)
    do {
        try await body(bridge)
    } catch {
        await bridge.stop()
        throw error
    }
    await bridge.stop()
}

struct Client {
    let port: Int
    var token: String?
    var sessionID: String?

    init(_ bridge: TestBridge) {
        port = bridge.port
        token = bridge.token
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    func request(_ body: String?, method: String, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        return request
    }

    func stream(_ body: String?, method: String = "POST", path: String = "/mcp") async throws -> (HTTPURLResponse, EventReader) {
        let (bytes, response) = try await Self.session.bytes(for: request(body, method: method, path: path))
        return (try #require(response as? HTTPURLResponse), EventReader(bytes))
    }

    func post(_ body: String) async throws -> (HTTPURLResponse, EventReader) {
        try await stream(body)
    }

    func data(_ body: String?, method: String = "POST", path: String = "/mcp") async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await Self.session.data(for: request(body, method: method, path: path))
        return (try #require(response as? HTTPURLResponse), data)
    }
}

/// Reads an SSE response one event at a time, splitting on `\n` only, as the bridge frames it.
final class EventReader {
    enum Event: Equatable {
        case message(String)
        case comment(String)
    }

    private let bytes: URLSession.AsyncBytes
    private var iterator: URLSession.AsyncBytes.AsyncIterator

    init(_ bytes: URLSession.AsyncBytes) {
        self.bytes = bytes
        iterator = bytes.makeAsyncIterator()
    }

    func next() async throws -> Event? {
        var line: [UInt8] = []
        while let byte = try await iterator.next() {
            guard byte == 0x0A else { line.append(byte); continue }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll()
            if text.hasPrefix("data: ") { return .message(String(text.dropFirst(6))) }
            if text.hasPrefix(": ") { return .comment(String(text.dropFirst(2))) }
        }
        return nil
    }

    /// The next JSON-RPC message, skipping heartbeats; `nil` when the stream ends.
    func nextMessage() async throws -> [String: Any]? {
        while let event = try await next() {
            if case .message(let text) = event { return json(Data(text.utf8)) }
        }
        return nil
    }

    func allMessages() async throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        while let message = try await nextMessage() { messages.append(message) }
        return messages
    }

    func cancel() { bytes.task.cancel() }
}

let initializeBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"PicoXcodeBridgeTests","version":"1"}}}"#
let initializedNotification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

func callBody(id: Int, tool: String, arguments: String = "{}", progressToken: String? = nil) -> String {
    let meta = progressToken.map { #","_meta":{"progressToken":"\#($0)"}"# } ?? ""
    return #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)\#(meta)}}"#
}

/// Initializes a session and returns a client for it, with the child's process id.
func initializedClient(_ bridge: TestBridge, path: String = "/mcp") async throws -> (Client, Int32) {
    var client = Client(bridge)
    let (response, events) = try await client.stream(initializeBody, path: path)
    client.sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
    #expect(client.sessionID?.isEmpty == false)
    let pid = Int32(serverInfo(try await events.allMessages().first)?["version"] as? String ?? "") ?? 0
    #expect(try await client.data(initializedNotification, path: path).0.statusCode == 202)
    return (client, pid)
}

func pendingCount(_ bridge: TestBridge, _ client: Client) async -> Int {
    guard let id = client.sessionID, let session = await bridge.server.sessions.session(id) else { return -1 }
    return await session.pendingRequestCount
}

func json(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func result(_ message: [String: Any]?) -> [String: Any]? { message?["result"] as? [String: Any] }

func serverInfo(_ message: [String: Any]?) -> [String: Any]? { result(message)?["serverInfo"] as? [String: Any] }

/// The text of a tool result's first content item.
func text(_ message: [String: Any]?) -> String? {
    (result(message)?["content"] as? [[String: Any]])?.first?["text"] as? String
}

func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Sends a hand-written HTTP request, for the headers URLSession won't let us set (Host), and
/// returns the response's status code.
func rawStatus(port: Int, _ request: String) async throws -> Int {
    try await Task.detached {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let bytes = Array(request.utf8)
        guard bytes.withUnsafeBytes({ send(socket, $0.baseAddress, $0.count, 0) }) == bytes.count else { throw POSIXError(.EIO) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(socket, &buffer, buffer.count, 0)
        // "HTTP/1.1 421 Misdirected Request"
        let statusLine = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
        return statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? -1
    }.value
}


// MARK: - Locally configured MCP profiles

@Suite struct ProfileConfigurationTests {
    @Test func examplesAreOptInAndRoundTrip() throws {
        let document = try JSONDecoder().decode(BridgeProfileConfiguration.self, from: BridgeProfileConfiguration.exampleData())
        #expect(document.version == 1)
        #expect(document.profiles.map(\.id) == ["bear", "proxyman"])
        #expect(try document.validatedProfiles().isEmpty)
        var enabled = document
        enabled.profiles[0].isEnabled = true
        #expect(try enabled.validatedProfiles().map(\.id) == ["bear"])
    }

    @Test func refusesReservedIDsRoutesAndInvalidCommands() throws {
        for id in ["", "xcode", "../bear", "bear/other", "bear?x=1", "bear%2fother", "bear\n", String(repeating: "x", count: 65)] {
            let profile = BridgeProfile(id: id, name: "Test", executable: "/usr/bin/true")
            #expect(throws: BridgeProfileConfiguration.ValidationError.self) {
                try BridgeProfileConfiguration(profiles: [profile]).validatedProfiles()
            }
        }
        for executable in ["node", "~/node", "https://example.com/tool", "/bin/test\0"] {
            let profile = BridgeProfile(id: "test", name: "Test", executable: executable)
            #expect(throws: BridgeProfileConfiguration.ValidationError.self) {
                try BridgeProfileConfiguration(profiles: [profile]).validatedProfiles()
            }
        }
        let duplicate = BridgeProfile(id: "test", name: "Test", executable: "/usr/bin/true")
        #expect(throws: BridgeProfileConfiguration.ValidationError.self) {
            try BridgeProfileConfiguration(profiles: [duplicate, duplicate]).validatedProfiles()
        }
        #expect(throws: BridgeProfileConfiguration.ValidationError.self) {
            try BridgeProfileConfiguration(version: 2).validatedProfiles()
        }
    }

    @Test func discoveryPublishesOnlyEnabledProfilesAndTracksTokenAndStatus() throws {
        let suite = "MCPProfileTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let discovery = Discovery(suiteName: suite)
        discovery.publish(port: 7431)
        discovery.publish(status: .running)
        let enabled = BridgeProfile(id: "test", name: "Test", executable: "/private/secret", environment: ["SECRET": "private"])
        discovery.publish(profiles: [enabled] + BridgeProfile.examples)
        func manifest() throws -> Discovery.Manifest {
            try JSONDecoder().decode(Discovery.Manifest.self, from: #require(discovery.defaults.data(forKey: "mcpBridge.discovery")))
        }
        let first = try manifest()
        #expect(first.version == 1)
        #expect(first.port == 7431)
        #expect(first.token == discovery.token())
        #expect(first.status == .running)
        #expect(first.profiles.map(\.id) == ["xcode", "test"])
        #expect(first.profiles.map(\.path) == ["/mcp/xcode", "/mcp/test"])
        let raw = string(try #require(discovery.defaults.data(forKey: "mcpBridge.discovery")))
        #expect(!raw.contains("/private/secret"))
        #expect(!raw.contains("SECRET"))
        let nextToken = discovery.resetToken()
        #expect(try manifest().token == nextToken)
        #expect(nextToken != first.token)
        discovery.publish(port: 7432)
        #expect(try manifest().port == 7432)
        discovery.publish(status: .stopped)
        #expect(try manifest().status == .stopped)
        #expect(discovery.defaults.string(forKey: "xcodeBridge.status") == "stopped")
        #expect(discovery.defaults.string(forKey: "xcodeBridge.token") == nextToken)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ProfileRoutingTests {
    private var profiles: [BridgeProfile] {
        [
            BridgeProfile(id: "bear", name: "Bear", executable: Fixtures.fakeServer.path,
                          arguments: ["bear-argument"], environment: ["PROFILE_MARKER": "bear"]),
            BridgeProfile(id: "proxyman", name: "Proxyman", executable: Fixtures.fakeServer.path,
                          arguments: ["proxyman-argument"], environment: ["PROFILE_MARKER": "proxyman"]),
            BridgeProfile(id: "disabled", name: "Disabled", executable: Fixtures.fakeServer.path, isEnabled: false),
        ]
    }

    @Test func routesEachProfileAndKeepsLegacyXcodeEndpoint() async throws {
        try await withBridge(configure: { $0.profiles = profiles }) { bridge in
            for (path, argument, marker) in [("/mcp", "", ""), ("/mcp/xcode", "", ""),
                                             ("/mcp/bear", "bear-argument", "bear"),
                                             ("/mcp/proxyman", "proxyman-argument", "proxyman")] {
                let (client, pid) = try await initializedClient(bridge, path: path)
                #expect(pid > 0)
                let (_, events) = try await client.stream(callBody(id: 2, tool: "identity"), path: path)
                let identity = try #require(text(try await events.allMessages().first))
                let object = try #require(json(Data(identity.utf8)))
                #expect(object["marker"] as? String == marker)
                #expect(object["arguments"] as? [String] == (argument.isEmpty ? [] : [argument]))
                #expect(try await client.data(nil, method: "DELETE", path: path).0.statusCode == 200)
            }
        }
    }

    @Test func preservesXcodesReplacementEnvironmentWhileProfilesInheritOverrides() async throws {
        try await withBridge(configure: {
            $0.childEnvironment = ["PROFILE_MARKER": "isolated-xcode"]
            $0.profiles = profiles
        }) { bridge in
            for (path, expectedMarker, expectedPath) in [
                ("/mcp", "isolated-xcode", ""),
                ("/mcp/xcode", "isolated-xcode", ""),
                ("/mcp/bear", "bear", ProcessInfo.processInfo.environment["PATH"] ?? ""),
            ] {
                let (client, _) = try await initializedClient(bridge, path: path)
                let (_, events) = try await client.stream(callBody(id: 2, tool: "identity"), path: path)
                let identity = try #require(text(try await events.allMessages().first))
                let object = try #require(json(Data(identity.utf8)))
                #expect(object["marker"] as? String == expectedMarker)
                #expect(object["path"] as? String == expectedPath)
                #expect(try await client.data(nil, method: "DELETE", path: path).0.statusCode == 200)
            }
        }
    }

    @Test func rejectsSessionIDsOnOtherProfilesForEveryMethod() async throws {
        try await withBridge(configure: { $0.profiles = profiles }) { bridge in
            let (client, pid) = try await initializedClient(bridge, path: "/mcp/bear")
            let ping = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
            for path in ["/mcp", "/mcp/xcode", "/mcp/proxyman"] {
                #expect(try await client.data(ping, path: path).0.statusCode == 404)
                #expect(try await client.data(initializedNotification, path: path).0.statusCode == 404)
                #expect(try await client.data(nil, method: "GET", path: path).0.statusCode == 404)
                #expect(try await client.data(nil, method: "DELETE", path: path).0.statusCode == 404)
            }
            #expect(kill(pid, 0) == 0)
            #expect(await bridge.server.sessionCount == 1)
            #expect(try await client.stream(ping, path: "/mcp/bear").0.statusCode == 200)
            #expect(try await client.data(nil, method: "DELETE", path: "/mcp/bear").0.statusCode == 200)
            #expect(await eventually { kill(pid, 0) != 0 })
        }
    }

    @Test func unknownDisabledAndUnauthenticatedRoutesNeverLaunchChildren() async throws {
        try await withBridge(configure: { $0.profiles = profiles }) { bridge in
            var client = Client(bridge)
            for path in ["/mcp/missing", "/mcp/disabled", "/mcp/bear/other", "/mcp/bear/", "/mcp//bear"] {
                #expect(try await client.data(initializeBody, path: path).0.statusCode == 404)
            }
            client.token = nil
            #expect(try await client.data(initializeBody, path: "/mcp/bear").0.statusCode == 401)
            client.token = bridge.token
            var request = client.request(initializeBody, method: "POST", path: "/mcp/bear")
            request.setValue("http://localhost", forHTTPHeaderField: "Origin")
            let (_, response) = try await Client.session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
            #expect(await bridge.server.sessionCount == 0)
        }
    }

    @Test func shutdownWaitsForChildrenThatIgnoreEOFAndSIGTERM() async throws {
        var configuration = BridgeConfiguration(ports: [0])
        configuration.childExecutable = Fixtures.fakeServer
        configuration.childArguments = []
        configuration.profiles = [BridgeProfile(id: "stubborn", name: "Stubborn", executable: Fixtures.fakeServer.path,
                                                 arguments: ["--ignore-eof"])]
        let bridge = try await TestBridge(configuration: configuration)
        do {
            let (client, pid) = try await initializedClient(bridge, path: "/mcp/stubborn")
            // DELETE removes the session from the active map before the child has terminated.
            // Application shutdown must drain these already-terminating children too.
            #expect(try await client.data(nil, method: "DELETE", path: "/mcp/stubborn").0.statusCode == 200)
            #expect(kill(pid, 0) == 0)
            await bridge.stop()
            #expect(kill(pid, 0) != 0)
        } catch {
            await bridge.stop()
            throw error
        }
    }

    @Test func resetAndShutdownEndChildrenFromAllProfiles() async throws {
        let configurationProfiles = profiles
        var configuration = BridgeConfiguration(ports: [0])
        configuration.childExecutable = Fixtures.fakeServer
        configuration.childArguments = []
        configuration.profiles = configurationProfiles
        let bridge = try await TestBridge(configuration: configuration)
        do {
            let (_, xcodePID) = try await initializedClient(bridge)
            let (_, bearPID) = try await initializedClient(bridge, path: "/mcp/bear")
            await bridge.server.resetToken(to: bridge.token)
            #expect(await bridge.server.sessionCount == 0)
            #expect(await eventually { kill(xcodePID, 0) != 0 && kill(bearPID, 0) != 0 })
            let (_, nextPID) = try await initializedClient(bridge, path: "/mcp/proxyman")
            await bridge.stop()
            #expect(await eventually { kill(nextPID, 0) != 0 })
        } catch {
            await bridge.stop()
            throw error
        }
    }
}
