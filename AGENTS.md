# Working on Pico Xcode Bridge

These are the conventions for this repository, for people and coding agents. `README.md` explains what the bridge does and why.

## What the bridge is, and isn't

- It is a pass-through proxy: MCP streamable HTTP on `127.0.0.1`, with one `xcrun mcpbridge` child per session.
- It parses only the fields it needs to route a message: `id`, `method`, the progress token and the cancelled request's id. It forwards the original bytes.
- **It never interprets, rewrites or filters tool calls or their results.** The one planned exception: replacing paths under Xcode's `ActionArtifacts` folder, which a sandboxed client can't read, with the files' contents. It needs its own design note before it lands.

## Code

- **Concrete types.** Don't add a protocol for a single implementation, a dependency-injection layer, or an abstraction "for testing". Tests run the real types against `FakeMCPServer`.
- **The fewest files.**
  - The core is three files: `BridgeServer.swift`, `MCPSession.swift` and `Discovery.swift`.
  - The app is one: `App/PicoXcodeBridgeApp.swift`, the only source file of the app target in `PicoXcodeBridge.xcodeproj`. Code that isn't menu-bar UI belongs in the package, where the tests reach it.
  - Add a file only when one holds unrelated things or grows hard to read, not for each type.
- **Swift 6 language mode, with strict concurrency.**
  - Prefer actors and `Mutex` over locks.
  - Every `@unchecked Sendable` needs a comment that says why it is safe.
- **Few dependencies.** Hummingbird serves HTTP. The other packages named in `Package.swift` already come with it. Ask before adding a new one.
- **Comments say why**, not what the next line does.

## Contracts

- **The `xcodeBridge.*` keys and the app group `group.com.starlingprotocol.pico` are read by Pico.** Changing them breaks Pico. Change them only together with Pico, and update the table in `README.md`.
- **Keep the bundle identifier `com.starlingprotocol.pico-xcode-bridge`.** Xcode records approvals by signing identifier and team, so changing it makes users approve the bridge again.
- **Keep the security checks first and as strict.** Bind only to `127.0.0.1`. Refuse any `Origin`. Allow only `127.0.0.1:<port>` and `localhost:<port>` as `Host`. Require the bearer token on every request.

## Tests

- **Use Swift Testing (`import Testing`), not XCTest.**
- **Never weaken a test to make it pass.** Don't delete, skip or loosen an assertion, and don't add retries or longer sleeps to hide a race. Fix the code. If a behavior changes on purpose, change the test with it and say why in the commit message.
- **Unit tests must not need Xcode.** They launch `Tests/FakeMCPServer`. Give it a new tool when a test needs new child behavior.
- **`XcodeIntegrationTests` runs only with `PICO_XCODE_BRIDGE_INTEGRATION=1`.** Tests must never open a project in Xcode or cause an approval prompt. Listing tools is fine.

```bash
swift test
```

```bash
PICO_XCODE_BRIDGE_INTEGRATION=1 swift test --filter XcodeIntegrationTests
```

```bash
xcodebuild -project PicoXcodeBridge.xcodeproj -scheme "Pico Xcode Bridge" -configuration Release build CODE_SIGNING_ALLOWED=NO
```

- **The Xcode project is the one way to build the app.** Its target holds the `Info.plist`, the entitlements, the version and the signing settings. Don't add a second one, such as a script that assembles the `.app`.
- **Check the app with unsigned builds**, as above. Signing, archives and notarization are for whoever releases the app, in Xcode.

In a sandboxed agent shell, SwiftPM may need its own sandbox off (`--disable-sandbox`) or the command run outside the agent's sandbox.

## Git

- Keep `main` clean in the primary checkout. Do feature work on a branch in a worktree under `.claude/worktrees/`, which `.gitignore` excludes.
- End commit messages written with a coding agent with the attribution line that agent's instructions give.
- Commit both `Package.resolved` files and keep them the same: the package's, and Xcode's in `PicoXcodeBridge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`. This is an app, and its dependency versions are pinned.
