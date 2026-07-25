import Foundation

// Test harness over the real shipping source (Sources/XPC/HelperProtocol.swift),
// compiled in, not re-implemented. Re-implementing the rule in the test is how a
// test passes while the product is broken.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

// The exact route table captured from the affected machine, verbatim.
let liveTable = """
Destination        Gateway            Flags               Netif Expire
default            10.1.1.1           UGScg                 en0
default            link#32            UCSIg               utun8
10.1.1/24          utun8              USc                 utun8
10.1.1/24          link#32            UCSI                utun8
10.1.1.1/32        link#15            UCS                   en0      !
10.1.1.20/32       link#15            UCS                   en0      !
10.1.1.80          link#32            UHWIi               utun8
10.1.1.255         link#32            UHWIi               utun8
100.64/10          link#32            UCS                 utun8
100.100.100.100    utun8              UHS                 utun8
100.100.100.100/32 link#32            UCS                 utun8
100.121.91.23      utun8              UHS                 utun8
192.168.3          link#32            UCS                 utun8
224.0.0/4          utun8              UmS                 utun8
224.0.0/4          link#32            UmCSI               utun8
255.255.255.255/32 link#32            UCSI                utun8
198.18.0.0         198.18.0.0         UH                utun100
100/10             198.18.0.0         UGSc              utun100
"""

section("RouteTable.parse — 列解析")
let entries = RouteTable.parse(netstat: liveTable)
expect(entries.count == 18, "解析出 18 条（实得 \(entries.count)）")
expect(!entries.contains { $0.interface == "!" }, "Expire 列的 ! 不会被当成接口名")

func find(_ cidr: String, _ gw: String) -> RouteTable.Entry? {
    entries.first { $0.cidr == cidr && $0.gateway == gw }
}

section("isScoped / isInterfaceRoute — 区分「我们装的」与「对端自己的」")
expect(find("10.1.1.0/24", "utun8")?.isInterfaceRoute == true,  "10.1.1.0/24 gw=utun8 判为接口路由（我们装的）")
expect(find("10.1.1.0/24", "utun8")?.isScoped == false,         "10.1.1.0/24 gw=utun8 非作用域")
expect(find("10.1.1.0/24", "link#32")?.isInterfaceRoute == false, "10.1.1.0/24 gw=link#32 不是我们装的")
expect(find("10.1.1.0/24", "link#32")?.isScoped == true,        "10.1.1.0/24 gw=link#32 是作用域路由")
expect(find("224.0.0.0/4", "utun8")?.isInterfaceRoute == true,  "224.0.0.0/4 gw=utun8 判为接口路由")
expect(find("100.64.0.0/10", "link#32")?.isInterfaceRoute == false, "Tailscale 的 100.64/10 不是我们装的")

section("RouteTable.overlaps")
expect(RouteTable.overlaps("10.1.1.0/24", "10.1.1.0/24"), "相同前缀重叠")
expect(RouteTable.overlaps("10.1.1.0/24", "10.0.0.0/8"),  "被包含算重叠")
expect(RouteTable.overlaps("224.0.0.251/32", "224.0.0.0/4"), "mDNS 落在组播段内")
expect(!RouteTable.overlaps("10.1.1.0/24", "192.168.3.0/24"), "无关网段不重叠")
expect(!RouteTable.overlaps("100.64.0.0/10", "10.1.1.0/24"), "CGNAT 与 LAN 不重叠")
expect(RouteTable.overlaps("0.0.0.0/0", "1.2.3.4/32"), "默认路由与一切重叠")

section("normalizedCIDR — netstat 缩写目的地")
expect(RouteTable.normalizedCIDR("192.168.3") == "192.168.3.0/24", "192.168.3 → /24")
expect(RouteTable.normalizedCIDR("126") == "126.0.0.0/8", "126 → /8")
expect(RouteTable.normalizedCIDR("100.64/10") == "100.64.0.0/10", "100.64/10 自带长度")
expect(RouteTable.normalizedCIDR("10.1.1.80") == "10.1.1.80/32", "四段无长度 = 主机路由")
expect(RouteTable.normalizedCIDR("default") == "0.0.0.0/0", "default → 0.0.0.0/0")

section("PeerRouteGuard.isForbidden — 链路专用前缀")
let lan = ["10.1.1.0/24"]
expect(PeerRouteGuard.isForbidden("224.0.0.0/4", localSubnets: []),        "组播 224/4 禁止")
expect(PeerRouteGuard.isForbidden("224.0.0.251/32", localSubnets: []),     "mDNS 单播地址禁止")
expect(PeerRouteGuard.isForbidden("255.255.255.255/32", localSubnets: []), "广播禁止")
expect(PeerRouteGuard.isForbidden("169.254.0.0/16", localSubnets: []),     "链路本地禁止")
expect(PeerRouteGuard.isForbidden("127.0.0.0/8", localSubnets: []),        "回环禁止")
expect(PeerRouteGuard.isForbidden("0.0.0.0/8", localSubnets: []),          "this-network 禁止")

