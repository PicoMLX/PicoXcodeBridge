# Pico Xcode Bridge

A small menu-bar companion that lets sandboxed Pico use local stdio MCP servers. Xcode remains built in; other servers are opt-in profiles configured locally. It serves each server over authenticated MCP Streamable HTTP on `127.0.0.1`. The app keeps its existing name and bundle identifier so Xcode approvals survive the update.

## Why it exists

- **Xcode's MCP server is stdio only.** A client has to launch `xcrun mcpbridge`, which talks to Xcode over XPC. Xcode offers no URL, unlike Keynote, Pages and Numbers.
- **Pico can't launch it.** Pico Server and Pico Studio ship in the Mac App Store, so they're sandboxed. They can't launch `mcpbridge` or reach Xcode's XPC service.
- **The bridge can.** It is a separate app, signed with a Developer ID, notarized, and not sandboxed. It launches one configured stdio server per MCP session and passes JSON-RPC both ways. It never reads or changes tool calls. Xcode still uses `xcrun mcpbridge`.
- **Xcode sees a signed agent.** The bridge is the process that launches `mcpbridge`, so Xcode records it by its signing identifier and team instead of a file hash. The user approves it once, and the approval survives updates.

```
Pico (sandboxed) --HTTP 127.0.0.1:<port>/mcp + bearer token--> Pico Xcode Bridge (Developer ID)
                                                                  | one `xcrun mcpbridge` per MCP session
                                                                  v
                                                               Xcode (XPC)
```

## Requirements

- macOS 26 or later. Xcode's `mcpbridge` is built for macOS 26.0.
- Xcode 26.3 or later, selected with `xcode-select`. The bridge was tested with Xcode 27.2, which lists 54 tools.

## How Pico finds it

At first launch the bridge creates a random token: 32 bytes, base64url, 43 characters. It writes the token, its port and its status to the shared defaults of Pico's app group, `UserDefaults(suiteName: "group.com.starlingprotocol.pico")`.

| Key | Type | Value |
|---|---|---|
| `xcodeBridge.port` | Int | The port on `127.0.0.1`. The endpoint is `http://127.0.0.1:<port>/mcp`. |
| `xcodeBridge.token` | String | The bearer token. Send `Authorization: Bearer <token>` on every request. |
| `xcodeBridge.status` | String | `running`, `stopped` or `failed`. |
| `xcodeBridge.xcode` | String | `reachable`: Xcode is running, as an app or headless. `notRunning`. `unavailable`: no `mcpbridge` in the selected Xcode. |
| `xcodeBridge.updatedAt` | Date | When the bridge last wrote these keys. |

These keys are the contract with Pico; `Discovery` in `Sources/XcodeBridgeCore/Discovery.swift` defines them.

How these values behave:
- **The token stays the same across launches.** Pico saves it when the user connects. It changes only when the user chooses **Reset Token**, which also ends every session. On a 401, Pico should read the token again.
- **The port stays the same where it can.** The bridge tries the port it used last, then 7428 to 7437, then any free port. A port taken by another app therefore doesn't break Pico's saved URL more often than it has to.
- **`status` can be stale.** After a crash or a forced quit, `status` still says `running`. Pico should treat the status as a hint and try to connect.

## Additional server profiles

Choose **Open Server Profiles…** in the menu to create and edit:

```
~/Library/Application Support/PicoXcodeBridge/profiles.json
```

The initial file contains disabled examples for Bear and Proxyman. Set `isEnabled` to `true` only for servers you want Pico to use, save, then choose **Reload Server Profiles**. The bridge validates the whole file before replacing its running configuration. An invalid file leaves existing connections unchanged. A successful reload ends current sessions; clients initialize again on the new server. Profiles are also loaded at startup.

