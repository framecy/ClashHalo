#!/usr/bin/env bash
# 回归测试入口。
#
# 原则没变：直接编译生产源码，不在测试里重新实现一遍规则——复刻一遍逻辑，
# 只会让产品坏掉时测试照样通过。
#
# 为什么重写：旧版是 `set -e` + 12 条 `run_one` 顺序执行，两个后果都很实在。
# 其一是**一红全断**——任何一套失败，后面所有套件根本不执行，"跑过回归"实际
# 只覆盖了排在最前面的那一套。其二是**引用会烂**：`Tests/` 自 291a239 起不再
# 入库，新克隆的仓库里 12 条路径有 11 条指向不存在的文件，而 swiftc 的报错是
# "error opening input file"，看起来像编译坏了，不像测试没装。
# 现在：全部跑完、按套件归类结果、缺文件单独算一类并给出恢复命令。
#
#   bash Scripts/run-tests.sh              全跑
#   bash Scripts/run-tests.sh --only yaml  只跑名字含 yaml 的
#   bash Scripts/run-tests.sh --list       列清单
# 退出码：0 = 全绿；1 = 有失败/编译错/缺文件。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

SUITES=()   # name:::sources(空格分隔)
add_suite() {
  local name="$1"; shift
  SUITES+=("$name:::$*")
}

# ── 套件清单 ───────────────────────────────────────────────────────────
# 每套为什么存在，一句话——这套清单本身就是缺陷档案。

# 对端路由守卫：真实故障机器路由表回归。把对端的接口作用域路由（I 标志）
# 当成可撤回条目重装，等于凭空制造一次劫持。
add_suite routeguard-tests \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Tests/RouteGuard/main.swift"

# TUN 数据面探针：DNS 报文校验 + 滑动窗口失败状态机。半死 fd 是「多数失败、
# 偶尔成功」，连续计数在这种形态下永远不触发。
add_suite tundataplane-tests \
  "$ROOT/Sources/Model/TUNDataPlaneProbe.swift" \
  "$ROOT/Tests/TUNDataPlaneProbe/main.swift"

# TUN IPv6 接管闸门：保守缺省 + 滞回。物理 v6 断供时 TUN 不得吸走公网 v6
# （mini-pro 事件：微信自带 HTTPDNS 拿真实 v6，3h 1400 次 no route to host）。
add_suite tunipv6health-tests \
  "$ROOT/Sources/Model/TUNIPv6Health.swift" \
  "$ROOT/Tests/TUNIPv6Health/main.swift"

# TUN 自循环哨兵：僵尸态内核的 DIRECT 出网回注同一隧道，单连接下行以链路
# 速率膨胀而物理网卡零流量。以 2026-09-16 幽灵流量事故数据回放钉住。
# 注意：这套曾长期只存在于本地、从未登记进本清单，因此从未被跑过。
add_suite loop-sentinel-tests \
  "$ROOT/Sources/Model/TUNLoopSentinel.swift" \
  "$ROOT/Tests/TUNLoopSentinel/main.swift"

# YAML 标量：行尾注释剥离，且不得破坏 nameserver 的 #接口/#策略组 绑定。
add_suite yamlscalar-tests \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Tests/YamlScalar/main.swift"

# TUN 系统 DNS 网关：2026-10-09 断网事故。配置里的 inet4-address 是**前缀**
# （198.18.0.0/30），裸切掉 /30 写进系统 DNS 的是网络地址 .0 —— 内核永不应答，
# TUN 一抖/一关就全网解析黑洞（实测 dig @198.18.0.0 → connection timed out，
# ping → 100% 丢包，而 utun100 还在）。钉住「必须取前缀里的主机地址」以及
# fake-ip 残留识别，后者是修复「overridden 标志失同步后残留永不清理」的依据。
add_suite tundnsaddress-tests \
  "$ROOT/Sources/Model/TUNDNSAddress.swift" \
  "$ROOT/Tests/TUNDNSAddress/main.swift"

