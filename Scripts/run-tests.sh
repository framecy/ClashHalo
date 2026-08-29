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

# TUN IPv6 接管闸门：保守缺省 + 滞回。物理 v6 断供时 TUN 不得吸走公网
# v6（mini-pro 事件：微信自带 HTTPDNS 拿真实 v6，3h 1400 次 no route to host）。
run_one tunipv6health-tests \
  "$ROOT/Sources/Model/TUNIPv6Health.swift" \
  "$ROOT/Tests/TUNIPv6Health/main.swift"

# YAML 标量：行尾注释剥离，且不得破坏 nameserver 的 #接口/#策略组 绑定。
run_one yamlscalar-tests \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Tests/YamlScalar/main.swift"

# 规则编辑器引擎：值内 `#` 是数据而非注释（旧版截断导致保存即删规则），
# fence 区（overlay 托管）在提取与注入中原样保留（旧版丢弃注释行打断
# Tailscale strip∘apply 幂等，Part 2 F1）。
run_one yamlruleengine-tests \
  "$ROOT/Sources/Model/RuleNode.swift" \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Sources/Core/Hash.swift" \
  "$ROOT/Sources/Model/TailscaleNode.swift" \
  "$ROOT/Sources/Core/YamlEditor/YamlRuleASTEngine.swift" \
  "$ROOT/Tests/YamlRuleEngine/main.swift"

# App 内存警卫：阈值分档与限频。钉住 350MB 必须触发——旧版 400MB 阈值
# 在实测占用平台期上方，等于从不运行，而构建无从发现。
run_one appmemoryguard-tests \
  "$ROOT/Sources/Model/AppMemoryGuard.swift" \
  "$ROOT/Tests/AppMemoryGuard/main.swift"

# 共存条目归属：只认领真正新增的排除项，不得撤回用户手写条目。
run_one coexprovenance-tests \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Sources/Model/CoexistenceProvenance.swift" \
  "$ROOT/Tests/CoexistenceProvenance/main.swift"

# 内置 Tailnet 覆盖层：叠加/缩进/回退。订阅配置会把 config.yaml 整个覆盖，
# 所以注入必须幂等；而 YAML 序列项缩进必须跟随原配置（订阅 YAML 用 0 列
# 短杠的概率不低于 2 列），猜错就是解析失败。
run_one tailscale-tests \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Sources/Core/Hash.swift" \
  "$ROOT/Sources/Model/TailscaleNode.swift" \
  "$ROOT/Tests/TailscaleOverlay/main.swift"

# Keychain 持久化：ad-hoc 重签 / 重装后 Tailscale key 与订阅 URL 不得丢失。
# 镜像目录 + 开放 ACL 是修复的两半；本套钉住镜像恢复路径（单元测试无法伪造
# 第二个 code-signing identity，所以 Keychain ACL 半边靠代码审阅保证）。
run_one keychain-tests \
  "$ROOT/Sources/Core/Hash.swift" \
  "$ROOT/Sources/Model/KeychainHelper.swift" \
  "$ROOT/Tests/KeychainHelper/main.swift"

# Tailscale API 设备列表解码 + 延迟测试语义分类。
# 对等节点（无 exit-node）不得参与公网 URL 测速，否则会被永久标红。
run_one tailscale-api-tests \
  "$ROOT/Sources/Model/TailscaleAPI.swift" \
  "$ROOT/Tests/TailscaleAPI/main.swift"

# 系统代理子系统：服务/设备配对解析（分支顺序回归）、目标服务选择
# （活性过滤 + 虚拟服务排除 + 无 2 服务上限 + 回退）、三态结果分类、
# -get*proxy 读回解析、bypass 单一来源网段。生产源码即 Helper 与 GUI
# fallback 共用的 ProxyServicePlan（HelperProtocol.swift）。
run_one systemproxy-tests \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Tests/SystemProxy/main.swift"

echo ""
echo "全部测试通过。"
