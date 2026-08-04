#!/usr/bin/env bash
# 回归测试入口。
#
# 直接编译生产源码，不做任何重新实现——
# 测试里复刻一遍规则，只会让产品坏掉时测试照样通过。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

run_one() {
  local name="$1"; shift
  echo ""
  echo "══ $name ══"
  xcrun swiftc -O "$@" -o "$OUT/$name"
  "$OUT/$name"
}

# 对端路由守卫：真实故障机器路由表回归。
run_one routeguard-tests \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Tests/RouteGuard/main.swift"

# TUN 数据面探针：DNS 校验 + 连续失败状态机。
run_one tundataplane-tests \
  "$ROOT/Sources/Model/TUNDataPlaneProbe.swift" \
  "$ROOT/Tests/TUNDataPlaneProbe/main.swift"

# YAML 标量：行尾注释剥离，且不得破坏 nameserver 的 #接口/#策略组 绑定。
run_one yamlscalar-tests \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Tests/YamlScalar/main.swift"

# 共存条目归属：只认领真正新增的排除项，不得撤回用户手写条目。
run_one coexprovenance-tests \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Sources/Model/CoexistenceProvenance.swift" \
  "$ROOT/Tests/CoexistenceProvenance/main.swift"

echo ""
echo "全部测试通过。"