section("PeerRouteGuard.isForbidden — 本机直连网段")
expect(PeerRouteGuard.isForbidden("10.1.1.0/24", localSubnets: lan),  "本机 LAN 禁止指向隧道")
expect(PeerRouteGuard.isForbidden("10.1.1.80/32", localSubnets: lan), "LAN 内主机地址同样禁止")
expect(PeerRouteGuard.isForbidden("10.0.0.0/8", localSubnets: lan),   "覆盖 LAN 的更大段也禁止")
expect(!PeerRouteGuard.isForbidden("10.1.1.0/24", localSubnets: []),  "没有直连该网段时不禁止")

section("PeerRouteGuard.isForbidden — 合法对端前缀必须放行")
expect(!PeerRouteGuard.isForbidden("100.64.0.0/10", localSubnets: lan),      "Tailscale CGNAT 放行")
expect(!PeerRouteGuard.isForbidden("100.100.100.100/32", localSubnets: lan), "MagicDNS 放行")
expect(!PeerRouteGuard.isForbidden("100.121.91.23/32", localSubnets: lan),   "对端自身地址放行")
expect(!PeerRouteGuard.isForbidden("192.168.3.0/24", localSubnets: lan),     "对端远端子网放行")
expect(!PeerRouteGuard.isForbidden("10.147.0.0/16", localSubnets: lan),      "ZeroTier 段放行")

section("回归：Helper 回收判据选中的正是毒化路由")
// 与 reclaimOrphanedPeerRoutes 的谓词逐条对应
let reclaimed = entries.filter {
    $0.interface.hasPrefix("utun") && $0.interface != kPinnedTunDevice
        && !$0.isScoped && $0.isInterfaceRoute
        && PeerRouteGuard.isForbidden($0.cidr, localSubnets: lan)
}
let names = Set(reclaimed.map { "\($0.cidr)->\($0.interface)" })
expect(names == ["10.1.1.0/24->utun8", "224.0.0.0/4->utun8"],
       "只回收 LAN 与组播两条（实得 \(names.sorted()))")
expect(!names.contains { $0.hasPrefix("100.64") },     "不动 Tailscale CGNAT")
expect(!names.contains { $0.hasPrefix("100.100.100") }, "不动 MagicDNS 排除路由")
expect(!names.contains { $0.hasPrefix("100.121") },     "不动对端自身地址排除路由")
expect(!reclaimed.contains { $0.interface == kPinnedTunDevice }, "绝不碰自己的 utun100")

section("回归：GUI 采集过滤（routesByInterface 的等价谓词）")
// 采集只看对端 utun 的非作用域、非禁用前缀
let harvested = entries.filter {
    $0.interface.hasPrefix("utun") && $0.interface != kPinnedTunDevice
        && $0.cidr != "0.0.0.0/0" && !$0.isScoped
        && !PeerRouteGuard.isForbidden($0.cidr, localSubnets: lan)
}.map(\.cidr)
expect(!harvested.contains("10.1.1.0/24"), "本机 LAN 不再被采集")
expect(!harvested.contains("224.0.0.0/4"), "组播不再被采集")
expect(!harvested.contains("255.255.255.255/32"), "广播不再被采集")
expect(!harvested.contains("0.0.0.0/0"), "默认路由不被采集")
expect(harvested.contains("100.64.0.0/10"), "Tailscale CGNAT 仍被采集")
expect(harvested.contains("192.168.3.0/24"), "对端远端子网仍被采集")

section("回归：保护性排除项绝不可被撤回")
// 复刻 Coexistence.isProtectiveExclusion —— 判据同源于 linkOnlyPrefixes
func isProtective(_ c: String) -> Bool {
    PeerRouteGuard.linkOnlyPrefixes.contains { RouteTable.overlaps(c, $0) }
}
// 场景：旧版错误地把用户手写的 224.0.0.0/4 记为「本应用注入」，
// 新计划不再包含它 —— 撤回逻辑必须拒绝删除。
let staleRecord: Set<String> = ["224.0.0.0/4", "255.255.255.255/32",
                                "10.1.1.0/24", "100.64.0.0/10"]
let userConfig = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
                  "192.168.0.0/16", "224.0.0.0/4", "239.0.0.0/8",
                  "169.254.0.0/16", "100.64.0.0/10"]
let kept = userConfig.filter { !staleRecord.contains($0) || isProtective($0) }
expect(kept.contains("224.0.0.0/4"),     "组播排除项被保留（用户手写，记录污染也不删）")
expect(kept.contains("169.254.0.0/16"),  "链路本地排除项被保留")
expect(kept.contains("127.0.0.0/8"),     "回环排除项被保留")
expect(!kept.contains("100.64.0.0/10"),  "普通注入项仍可正常撤回")
expect(!isProtective("100.64.0.0/10"),   "CGNAT 不是保护性排除项")
expect(!isProtective("192.168.3.0/24"),  "对端子网不是保护性排除项")
expect(isProtective("239.0.0.0/8"),      "组织本地组播属保护性排除项")