# 系统 DNS 重定向台账：2026-10-14 多次断网事故的根因簇——双写者（TUN fake-ip
# 网关 / 代理 redir-host 的 127.0.0.1）共用单快照与单 flag、退出路径无条件清账、
# sweep 有两个盲区。钉住 TunnelDNSLedger 的 5 条不变量：属主隔离（接管时继承
# 真值快照）、快照只在读取成功时落盘（三态 nil ≠ Empty）、pending→committed
# 两段式、恢复失败保留账本、服务漂移自愈；另钉 shouldSweepResidueOn 的共存
# 豁免逐地址取证（39 条断言）。生产适配器 `EngineControlDNSDriver` 在
# EngineControl.swift 末尾，套件以同名 stub（StubDriver.swift）替身，
# TunnelDNSLedger.swift 保持零 impure 依赖、可单独编译。
add_suite dnsledger-tests \
  "$ROOT/Sources/Model/TunnelDNSLedger.swift" \
  "$ROOT/Sources/Model/TUNDNSAddress.swift" \
  "$ROOT/Tests/DNSLedger/StubDriver.swift" \
  "$ROOT/Tests/DNSLedger/main.swift"

# config.yaml 写入审计：11 个调用点就地改写运行配置，其中设置页的 persistent 键
# 会压过已激活的 profile。此前无任何记录——排查只能比对 config.yaml.bak-* 快照，
# 且答不出「哪个键、何时、被谁」。钉住顶层标量解析口径、差异计算，以及 secret
# 之类凭据必须脱敏但仍留痕。
add_suite configwriteaudit-tests \
  "$ROOT/Sources/Model/ConfigWriteAudit.swift" \
  "$ROOT/Tests/ConfigWriteAudit/main.swift"

# 重新激活 profile 的短路判定：appliedHash 哈希的是 profile 自身，而设置页把
# persistent 键就地写进 config.yaml —— profile 没变、运行配置已漂移，短路却仍
# 成立，于是「已切换配置」是绿色空操作，实测 7 个键永不恢复。钉住漂移必须能
# 阻断短路，同时刻意加固键（secret/external-controller）不得算作漂移。
add_suite applydrift-tests \
  "$ROOT/Sources/Model/ConfigWriteAudit.swift" \
  "$ROOT/Tests/ApplyDrift/main.swift"

# 规则编辑器引擎：值内 `#` 是数据而非注释（旧版截断导致保存即删规则）。
add_suite yamlruleengine-tests \
  "$ROOT/Sources/Model/RuleNode.swift" \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Sources/Core/Hash.swift" \
  "$ROOT/Sources/Model/TailscaleNode.swift" \
  "$ROOT/Sources/Core/YamlEditor/YamlRuleASTEngine.swift" \
  "$ROOT/Tests/YamlRuleEngine/main.swift"

# App 内存警卫：阈值分档与限频。钉住 350MB 必须触发——旧版阈值在实测占用
# 平台期上方，等于从不运行，而构建无从发现。
add_suite appmemoryguard-tests \
  "$ROOT/Sources/Model/AppMemoryGuard.swift" \
  "$ROOT/Tests/AppMemoryGuard/main.swift"

# 内核内存：静默连接判死 + 基于真实 RSS 的分级看门狗。钉住 2026-09-28 六天
# 待机事故（1039 条 TCP 尸体合计只走 1.2MB、RSS 426MB vs 健康 145MB），并钉住
# 误杀边界：5 分钟与 29 分钟心跳的活连接、arm 后新建、grace 未满都不得回收。
add_suite kernelmemoryguard-tests \
  "$ROOT/Sources/Model/KernelMemoryGuard.swift" \
  "$ROOT/Tests/KernelMemoryGuard/main.swift"

# 共存条目归属：只认领真正新增的排除项，不得撤回用户手写条目。
add_suite coexprovenance-tests \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Sources/Model/CoexistenceProvenance.swift" \
  "$ROOT/Tests/CoexistenceProvenance/main.swift"

# Tailscale 覆盖网段与节点解析。
add_suite tailscale-tests \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Sources/Core/Hash.swift" \
  "$ROOT/Sources/Model/TailscaleNode.swift" \
  "$ROOT/Tests/TailscaleOverlay/main.swift"

