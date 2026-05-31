# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClashPow is a **macOS 14+ (Apple Silicon only)** native proxy GUI client wrapping the mihomo (Clash.Meta) kernel.

**Status: v0.2 — BUILD SUCCEEDED, engine running, 9 GUI pages with real mihomo data.**

```
┌──────────────┐  JSON-RPC (UDS)    ┌──────────────────────┐
│  GUI Process │◄──────────────────►│  Engine Process       │
│  SwiftUI 5   │  Mihomo REST API  │  mihomo kernel (Go)   │
│  + AppKit    │◄──────────────────►│  launchd daemon       │
└──────────────┘                    └──────────────────────┘
```

**Engine pid:** `launchctl list | grep clashpow`
**App launch:** `open -a <path-to>/ClashPow.app` *(NOT direct binary — BackgroundOnly issue)*

## Key Paths

| Resource | Path |
|----------|------|
| Engine socket | `/tmp/clashpow-engine.sock` |
| Engine log socket | `/tmp/clashpow-log.sock` |
| Mihomo REST API | `http://127.0.0.1:9091` (secret set by user config) |
| Engine binary (dev) | `~/Library/Application Support/ClashPow/clashpow-engine` |
| Engine logs | `~/Library/Logs/ClashPow/clashpow-engine.log` |
| Engine plist | `~/Library/LaunchAgents/com.clashpow.engine.plist` |

## Source Files (12 Swift + 10 Go)

### GUI
- `Sources/App/ClashPowApp.swift` — `@main` entry, `WindowGroup` + `MenuBarExtra`
- `Sources/App/ContentView.swift` — `NavigationSplitView` shell, `SidebarView`, page router
- `Sources/UI/Dashboard/DashboardView.swift` — `DashboardPage` with stat grid, traffic chart, chain view
- `Sources/UI/ConfigEditor/Pages.swift` — All other pages: `ProxiesPage`, `ConnectionsPage`, `DnsPage`, `LogsPage`, `SdwanPage`, `SubscriptionsPage`, `ConfigPage`, `SettingsPage`, `MenuBarPanel`
- `Sources/Model/Models.swift` — `AppState` (central ObservableObject), `TrafficModel`, all data types, engine polling loop
- `Sources/XPC/EngineClient.swift` — JSON-RPC over UDS + Mihomo REST HTTP client
- `Sources/XPC/HelperManager.swift` — Privileged helper XPC (TUN/route/sysproxy)
- `Sources/XPC/KernelUpdateManager.swift` — Mihomo kernel update from GitHub

### Engine
- `Engine/cmd/clashpow/main.go` — Entry point, wires mihomo + extensions + RPC server
- `Engine/xpc/server.go` — JSON-RPC server (UDS) — `get_status`, `set_config`, `compile_rules`, `reload_rules`, `shutdown`, `start_tun`, `stop_tun`
- `Engine/xpc/compile.go` — YAML rules → binary Trie compiler
- `Engine/xpc/tun.go` — UTUN manager (AF_SYSTEM, no VPN slot)
- `Engine/mmap/loader.go` — mmap binary rule loader (atomic hot-swap)
- `Engine/stats/pusher.go` — IOSurface stats ring buffer writer
- `Engine/routed/daemon.go` — SD-WAN route daemon
- `Engine/routed/split.go` — Per-process traffic split (SO_USER_COOKIE + PF)

## Build Commands

```bash
# Engine
cd Engine && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o /tmp/clashpow-engine ./cmd/clashpow

# Deploy engine
cp /tmp/clashpow-engine "$HOME/Library/Application Support/ClashPow/clashpow-engine"
launchctl unload "$HOME/Library/LaunchAgents/com.clashpow.engine.plist" 2>/dev/null
launchctl load "$HOME/Library/LaunchAgents/com.clashpow.engine.plist"

# GUI
xcodebuild -project ClashPow.xcodeproj -scheme ClashPow -configuration Debug -destination 'platform=macOS,arch=arm64' build

# Run (MUST use open, not direct binary!)
APP=$(find ~/Library/Developer/Xcode/DerivedData/ClashPow-*/Build/Products/Debug -name "ClashPow.app" -type d | head -1)
open -a "$APP"
```

## Critical Gotchas

1. **Direct binary = BackgroundOnly**: Never run the ClashPow binary directly. Must use `open -a ClashPow.app` or macOS launches it with `type=BackgroundOnly`, window never renders.
2. **No mock data**: All data comes from engine (mihomo REST API at `:9091`). App starts empty, populates via 2s polling loop.
3. **Color types**: Use `Color.green`, not `.green` in view bodies — macOS 14/26 has `Color` vs `HierarchicalShapeStyle` ambiguity.
4. **TableColumn key paths**: Must be wrapped in `{}` closures on macOS 14 for non-Identifiable value types.

## Mihomo REST API

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/version` | GET | mihomo version |
| `/proxies` | GET | All proxies + groups |
| `/proxies/:name` | PUT | Switch proxy selection |
| `/proxies/:name/delay` | GET | Latency test |
| `/connections` | GET | Active connections |
| `/rules` | GET | Rule list |
| `/configs` | GET | Full running config |
| `/traffic` | GET | Up/down totals |

All requests need `Authorization: Bearer clashpow` header.