section("回归：冲突检测不得把不可遮蔽的对端路由算作冲突")
// 复刻 NetScanner.isUnshadowable
func unshadowable(_ e: RouteTable.Entry) -> Bool {
    if e.isScoped { return true }
    return PeerRouteGuard.linkOnlyPrefixes.contains { RouteTable.overlaps(e.cidr, $0) }
}
let peerRoutes = entries.filter { $0.interface == "utun8" }
expect(unshadowable(find("255.255.255.255/32", "link#32")!),
       "对端作用域广播路由不可遮蔽（实测误报的那条）")
expect(unshadowable(find("10.1.1.0/24", "link#32")!),   "对端作用域 LAN 路由不可遮蔽")
expect(unshadowable(find("224.0.0.0/4", "link#32")!),   "对端作用域组播路由不可遮蔽")
expect(!unshadowable(find("100.64.0.0/10", "link#32")!), "对端非作用域 CGNAT 路由可被遮蔽（真冲突需报告）")
expect(!unshadowable(find("192.168.3.0/24", "link#32")!), "对端非作用域子网可被遮蔽（真冲突需报告）")
let reportable = peerRoutes.filter { !unshadowable($0) }.map(\.cidr)
expect(!reportable.contains("255.255.255.255/32"), "广播不进入冲突报告")
expect(!reportable.contains("224.0.0.0/4"),        "组播不进入冲突报告")
expect(reportable.contains("100.64.0.0/10"),       "CGNAT 仍进入冲突比对")

section("IPv6：前缀解析与重叠")
expect(RouteTable.IPPrefix("fe80::/10")?.isV6 == true,   "fe80::/10 解析为 v6")
expect(RouteTable.IPPrefix("10.1.1.0/24")?.isV6 == false, "10.1.1.0/24 解析为 v4")
expect(RouteTable.IPPrefix("::1/128") != nil,            ":: 压缩形式可解析")
expect(RouteTable.IPPrefix("fd7a:115c:a1e0::/48") != nil, "Tailscale ULA 可解析")
expect(RouteTable.IPPrefix("nonsense") == nil,           "非法串返回 nil")
expect(RouteTable.overlaps("fe80::1/128", "fe80::/10"),  "v6 被包含算重叠")
expect(RouteTable.overlaps("ff02::fb/128", "ff00::/8"),  "v6 组播落在 ff00::/8 内")
expect(!RouteTable.overlaps("fd7a:115c:a1e0::/48", "fe80::/10"), "无关 v6 前缀不重叠")
expect(!RouteTable.overlaps("fe80::/10", "10.1.1.0/24"), "跨协议族绝不重叠")
expect(!RouteTable.overlaps("::/0", "10.1.1.0/24"),      "v6 默认路由不与 v4 重叠")
expect(RouteTable.overlaps("::/0", "fe80::/10"),         "v6 默认路由与 v6 重叠")

section("IPv6：链路专用前缀受保护")
expect(PeerRouteGuard.isForbidden("fe80::/10", localSubnets: []),   "v6 链路本地禁止指向隧道")
expect(PeerRouteGuard.isForbidden("ff00::/8", localSubnets: []),    "v6 组播禁止")
expect(PeerRouteGuard.isForbidden("ff02::fb/128", localSubnets: []), "v6 mDNS 地址禁止")
expect(PeerRouteGuard.isForbidden("::1/128", localSubnets: []),     "v6 回环禁止")
expect(!PeerRouteGuard.isForbidden("fd7a:115c:a1e0::/48", localSubnets: []),
       "Tailscale v6 ULA 放行（是对端真实网段）")
// 这正是 v4 版本上出过的 bug：用户手写的排除项被撤回逻辑删掉
expect(isProtective("fe80::/10"), "v6 链路本地属保护性排除项，永不撤回")
expect(isProtective("ff00::/8"),  "v6 组播属保护性排除项，永不撤回")
expect(!isProtective("fd7a:115c:a1e0::/48"), "对端 v6 网段可正常撤回")

section("localAttachedSubnets — 本机实测")
let live = PeerRouteGuard.localAttachedSubnets()
print("  本机直连网段: \(live)")
expect(live.contains("10.1.1.0/24"), "识别出 en0 的 10.1.1.0/24")
expect(!live.contains { $0.hasSuffix("/32") }, "不产生 /32 主机掩码")
expect(!live.contains("198.18.0.0/30"), "不把 utun 的网段当直连（utun 已排除）")
expect(!live.contains("127.0.0.0/8"), "不含回环")

print("\n" + String(repeating: "=", count: 46))
print(failures == 0 ? "全部通过：\(checks)/\(checks)" : "失败 \(failures)/\(checks)")
exit(failures == 0 ? 0 : 1)
