import Foundation
import Security

/// The contract with Pico: what the bridge writes to the shared app group's defaults so Pico can
/// find it without the user typing anything. Pico reads these keys; changing one breaks Pico.
///
/// | Key | Type | Meaning |
/// |---|---|---|
/// | `xcodeBridge.port` | Int | The port on `127.0.0.1`; the endpoint is `http://127.0.0.1:<port>/mcp`. |
/// | `xcodeBridge.token` | String | The bearer token every request needs. |
/// | `xcodeBridge.status` | String | `running`, `stopped` or `failed`. |
/// | `xcodeBridge.xcode` | String | `reachable`, `notRunning` or `unavailable` (no `mcpbridge`). |
/// | `xcodeBridge.updatedAt` | Date | When the bridge last wrote these. |
public struct Discovery: @unchecked Sendable {
    // @unchecked: UserDefaults is thread-safe.
    public static let appGroup = "group.com.starlingprotocol.pico"

    public enum Key {
        public static let port = "xcodeBridge.port"
        public static let token = "xcodeBridge.token"
        public static let status = "xcodeBridge.status"
        public static let xcode = "xcodeBridge.xcode"
        public static let updatedAt = "xcodeBridge.updatedAt"
        public static let manifest = "mcpBridge.discovery"
    }

    public enum Status: String, Sendable, Codable {
        case running, stopped, failed
    }

    public enum XcodeState: String, Sendable {
        case reachable, notRunning, unavailable
    }

    public let defaults: UserDefaults

    public init(suiteName: String = Discovery.appGroup) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// The token, created on first use. It stays the same across launches, since Pico saves it
    /// when the user connects, until `resetToken()`.
    public func token() -> String {
        if let token = defaults.string(forKey: Key.token), !token.isEmpty { return token }
        return resetToken()
    }

    @discardableResult
    public func resetToken() -> String {
        let token = Self.makeToken()
        defaults.set(token, forKey: Key.token)
        touch()
        refreshManifest()
        return token
    }

    /// The port published last, which the bridge tries first so Pico's saved URL keeps working.
    public var lastPort: Int? {
        defaults.object(forKey: Key.port) as? Int
    }

    public func publish(port: Int) {
        defaults.set(port, forKey: Key.port)
        touch()
        refreshManifest()
    }

    public func publish(status: Status) {
        defaults.set(status.rawValue, forKey: Key.status)
        touch()
        refreshManifest()
    }

    public func publish(xcode: XcodeState) {
        defaults.set(xcode.rawValue, forKey: Key.xcode)
        touch()
    }

    /// The additional discovery contract. It contains only public profile metadata, never commands
    /// or their environment. The token has the same app-group protection as the legacy token key.
    public struct Manifest: Codable, Sendable, Equatable {
        public struct Profile: Codable, Sendable, Equatable {
            public let id: String
            public let name: String
            public let path: String
        }

        public var version = 1
        public var port: Int
        public var token: String
        public var status: Status
        public var profiles: [Profile]
    }

    /// Publish only the profiles this server actually routes. Xcode also keeps its legacy /mcp URL.
    public func publish(profiles: [BridgeProfile]) {
        guard let port = lastPort, (1...65535).contains(port) else { return }
        let manifest = Manifest(port: port, token: token(),
            status: defaults.string(forKey: Key.status).flatMap(Status.init(rawValue:)) ?? .stopped,
            profiles: ([BridgeProfile.xcode] + profiles.filter(\.isEnabled)).map {
                Manifest.Profile(id: $0.id, name: $0.name, path: $0.path)
            })
        write(manifest)
    }

    private func refreshManifest() {
        guard let data = defaults.data(forKey: Key.manifest),
              var manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let port = lastPort, let token = defaults.string(forKey: Key.token), !token.isEmpty
        else { return }
        manifest.port = port
        manifest.token = token
        manifest.status = defaults.string(forKey: Key.status).flatMap(Status.init(rawValue:)) ?? .stopped
        write(manifest)
    }

    private func write(_ manifest: Manifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        defaults.set(data, forKey: Key.manifest)
    }

    private func touch() {
        defaults.set(Date(), forKey: Key.updatedAt)
    }

    /// 32 random bytes, base64url without padding: 43 characters.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
