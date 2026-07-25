#!/usr/bin/env bash
# 对端路由守卫回归测试。
#
# 直接编译生产源码 Sources/XPC/HelperProtocol.swift，不做任何重新实现——
# 测试里复刻一遍规则，只会让产品坏掉时测试照样通过。
#
# 用例基线是一台真实故障机器的路由表：Tailscale 的接口作用域路由被
# 重装成全局静态路由，把本机 LAN(10.1.1.0/24) 与全部组播(224.0.0.0/4)
# 劫持进了隧道。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc -O \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Tests/RouteGuard/main.swift" \
  -o "$OUT/routeguard-tests"

"$OUT/routeguard-tests"