For example:

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "bear",
      "name": "Bear",
      "executable": "/Applications/Bear.app/Contents/MacOS/bearcli",
      "arguments": ["mcp-server"],
      "isEnabled": true
    },
    {
      "id": "proxyman",
      "name": "Proxyman",
      "executable": "/Applications/Proxyman.app/Contents/MacOS/mcp-server",
      "arguments": [],
      "isEnabled": false
    }
  ]
}
```

- IDs are unique lowercase ASCII letters, digits, hyphens or underscores, at most 64 characters. `xcode` is reserved.
- Executables use absolute paths. Arguments are passed literally, without a shell. Paths may need adjusting for apps installed outside `/Applications`.
- Optional `environment` is a string-to-string dictionary that overrides the companion's inherited environment, including `PATH` if supplied. A menu-bar app may have a different `PATH` from Terminal; use absolute paths for interpreters and installed server binaries.
- Commands can only be changed in the local file. No HTTP endpoint installs, enables or configures a command. Enabling a profile authorizes launching that configured server when an authenticated client starts an MCP session.
- Nothing downloads npm/Python packages or installs additional applications. For community servers such as Blender or Chrome DevTools, install the server and its runtime separately, then configure their local executable and arguments.
- At most 32 additional profiles are accepted. The existing global session limit applies across all profiles.
- For development, `PICO_MCP_BRIDGE_CONFIG=/absolute/path/profiles.json` selects a separate file without editing the user's configuration.

The Bear and Proxyman commands are documented by their vendors, but their live app integrations have not been tested by this change. Affinity and other apps that serve HTTP directly connect to Pico without this companion; Affinity's legacy SSE support belongs in Pico's client.

### Discovery for multiple profiles

The existing `xcodeBridge.*` keys above are unchanged. The companion additionally writes JSON **Data** under `mcpBridge.discovery` in the same app-group defaults:

```json
{
  "version": 1,
  "port": 7428,
  "token": "<same bearer token as xcodeBridge.token>",
  "status": "running",
  "profiles": [
    {"id": "xcode", "name": "Xcode", "path": "/mcp/xcode"},
    {"id": "bear", "name": "Bear", "path": "/mcp/bear"}
  ]
}
```

Only enabled profiles are published. The manifest contains no executable, arguments or environment. Port changes, token resets and stopped/failed status also update the manifest. `/mcp` remains the legacy alias for Xcode; `/mcp/xcode` reaches the same Xcode sessions. A session created for one profile cannot be used on another profile's route, including for GET streams, notifications or DELETE.

## What the bridge does with MCP

- **Starting a session.** A `POST /mcp` with `initialize` starts a session and its `xcrun mcpbridge` child. The response carries the session's `Mcp-Session-Id`; every later request must send it.
- **Requests.** Every request is answered with an SSE stream (`text/event-stream`). The stream carries each line the child writes for that request, then the response, and then it ends. `notifications/progress` reaches the stream whose request sent the matching `_meta.progressToken`.
  - Xcode sends progress only to clients that ask for it: a 131 s build sent 126 progress notifications.
  - A proxy that answers with plain JSON makes Pico's client time out after 60 s.
- **Notifications and responses from the client.** These are written to the child, and the bridge answers `202 Accepted`. A `notifications/cancelled` also ends the cancelled request's stream, because the child won't answer that request.
- **Other server messages.** `GET /mcp` opens a stream for everything else the child sends: `notifications/tools/list_changed`, logging, and requests to the client. A newer GET stream replaces an older one.
  - While no GET stream is open, these messages go on an open POST stream, which MCP allows.
  - If no stream is open at all, they wait (up to 256) for the next GET stream.
- **`DELETE /mcp`.** Ends the session. The bridge closes the child's stdin, sends SIGTERM if the child is still running two seconds later, and uses SIGKILL after four seconds if it ignores termination.
- **Heartbeats.** Every stream starts with an SSE comment, and every open stream gets another one every 15 s.
  - The first comment makes the response headers go out at once.
  - The later ones keep a client's idle timer from firing while Xcode stays silent. For example, `XcodeOpenWorkspace` sent nothing for 64 s while it waited for the user's approval.
  - When a heartbeat can't be written, the bridge knows the client is gone.
- **Limits.**
  - A session with no open stream is stopped after 30 minutes without a request.
  - At most 8 children run at once. Beyond that, a new session replaces the least recently used idle one; if every session is busy, the bridge answers 503.
  - JSON-RPC batches get 400.
  - A request body may be at most 32 MB.
- **Errors.** If the child exits, its pending requests get a JSON-RPC error with code -32002 that quotes the child's last stderr line. Unknown sessions get 404 with code -32001.

## Security

- **Localhost only.** The bridge listens on `127.0.0.1` and on nothing else.
- **A bearer token on every request.** It's compared in constant time. Missing or wrong: 401.
- **No browsers.** Any request with an `Origin` header gets 403. A `Host` other than `127.0.0.1:<port>` or `localhost:<port>` gets 421, which stops DNS rebinding. Both checks run before the token check, so a web page learns nothing about the token.
- **No new reach.** Everything Xcode does still needs Xcode's own approval of the bridge and of each project folder, and the user can revoke both in Xcode. Pico's approval prompt stays the gate for builds, runs and edits.
- **Where the token lives.** The token is in the app group's container. Apps outside the group get a macOS privacy prompt before they can read it.

## The app

The menu-bar item shows:
- how many additional server profiles are enabled;
- whether Xcode is reachable;
- how many clients are connected;
- the port the bridge listens on.

It has these items:
- **Open at Login**, which uses `SMAppService.mainApp`. The first launch from an Applications folder turns it on; builds run from elsewhere never do.
- **Open Server Profiles…** and **Reload Server Profiles**.
- **Reset Token**, ending sessions across every profile.
- **Open Logs**, which runs `xcrun mcp-server show-logs` and opens the file it writes.
- **Quit**, which stops accepting sessions and waits for the launched server processes to terminate before the app exits.

## Build and test

```bash
swift build
```

```bash
swift test
```

The unit tests launch `FakeMCPServer` (`Tests/FakeMCPServer`) in place of `xcrun mcpbridge`, so they don't need Xcode. They cover routing, the token, Host and Origin checks, SSE forwarding and progress ordering, the GET stream, cancellation, DELETE, the idle timeout, a crashing child, heartbeats, large messages, port fallback, profile routing and isolation, profile configuration validation, and versioned discovery.

One integration test runs against the real `xcrun mcpbridge`. It initializes and lists tools only. It doesn't open a project, so it never asks Xcode for approval.

```bash
PICO_XCODE_BRIDGE_INTEGRATION=1 swift test --filter XcodeIntegrationTests
```

## The Xcode project

The menu-bar app is the **Pico Xcode Bridge** target in `PicoXcodeBridge.xcodeproj`. Its source, `Info.plist` and entitlements are in `App/`. It links the package's `XcodeBridgeCore` library through a local package reference, so all the bridge code and its tests stay in the package.

To run the app, open `PicoXcodeBridge.xcodeproj` and choose **Product › Run**. To build it from Terminal without signing:

```bash
xcodebuild -project PicoXcodeBridge.xcodeproj -scheme "Pico Xcode Bridge" -configuration Release build CODE_SIGNING_ALLOWED=NO
```

For development, `PICO_XCODE_BRIDGE_SUITE=<name>` makes the app write to another defaults suite instead of Pico's group, for example to run a second copy without touching Pico's settings. The scheme defines it, turned off; turn it on under **Product › Scheme › Edit Scheme › Run › Arguments**.

The package and the project each pin the dependency versions: `Package.resolved` for `swift build` and `swift test`, and `PicoXcodeBridge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` for Xcode. Keep the two the same.

## Release

The target signs automatically with team TPKP4XK352 and the hardened runtime. It isn't sandboxed, and its entitlements hold only the app group `group.com.starlingprotocol.pico`.

1. In **Xcode › Settings › Accounts**, sign in with an Apple Account on team TPKP4XK352.
2. Open `PicoXcodeBridge.xcodeproj`. If this is a new version, set **Version** and **Build** on the target's **General** tab.
3. Choose the **Pico Xcode Bridge** scheme and **My Mac** as the destination, then **Product › Archive**.
4. In the Organizer, select the archive and click **Distribute App**. Choose **Direct Distribution**, then **Distribute**. Xcode signs the app with Developer ID, uploads it to Apple's notary service, and staples the ticket once Apple accepts it.
5. When notarization is done, select the archive and click **Export Notarized App**.
6. To attach the app to a GitHub release, zip it first:

```bash
ditto -c -k --keepParent "Pico Xcode Bridge.app" PicoXcodeBridge.zip
```

**Xcode sets up the signing assets.** The first time Xcode signs the app for the team, on the first Run or the first archive, it registers the App ID `com.starlingprotocol.pico-xcode-bridge` with the app group and creates the provisioning profiles that list the group. Distribute App signs with a cloud-managed Developer ID certificate, so there's no certificate to install. If Xcode says the account can't use one, sign in as the team's Account Holder, or ask the Account Holder for access to cloud-managed Developer ID certificates.

**Builds without the team's profile can't share the app group.** A build signed ad hoc or not at all, such as the `CODE_SIGNING_ALLOWED=NO` build above, has no app-group entitlement. Its defaults go to `~/Library/Preferences` instead of the group container. The bridge works over HTTP, but Pico can't discover it.

### Keep the bundle identifier

Xcode records the approved agent by its signing identifier (`com.starlingprotocol.pico-xcode-bridge`) and team. Changing either makes every user approve the bridge again.

### Not tested yet

These need the team's signing, which the repository's own checks don't use:
- An archive signed with Developer ID, notarized and stapled.
- Xcode's **Always** approval of that build.
- The app group shared between this unsandboxed app and sandboxed Pico.

If the registered group turns out to be a problem, the fallback is a team-prefixed group, `TPKP4XK352.com.starlingprotocol.xcode-bridge`. That needs no profile. The bridge would write its port and token to a file in that group's container.

## Layout

```
Package.swift                    the package: XcodeBridgeCore, FakeMCPServer and the tests
Sources/XcodeBridgeCore/
  BridgeServer.swift   HTTP: routing, the Host, Origin and token checks, SSE responses, ports
  MCPSession.swift     sessions, the child process, line framing, JSON-RPC routing fields
  Discovery.swift      the legacy and versioned app-group contracts with Pico and the token
  BridgeProfiles.swift locally configured stdio servers and validation
Tests/FakeMCPServer/main.swift   the stdio MCP server the tests launch
Tests/XcodeBridgeCoreTests/      Swift Testing tests
PicoXcodeBridge.xcodeproj        the app target, which links XcodeBridgeCore
App/
  PicoXcodeBridgeApp.swift       the menu-bar app
  Info.plist
  PicoXcodeBridge.entitlements   the app group
```

## License

MIT; see `LICENSE`.