# Keychain 持久化：ad-hoc 重签 / 重装后 Tailscale key 与订阅 URL 不得丢失。
# 镜像目录 + 开放 ACL 是修复的两半；本套钉住镜像恢复路径（单元测试无法伪造
# 第二个 code-signing identity，所以 Keychain ACL 半边靠代码审阅保证）。
add_suite keychain-tests \
  "$ROOT/Sources/Core/Hash.swift" \
  "$ROOT/Sources/Model/KeychainHelper.swift" \
  "$ROOT/Tests/KeychainHelper/main.swift"

# Tailscale API 设备列表解码 + 延迟测试语义分类。对等节点（无 exit-node）
# 不得参与公网 URL 测速，否则会被永久标红。
add_suite tailscale-api-tests \
  "$ROOT/Sources/Model/TailscaleAPI.swift" \
  "$ROOT/Tests/TailscaleAPI/main.swift"

# 系统代理子系统：服务/设备配对解析（分支顺序回归）、目标服务选择（活性过滤
# + 虚拟服务排除 + 无 2 服务上限 + 回退）、三态结果分类、-get*proxy 读回解析、
# bypass 单一来源网段。生产源码即 Helper 与 GUI fallback 共用的
# ProxyServicePlan（HelperProtocol.swift）。
add_suite systemproxy-tests \
  "$ROOT/Sources/XPC/HelperProtocol.swift" \
  "$ROOT/Tests/SystemProxy/main.swift"

# 连接来源判定：TUN 下 sourceIP 恒为 fake-ip 网关 198.18.0.0（实测 98 条中 96 条），
# 只看源地址会把本机与局域网设备混为一谈；inboundName 为空的老连接必须落到
# 「未知来源」而不是空白。纯逻辑半边，供连接详情四段式卡片使用。
add_suite connorigin-tests \
  "$ROOT/Sources/Model/ConnOrigin.swift" \
  "$ROOT/Tests/ConnOrigin/main.swift"

# 订阅协议分布：订阅卡「VLESS 61 · HYSTERIA2 25 · SS 2」的口径。分项之和必须等于
# 节点数（不能与卡上「N 节点」自相矛盾），折叠打的是协议种类数不是节点数，
# proxies 为 nil/空时不得产出「0」这种看起来像订阅坏了的文案。
add_suite providerprotocols-tests \
  "$ROOT/Sources/Model/ProviderProtocols.swift" \
  "$ROOT/Tests/ProviderProtocols/main.swift"

# 连接页「一键独立制裁」的规则决策：这一键直接改用户 config.yaml。钉住
# 「裸 IP 必须写 IP-CIDR 而不是 IP-CIDR6、fake-ip 用 remoteDestination 兜底、
# 目标不明时置灰、指向不存在策略组时拒绝、已有等价规则不重复写盘」。
add_suite quickrule-tests \
  "$ROOT/Sources/Model/RuleNode.swift" \
  "$ROOT/Sources/Model/QuickRule.swift" \
  "$ROOT/Tests/QuickRule/main.swift"

# 设备身份：arp 行解析（去前导零 / incomplete 跳过）、OUI 厂商表完整性
# （每键 6 位 hex、无重复键——重复键在字典字面量里会运行时崩溃）、
# 类型只来自厂商白名单或端口指纹且必须标注「推测」。
add_suite deviceidentity-tests \
  "$ROOT/Sources/Model/DeviceIdentity.swift" \
  "$ROOT/Tests/DeviceIdentity/main.swift"

# 入站端口转发：这一块是**直接暴露到网络的监听端口**。钉住 2026-10-20 实测的三条
# 内核行为——不写 `listen:` 会绑 `*`（全网卡）、`bind-address` 对 listener 无效、
# `network` 必须是数组；以及替换块只动 listeners、内联写法交调用方报错。
add_suite inboundlistener-tests \
  "$ROOT/Sources/Model/InboundListener.swift" \
  "$ROOT/Tests/InboundListener/main.swift"

# 订阅引用统计：`use:` 的块状/内联两种写法（真实 config.yaml 两种都在用）、
# 只统计 proxy-groups 块、重复项去重。订阅卡据此显示「被 N 个策略组引用」，
# N=0 时警示「节点不会出现在代理节点页」。
add_suite providerusage-tests \
  "$ROOT/Sources/Model/ProviderUsage.swift" \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Tests/ProviderUsage/main.swift"

