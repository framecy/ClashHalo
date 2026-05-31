# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClashPow is a **macOS 14+ (Apple Silicon only)** native SwiftUI client for the mihomo (Clash.Meta) kernel.

**Status: v1.0 — bundled-engine architecture complete (v0.4→v1.0). Self-contained .app: Go engine (embeds mihomo) + geodata bundled; GUI auto-installs engine via launchd on first run; Metal 120fps chart from mmap stats; YAML config center w/ rollback; SD-WAN topology; subscriptions/DNS/logs; DMG packaging via make.sh.**

```
┌──────────────────────┐   REST + WebSocket   ┌──────────────────────┐
│  ClashPow GUI         │◄────────────────────►│  mihomo kernel        │
│  SwiftUI 5            │  /traffic /logs       │  (external-controller │
│  MihomoClient + AppModel  /connections /proxies   127.0.0.1:6170)    │
└──────────────────────┘                       └──────────────────────┘
```

The GUI talks **directly** to mihomo's external-controller. There is no intermediate
Go engine, no JSON-RPC, no UDS. The user runs their own mihomo (launchd or manually);
the GUI connects to its REST/WS API. Connection settings (host/port/secret) are
configurable in Settings and persisted via `@AppStorage`.

**Default connection:** engine-managed mihomo controller on `127.0.0.1:9092` (secret auto-discovered from the engine via UDS `get_status`).
**App launch:** `open <path-to>/ClashPow.app` *(NOT direct binary — BackgroundOnly issue)*
**Verify connected:** `lsof -a -p $(pgrep -f ClashPow.app/Contents/MacOS/ClashPow) -iTCP -P -n` → should show 4 ESTABLISHED to :6170 (3 WS + REST).

## Architecture (4 real Swift files + stubs)

- `Sources/App/ClashPowApp.swift` — `@main`, `WindowGroup` + `MenuBarExtra`
- `Sources/App/ContentView.swift` — `NavigationSplitView` shell, sidebar, `Card`
- `Sources/UI/Dashboard/DashboardView.swift` — `DashboardPage`, `Tile`, `TrafficChart`
- `Sources/UI/ConfigEditor/Pages.swift` — `ProxiesPage` `ConnectionsPage` `RulesPage` `LogsPage` `ConfigPage` `SettingsPage` `MenuBarPanel` `ContentUnavailable`
- `Sources/Model/Models.swift` — `AppModel` (state + WS/poll orchestration), view types `ProxyGroup`/`Node`/`Conn`/`Log`, formatting helpers
- `Sources/XPC/EngineClient.swift` — `MihomoClient` (REST + WebSocket), wire types, `WSHandle`
- `Sources/Metal/IOSurfaceReader.swift` — empty stub (reserved)

The `Engine/` Go tree and `Helper/` are **legacy/unused by the current GUI** — kept for
reference but the GUI does not depend on them.

## Legacy Paths (old engine — not used by GUI)

| Resource | Path |
|----------|------|
| Old engine socket | `/tmp/clashpow-engine.sock` *(dead)* |
| User mihomo binary | `~/Library/Application Support/ClashPow/mihomo` |
| User mihomo config | `~/Desktop/mihomo_config.yaml` |
| launchd plist | `~/Library/LaunchAgents/com.clashpow.engine.plist` |

## Old Source Files

### GUI
- `Sources/App/ClashPowApp.swift` — `@main` entry, `WindowGroup` + `MenuBarExtra`
- `Sources/App/ContentView.swift` — `NavigationSplitView` shell, `SidebarView`, page router
(Legacy `Engine/` Go and `Helper/` XPC trees remain in the repo but the v0.3 GUI does
not use them. Ignore unless explicitly reviving the bundled-engine design.)

## Build & Run

```bash
# Build GUI
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug -destination 'platform=macOS,arch=arm64' build

# Run (MUST use open, not direct binary!)
APP=$(find ~/Library/Developer/Xcode/DerivedData/ClashPow-*/Build/Products/Debug -name "ClashPow.app" -type d | head -1)
open "$APP"

# Verify it connected to the kernel
lsof -a -p $(pgrep -f "ClashPow.app/Contents/MacOS/ClashPow") -iTCP -P -n   # expect 4x ESTABLISHED → :6170
```

## Critical Gotchas

1. **Direct binary = BackgroundOnly**: never run the binary directly; use `open ClashPow.app`.
2. **No mock data**: everything comes from mihomo's live REST/WS API. App shows empty states until the kernel responds.
3. **Color types**: use `Color.green` etc, not bare `.green` in `.foregroundColor`/`.fill` where the compiler infers `HierarchicalShapeStyle` (macOS 14/26 ambiguity).
4. **`Group` is taken by SwiftUI** — the proxy-group model type is named `ProxyGroup`.
5. **WebSocket auth** uses `?token=<secret>` query param; **REST** uses `Authorization: Bearer <secret>`.

## Mihomo API used by MihomoClient

| Endpoint | Transport | Purpose |
|----------|-----------|---------|
| `/version` | GET | reachability + version |
| `/proxies` | GET (poll 3s) | groups + nodes + selections + delays |
| `/proxies/:name` | PUT | switch selector group |
| `/proxies/:name/delay` | GET | latency test |
| `/configs` | GET (poll 3s) / PATCH | mode/ports/dns/tun; PATCH `{mode}` |
| `/rules` | GET | rule list (RulesPage) |
| `/traffic` | **WS** | live up/down → chart |
| `/connections` | **WS** | live connection list + totals + memory |
| `/logs?level=info` | **WS** | live log stream |
