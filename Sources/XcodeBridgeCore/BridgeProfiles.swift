import Foundation

/// A stdio server selected locally by the user. HTTP requests can select a profile, never a command.
public struct BridgeProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var isEnabled: Bool

    public init(id: String, name: String, executable: String, arguments: [String] = [],
                environment: [String: String]? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.isEnabled = isEnabled
    }

    public var path: String { "/mcp/" + id }

    public static let xcode = BridgeProfile(id: "xcode", name: "Xcode", executable: "/usr/bin/xcrun", arguments: ["mcpbridge"])

    /// Nothing is launched until the user enables a profile and a client initializes a session.
    public static let examples = [
        BridgeProfile(id: "bear", name: "Bear", executable: "/Applications/Bear.app/Contents/MacOS/bearcli",
                      arguments: ["mcp-server"], isEnabled: false),
        BridgeProfile(id: "proxyman", name: "Proxyman", executable: "/Applications/Proxyman.app/Contents/MacOS/mcp-server",
                      isEnabled: false),
    ]
}

/// Versioned local configuration. Invalid entries fail the whole reload, preserving the running set.
public struct BridgeProfileConfiguration: Codable, Sendable {
    public var version: Int
    public var profiles: [BridgeProfile]

    public init(version: Int = 1, profiles: [BridgeProfile] = []) {
        self.version = version
        self.profiles = profiles
    }

    public enum ValidationError: LocalizedError {
        case unsupportedVersion, tooManyProfiles, invalidID(String), duplicateID(String), invalidCommand(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "The profiles file must use version 1."
            case .tooManyProfiles: "The profiles file can contain at most 32 profiles."
            case .invalidID(let id): "Invalid profile ID: \(id). Use lowercase letters, digits, hyphens or underscores; xcode is reserved."
            case .duplicateID(let id): "Duplicate profile ID: \(id)."
            case .invalidCommand(let id): "Profile \(id) needs a name and an absolute executable path, without null characters."
            }
        }
    }

    public func validatedProfiles() throws -> [BridgeProfile] {
        guard version == 1 else { throw ValidationError.unsupportedVersion }
        guard profiles.count <= 32 else { throw ValidationError.tooManyProfiles }
        var ids = Set<String>()
        for profile in profiles {
            let characters = profile.id.utf8
            guard !characters.isEmpty, characters.count <= 64, profile.id != "xcode",
                  characters.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
            else { throw ValidationError.invalidID(profile.id) }
            guard ids.insert(profile.id).inserted else { throw ValidationError.duplicateID(profile.id) }
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.name.utf8.count <= 256, !profile.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  profile.executable.hasPrefix("/"),
                  !profile.executable.contains("\0"),
                  profile.arguments.allSatisfy({ !$0.contains("\0") }),
                  profile.environment?.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) ?? true
            else { throw ValidationError.invalidCommand(profile.id) }
        }
        return profiles.filter(\.isEnabled)
    }

    public static func load(from url: URL) throws -> [BridgeProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).validatedProfiles()
    }

    public static func exampleData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Self(profiles: BridgeProfile.examples))
    }
}