# 空组预检：删除订阅后只靠它供血的策略组会变成空 select，mihomo -t 的英文
# 语法错掩盖真正原因。钉住 groupsMissingMembers 的口径：proxies/use 任一有
# 非空条目即有来源；内联与块状两种写法都认；组外与注释不算。
add_suite emptygroup-tests \
  "$ROOT/Sources/Model/ProviderUsage.swift" \
  "$ROOT/Sources/Core/YamlEditor/YamlScalar.swift" \
  "$ROOT/Tests/ProviderEmptyGroup/main.swift"

# 规则表单保存前的存在性校验：规则指向已被删除的策略组/节点时，内核 reload 会拒绝
# 整份配置、事务回滚，用户只看到一条英文报错。这里钉住三件事：存在则放行、不存在则
# 中文拦住并带上原目标名、**拿不到配置（内核未运行 → 空集合）时必须放行**——把
# 「没有数据」当成「所有目标都失效」会让用户连改都改不了。
add_suite rulevalidator-tests \
  "$ROOT/Sources/Model/RuleNode.swift" \
  "$ROOT/Sources/Core/RuleValidator/RuleValidator.swift" \
  "$ROOT/Tests/RuleValidator/main.swift"

# ── 执行 ───────────────────────────────────────────────────────────────

FILTER=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) FILTER="${2:-}"; shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    -h|--help) sed -n '1,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

if [ "$LIST_ONLY" = 1 ]; then
  for entry in "${SUITES[@]}"; do
    echo "${entry%%::*}"
  done
  exit 0
fi

pass=0; fail=0; miss=0
declare -a RESULTS=()

for entry in "${SUITES[@]}"; do
  name="${entry%%::*}"
  files="${entry#*:::}"
  [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) continue ;; esac

  # 缺文件与测试失败必须分开报：前者是环境没装好，后者才是产品坏了。
  missing=""
  for f in $files; do
    [ -f "$f" ] || missing="$missing ${f#$ROOT/}"
  done
  if [ -n "$missing" ]; then
    miss=$((miss+1))
    RESULTS+=("MISS    $name  缺:$missing")
    printf "%-24s %-8s %s\n" "$name" "MISSING" "缺文件:${missing}"
    continue
  fi

  if ! xcrun swiftc -O $files -o "$OUT/$name" 2>"$OUT/$name.err"; then
    fail=$((fail+1))
    reason="$(grep -m1 'error:' "$OUT/$name.err" | sed 's/.*error: //' | cut -c1-70)"
    RESULTS+=("COMPILE $name  $reason")
    printf "%-24s %-8s %s\n" "$name" "COMPILE-ERROR" "$reason"
    continue
  fi

  if "$OUT/$name" >"$OUT/$name.out" 2>&1; then
    n=$(grep -c '✓' "$OUT/$name.out")
    pass=$((pass+1))
    RESULTS+=("PASS    $name  ${n} 断言")
    printf "%-24s %-8s %s\n" "$name" "PASS" "${n} 断言"
  else
    fail=$((fail+1))
    detail="$(grep -E '^失败|[0-9]+ 项失败|^✗' "$OUT/$name.out" | tail -1)"
    RESULTS+=("FAIL    $name  $detail")
    printf "%-24s %-8s %s\n" "$name" "FAIL" "$detail"
    echo "   ── 失败上下文（末 12 行）──"
    grep -E '✗' "$OUT/$name.out" | head -12 | sed 's/^/   /'
  fi
done

echo ""
echo "════════════════════════════════════════════════"
printf "回归汇总：PASS %d   FAIL %d   MISSING %d\n" "$pass" "$fail" "$miss"
if [ "$miss" -gt 0 ]; then
  echo ""
  echo "有套件的测试文件不在工作区。Tests/ 自 291a239 起不入库，"
  echo "新克隆的仓库需要先物化："
  echo "    bash Scripts/restore-tests.sh"
fi
if [ "$fail" -eq 0 ] && [ "$miss" -eq 0 ]; then
  echo "全部通过。"
  exit 0
fi
echo "存在未通过或缺失的套件。"
exit 1
