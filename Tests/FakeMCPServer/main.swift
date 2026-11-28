// A stdio MCP server the tests launch in place of `xcrun mcpbridge`. It reads one JSON-RPC
// message per line and answers on stdout, like mcpbridge. Its tools exercise the bridge:
//
// - echo: returns its arguments.
// - slow: three `notifications/progress` for the call's progress token, 100 ms apart, then the
//   result after another 300 ms.
// - notify: `notifications/tools/list_changed`, then the result.
// - ask: a `roots/list` request to the client; the result carries the client's answer.
// - big: a 300 kB result with a raw U+2028 inside a string.
// - hang: never answers.
// - crash: writes to stderr and exits with status 3.
//
// initialize reports the process id as serverInfo.version, so tests can check the process stops.

import Foundation

func write(_ object: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func result(_ id: Any, _ result: [String: Any]) {
    write(["jsonrpc": "2.0", "id": id, "result": result])
}

func text(_ string: String) -> [String: Any] {
    ["content": [["type": "text", "text": string]]]
}

func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

/// The id of the tools/call that is waiting for the client's answer to `roots/list`.
var waitingAsk: Any?

@MainActor func handle(_ message: [String: Any]) {
    let id = message["id"]
    let method = message["method"] as? String
    let params = message["params"] as? [String: Any] ?? [:]

    guard let method else {
        // A response from the client.
        if message["id"] as? String == "srv-1", let callID = waitingAsk {
            waitingAsk = nil
            result(callID, text(json(message["result"] ?? NSNull())))
        }
        return
    }
    guard let id else { return }  // Notifications need no answer.

    switch method {
    case "initialize":
        result(id, [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": ["name": "fake-mcp-server", "version": "\(getpid())"],
        ])
    case "ping":
        result(id, [:])
    case "tools/list":
        let names = ["echo", "slow", "notify", "ask", "big", "hang", "crash", "identity"]
        result(id, ["tools": names.map { ["name": $0, "inputSchema": ["type": "object"]] }])
    case "tools/call":
        let arguments = params["arguments"] ?? [String: Any]()
        let token = (params["_meta"] as? [String: Any])?["progressToken"]
        switch params["name"] as? String {
        case "echo":
            result(id, text(json(arguments)))
        case "identity":
            result(id, text(json(["arguments": Array(ProcessInfo.processInfo.arguments.dropFirst()),
                                  "marker": ProcessInfo.processInfo.environment["PROFILE_MARKER"] ?? "",
                                  "path": ProcessInfo.processInfo.environment["PATH"] ?? ""])))
        case "slow":
            for step in 1...3 {
                if let token {
                    write(["jsonrpc": "2.0", "method": "notifications/progress",
                           "params": ["progressToken": token, "progress": step, "total": 3, "message": "Step \(step)"]])
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.3)
            result(id, text("done"))
        case "notify":
            write(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
            result(id, text("notified"))
        case "ask":
            waitingAsk = id
            write(["jsonrpc": "2.0", "id": "srv-1", "method": "roots/list"])
        case "big":
            result(id, text(String(repeating: "x", count: 150_000) + "\u{2028}" + String(repeating: "y", count: 150_000)))
        case "hang":
            break
        case "crash":
            FileHandle.standardError.write(Data("fake crash\n".utf8))
            exit(3)
        default:
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool"]])
        }
    default:
        write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
    }
}

let ignoresEOF = ProcessInfo.processInfo.arguments.contains("--ignore-eof")
if ignoresEOF { signal(SIGTERM, SIG_IGN) }
FileHandle.standardError.write(Data("fake-mcp-server: started\n".utf8))
var buffer = Data()
while case let chunk = FileHandle.standardInput.availableData, !chunk.isEmpty {
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            handle(message)
        }
    }
}
if ignoresEOF { while true { Thread.sleep(forTimeInterval: 0.1) } }
exit(0)
