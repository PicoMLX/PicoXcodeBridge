// swift-tools-version: 6.2
import PackageDescription

// XcodeBridgeCore is the whole bridge: the HTTP side, the sessions and their `xcrun mcpbridge`
// children, and the discovery contract. The PicoXcodeBridge executable is only the menu-bar shell;
// Scripts/build-app.sh wraps it in an .app bundle and signs it. FakeMCPServer is a stdio MCP server
// the tests launch in place of `xcrun mcpbridge`, so the tests never need Xcode.
let package = Package(
    name: "PicoXcodeBridge",
    // Xcode's `mcpbridge` binary is built for macOS 26.0 (its LC_BUILD_VERSION minos), so the
    // bridge can't do anything useful on an older system.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PicoXcodeBridge", targets: ["PicoXcodeBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.29.0"),
        // These come with Hummingbird. They're named because the bridge uses HTTPField.Name (the
        // Mcp-Session-Id header), NIOCore's IOError (port in use) and ServiceGroup's graceful
        // shutdown.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "XcodeBridgeCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .executableTarget(
            name: "PicoXcodeBridge",
            dependencies: ["XcodeBridgeCore"]
        ),
        .executableTarget(
            name: "FakeMCPServer",
            path: "Tests/FakeMCPServer"
        ),
        .testTarget(
            name: "XcodeBridgeCoreTests",
            dependencies: ["XcodeBridgeCore", "FakeMCPServer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
