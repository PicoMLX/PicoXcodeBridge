// swift-tools-version: 6.2
import PackageDescription

// XcodeBridgeCore is the whole bridge: the HTTP side, the sessions and their `xcrun mcpbridge`
// children, and the discovery contract. The menu-bar app is the "Pico Xcode Bridge" target in
// PicoXcodeBridge.xcodeproj, which links this library; Xcode archives, signs and notarizes it.
// FakeMCPServer is a stdio MCP server the tests launch in place of `xcrun mcpbridge`, so the tests
// never need Xcode.
let package = Package(
    name: "PicoXcodeBridge",
    // Xcode's `mcpbridge` binary is built for macOS 26.0 (its LC_BUILD_VERSION minos), so the
    // bridge can't do anything useful on an older system.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XcodeBridgeCore", targets: ["XcodeBridgeCore"]),
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
