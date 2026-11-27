import Foundation
import Testing
@testable import XcodeBridgeCore

/// Runs the bridge against the real `xcrun mcpbridge`. It needs Xcode 26.3 or later running, so
/// it's skipped unless PICO_XCODE_BRIDGE_INTEGRATION=1. It only initializes and lists tools:
/// neither opens a project nor asks Xcode for approval.
@Suite(.timeLimit(.minutes(1)))
struct XcodeIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICO_XCODE_BRIDGE_INTEGRATION"] == "1",
                   "Set PICO_XCODE_BRIDGE_INTEGRATION=1 to run against xcrun mcpbridge"))
    func listsXcodesTools() async throws {
        try await withBridge(configure: {
            $0.childExecutable = URL(filePath: "/usr/bin/xcrun")
            $0.childArguments = ["mcpbridge"]
        }) { bridge in
            var client = Client(bridge)
            let (response, events) = try await client.post(initializeBody)
            client.sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
            #expect(client.sessionID?.isEmpty == false)
            let initialize = try #require(try await events.allMessages().first)
            #expect(result(initialize)?["protocolVersion"] is String)
            #expect(try await client.data(initializedNotification).0.statusCode == 202)

            let (_, list) = try await client.post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            let tools = try #require(result(try await list.allMessages().first)?["tools"] as? [[String: Any]])
            let names = tools.compactMap { $0["name"] as? String }
            print("Xcode's mcpbridge (\(serverInfo(initialize)?["version"] ?? "?")) lists \(names.count) tools: \(names.joined(separator: ", "))")
            #expect(!names.isEmpty)
            #expect(names.count == tools.count)

            #expect(try await client.data(nil, method: "DELETE").0.statusCode == 200)
        }
    }
}
