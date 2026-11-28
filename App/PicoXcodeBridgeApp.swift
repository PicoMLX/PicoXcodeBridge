import AppKit
import ServiceManagement
import SwiftUI
import XcodeBridgeCore

@main
struct PicoXcodeBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            BridgeMenu(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.symbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = BridgeController()
    private var terminationSignal: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (`killall`, launchd) would skip applicationWillTerminate and leave the
        // published status at "running"; quit through AppKit instead.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The children see their stdin close when the bridge exits, and stop.
        controller.publishStopped()
    }
}

// MARK: - Menu

struct BridgeMenu: View {
    let controller: BridgeController

    var body: some View {
        Text(controller.xcodeDescription)
        Text(controller.clientDescription)
        Text(controller.listeningDescription)
        Divider()
        Toggle("Open at Login", isOn: Binding(
            get: { controller.launchesAtLogin },
            set: { controller.setLaunchesAtLogin($0) }
        ))
        if controller.loginItemNeedsApproval {
            Button("Allow in Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
        }
        Button("Reset Token") { controller.resetToken() }
        Button("Open Logs") { controller.openLogs() }
        if let message = controller.lastError {
            Divider()
            Text(message)
        }
        Divider()
        Button("Quit Pico Xcode Bridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Controller

@MainActor
@Observable
final class BridgeController {
    private(set) var port: Int?
    private(set) var clientCount = 0
    private(set) var xcode: Discovery.XcodeState?
    private(set) var serverFailed = false
    private(set) var lastError: String?
    private(set) var loginItemStatus = SMAppService.mainApp.status

    /// PICO_XCODE_BRIDGE_SUITE points a development build at other defaults than Pico's group.
    private let discovery = Discovery(suiteName: ProcessInfo.processInfo.environment["PICO_XCODE_BRIDGE_SUITE"] ?? Discovery.appGroup)
    private var server: BridgeServer?

    var symbolName: String {
        if serverFailed { return "exclamationmark.triangle" }
        return xcode == .reachable ? "hammer.fill" : "hammer"
    }

    var xcodeDescription: String {
        switch xcode {
        case nil: "Xcode: checking…"
        case .reachable: "Xcode: reachable"
        case .notRunning: "Xcode: not running"
        case .unavailable: "Xcode: no mcpbridge (needs Xcode 26.3 or later)"
        }
    }

    var clientDescription: String {
        clientCount == 1 ? "1 client connected" : "\(clientCount) clients connected"
    }

    var listeningDescription: String {
        if serverFailed { return "Not listening" }
        guard let port else { return "Starting…" }
        return "Listening on 127.0.0.1:\(port)"
    }

    var launchesAtLogin: Bool { loginItemStatus == .enabled }
    var loginItemNeedsApproval: Bool { loginItemStatus == .requiresApproval }

    func start() {
        let server = BridgeServer(
            configuration: BridgeConfiguration(preferredPort: discovery.lastPort),
            token: discovery.token(),
            onSessionCountChange: { [weak self] _ in
                // These tasks can run out of order, so each reads the current count.
                Task { @MainActor in
                    guard let self, let server = self.server else { return }
                    self.clientCount = await server.sessionCount
                }
            }
        )
        self.server = server
        Task {
            do {
                try await server.run { port in
                    await MainActor.run {
                        self.port = port
                        self.discovery.publish(port: port)
                        self.discovery.publish(status: .running)
                    }
                }
            } catch {
                serverFailed = true
                lastError = "Couldn't listen: \(error.localizedDescription)"
                discovery.publish(status: .failed)
            }
        }
        Task { await monitorXcode() }
        addLoginItemOnFirstLaunch()
    }

    func publishStopped() {
        discovery.publish(status: .stopped)
    }

    /// Pico picks up the new token from the app group; connected clients are cut off.
    func resetToken() {
        let token = discovery.resetToken()
        Task { await server?.resetToken(to: token) }
    }

    func openLogs() {
        Task {
            let result = await Tool.run(["mcp-server", "show-logs"])
            let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
            if result.status == 0, path.hasPrefix("/") {
                NSWorkspace.shared.open(URL(filePath: path))
            } else {
                lastError = "Couldn't get Xcode's logs: \(result.output)"
            }
        }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Login item: \(error.localizedDescription)"
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    /// The first time the bridge runs from an Applications folder it adds itself as a login item.
    /// Builds run from elsewhere (a build folder) don't, so a development build never becomes one.
    private func addLoginItemOnFirstLaunch() {
        let key = "didAddLoginItem"
        let path = Bundle.main.bundleURL.path
        let inApplications = path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path + "/")
        guard inApplications, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if loginItemStatus != .enabled { setLaunchesAtLogin(true) }
    }

    /// Xcode is reachable when `mcpbridge` exists and Xcode runs, as an app or headless.
    private func monitorXcode() async {
        let hasMCPBridge = await Tool.run(["--find", "mcpbridge"]).status == 0
        while !Task.isCancelled {
            let state: Discovery.XcodeState
            if !hasMCPBridge {
                state = .unavailable
            } else if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty {
                state = .reachable
            } else {
                state = await Tool.headlessXcodeIsRunning() ? .reachable : .notRunning
            }
            if state != xcode {
                xcode = state
                discovery.publish(xcode: state)
            }
            loginItemStatus = SMAppService.mainApp.status
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

// MARK: - xcrun

/// Runs `xcrun` for the menu's checks and Open Logs.
enum Tool {
    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    static func run(_ arguments: [String]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/xcrun")
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
                    return
                }
                // Read before waiting, so a full pipe can't stall the tool.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: Result(status: process.terminationStatus, output: text))
            }
        }
    }

    /// `xcrun mcp-server status` reports `running` for headless Xcode only.
    static func headlessXcodeIsRunning() async -> Bool {
        let result = await run(["mcp-server", "status", "--format", "json"])
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return status["running"] as? Bool ?? false
    }
}
