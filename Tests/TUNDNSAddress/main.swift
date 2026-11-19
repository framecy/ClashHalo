// TUN 系统 DNS 网关换算回归：钉住 2026-10-09「一开 TUN 就完全断网」的语义。
//
// 事故：系统 DNS 被写成 198.18.0.0 —— `198.18.0.0/30` 的网络地址（主机位全 0），
// 内核永不应答。TUN 开着时靠 dns-hijack 硬兜住，TUN 一抖/一关就全网解析黑洞。
// 这套钉两件事：网关必须是前缀里的**主机**地址；fake-ip 残留必须能被识别。
import Foundation

var failed = 0
var total = 0
func check(_ cond: Bool, _ name: String) {
    total += 1
    print(cond ? "  ✓ \(name)" : "  ✗ FAIL: \(name)")
    if !cond { failed += 1 }
}
func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    total += 1
    if got == want {
        print("  ✓ \(name)")
    } else {
        print("  ✗ FAIL: \(name) — got \(got), want \(want)")
        failed += 1
    }
}

print("── firstHostAddress：网络地址 ≠ 网关 ──")

// 事故本体：mihomo 默认 fake-ip 段，配置里的 inet4-address 就是 198.18.0.0/30。
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/30"), "198.18.0.1",
        "/30 的网络地址 198.18.0.0 → 网关 198.18.0.1（事故本体）")
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/30") != "198.18.0.0",
      "绝不返回 /30 的网络地址 .0（那正是断网根因）")

print("── firstHostAddress：各前缀长度 ──")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/24"), "198.18.0.1",
        "/24 网络地址 +1")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "10.0.0.0/8"), "10.0.0.1",
        "/8 网络地址 +1")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "192.168.1.128/25"), "192.168.1.129",
        "/25 非零网络地址 → 129（不是 192.168.1.129 之外的推断值）")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "172.16.5.0/29"), "172.16.5.1",
        "/29 网络地址 +1")
// 广播边界：/30 的可用主机只有 .1 和 .2，.3 是广播。确认不会算到 .3。
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/30") != "198.18.0.3",
      "/30 不会返回广播地址 .3")

print("── firstHostAddress：/31 与 /32 无网络/广播之分（RFC 3021）──")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/31"), "198.18.0.0",
        "/31 原样返回（两个地址都是主机，+1 会越界）")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.1/32"), "198.18.0.1",
        "/32 原样返回")

print("── firstHostAddress：裸地址原样返回 ──")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.1"), "198.18.0.1",
        "无前缀的裸地址不 +1（用户已指定具体地址）")
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "1.1.1.1"), "1.1.1.1",
        "裸公网地址原样返回")

print("── firstHostAddress：非法输入返回 nil ──")
// 空串与「只有前缀」会 split 出 0 / 1 个分量，parts[0] 直接越界 trap ——
// config 里的值是用户可编辑的文本，不是受检类型，必须在库里挡住。
check(TUNDNSAddress.firstHostAddress(inPrefix: "") == nil, "空串 → nil（不得越界崩溃）")
check(TUNDNSAddress.firstHostAddress(inPrefix: "/30") == nil, "只有前缀 → nil（不得越界崩溃）")
check(TUNDNSAddress.firstHostAddress(inPrefix: "/") == nil, "裸斜杠 → nil")
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/") == nil, "前缀为空 → nil")
check(TUNDNSAddress.firstHostAddress(inPrefix: "not-an-ip/30") == nil, "非 IP → nil")
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0/30") == nil, "三段 → nil")
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0.0/30") == nil, "五段 → nil")
check(TUNDNSAddress.firstHostAddress(inPrefix: "999.18.0.0/30") == nil, "越界 octet → nil")
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/33") == nil,
      "前缀 >32 → nil（绝不能回落到原地址：那会把网络地址 .0 当网关写进系统 DNS）")
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/x") == nil, "非数字前缀 → nil")
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/-1") == nil, "负前缀 → nil")
// 这条是上面那条的语义化重述：非法前缀必须「失败」而不是「降级成裸地址」。
check(TUNDNSAddress.firstHostAddress(inPrefix: "198.18.0.0/33") != "198.18.0.0",
      "非法前缀不会静默返回事故地址 .0")

print("── /0 边界（掩码为 0 时左移 32 位是 UB，必须有专门处理）──")
// UInt32(0) << 32 在 Swift 里会 trap；掩码为 0 时必须走特判而不是移位。
checkEq(TUNDNSAddress.firstHostAddress(inPrefix: "0.0.0.0/0"), "0.0.0.1",
        "/0 → 0.0.0.1（掩码 0 走特判，不移位）")

print("── gateway(fromInet4Addresses:)：兜底绝不返回黑洞地址 ──")
checkEq(TUNDNSAddress.gateway(fromInet4Addresses: ["198.18.0.0/30"]), "198.18.0.1",
        "事故配置 → 正确网关")
checkEq(TUNDNSAddress.gateway(fromInet4Addresses: []), "198.18.0.1",
        "空列表 → 默认 fake-ip 网关")
checkEq(TUNDNSAddress.gateway(fromInet4Addresses: ["garbage"]), "198.18.0.1",
        "不可解析 → 默认 fake-ip 网关（绝不写坏值）")
checkEq(TUNDNSAddress.gateway(fromInet4Addresses: ["198.18.0.0/30", "10.0.0.0/8"]), "198.18.0.1",
        "取第一个可用项")
// 兜底值本身必须是可应答的主机地址。
check(TUNDNSAddress.isFakeIPResolver(TUNDNSAddress.defaultFakeIPGateway),
      "默认兜底网关落在 fake-ip 段内（TUN 开启时由内核应答）")

print("── isFakeIPResolver：残留识别 ──")
check(TUNDNSAddress.isFakeIPResolver("198.18.0.0"), "198.18.0.0 是 fake-ip 残留（事故现场值）")
check(TUNDNSAddress.isFakeIPResolver("198.18.0.1"), "198.18.0.1 是 fake-ip 网段")
check(TUNDNSAddress.isFakeIPResolver("198.19.255.254"), "198.19.x.x 在 198.18.0.0/15 内")
check(!TUNDNSAddress.isFakeIPResolver("198.20.0.1"), "198.20.x.x 不在 /15 内 → 不动")
check(!TUNDNSAddress.isFakeIPResolver("192.168.0.6"), "正常 LAN DNS 不误伤")
check(!TUNDNSAddress.isFakeIPResolver("223.6.6.6"), "公共 DNS 不误伤")
check(!TUNDNSAddress.isFakeIPResolver("127.0.0.1"), "回环不误伤（proxy 模式会用到）")
check(!TUNDNSAddress.isFakeIPResolver("Empty"), "networksetup 的 Empty 哨兵不误判")
check(!TUNDNSAddress.isFakeIPResolver(""), "空串不误判")

print("── /15 边界逐位确认 ──")
check(TUNDNSAddress.isFakeIPResolver("198.18.0.0") && TUNDNSAddress.isFakeIPResolver("198.19.255.255"),
      "198.18.0.0/15 的首尾都在内")
check(!TUNDNSAddress.isFakeIPResolver("198.17.255.255") && !TUNDNSAddress.isFakeIPResolver("198.20.0.0"),
      "198.18.0.0/15 的紧邻两侧都在外")

print("── shouldRedirectSystemDNS：写入点不变量 ──")
// 事故现场：TUN 开着、接口在、地址合法，但 dns.enable=false。
// 系统 DNS 被写入 198.18.0.1，实测全网 SERVFAIL。
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: false, interfacePresent: true, gateway: "198.18.0.1"),
      "★ dns.enable=false 时拒绝写入（实测 SERVFAIL 全网故障的现场）")
check(TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.1"),
      "dns.enable=true 且接口在、地址合法 → 允许写入")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: false, gateway: "198.18.0.1"),
      "接口不存在 → 拒绝（第一道不变量）")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: false, interfacePresent: false, gateway: "198.18.0.0"),
      "前提同时不满足 → 拒绝")
// 兜底：网关不可解析时也拒绝，绝不落到「写个不可应答的地址」。
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: ""),
      "空网关 → 拒绝")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "not-an-ip"),
      "非法网关 → 拒绝")

print("── shouldRedirectSystemDNS：路由判据（取代被证伪的主机位判据） ──")
// 2026-10-09 实机：TUN 开启时 .0 与 .1 都 NOERROR、都 0% 丢包；TUN 关闭时
// 二者都 timed out。可达性来自 auto-route + dns-hijack，与主机位无关。
// 故 .0 不再因为「是网络地址」被拒 —— 只要它确实被路由进隧道。
check(TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.0",
                                            routedInterface: "utun100", tunnel: "utun100"),
      "★ .0 被路由进隧道 → 允许（旧代码因主机位而拒绝，属被证伪的判据）")
check(TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.1",
                                            routedInterface: "utun100", tunnel: "utun100"),
      "★ .1 被路由进隧道 → 允许")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.1",
                                             routedInterface: "en0", tunnel: "utun100"),
      "★ 网关走物理口而非隧道 → 拒绝（隧道掉线时写入即黑洞）")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.0",
                                             routedInterface: "en0", tunnel: "utun100"),
      "★ .0 走物理口 → 拒绝（实测 TUN 关闭后 .0 正是经 en0 默认路由）")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.1",
                                             routedInterface: nil, tunnel: "utun100"),
      "★ 查不到路由 → 拒绝（fail-closed）")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.1",
                                             routedInterface: "utun100", tunnel: nil),
      "★ 找不到自家隧道 → 拒绝")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: true, interfacePresent: true, gateway: "198.18.0.1",
                                             routedInterface: "utun9", tunnel: "utun100"),
      "★ 路由到别人的隧道 → 拒绝（身份必须精确相等）")
check(!TUNDNSAddress.shouldRedirectSystemDNS(dnsEnabled: false, interfacePresent: true, gateway: "198.18.0.1",
                                             routedInterface: "utun100", tunnel: "utun100"),
      "路由对但 dns.enable=false → 仍然拒绝（两道闸门都要过）")

print("── routedInto：身份判据 ──")
check(TUNDNSAddress.routedInto("utun100", tunnel: "utun100"), "同一接口 → true")
check(!TUNDNSAddress.routedInto("utun9", tunnel: "utun100"), "异接口 → false")
check(!TUNDNSAddress.routedInto(nil, tunnel: "utun100"), "无路由 → false")
check(!TUNDNSAddress.routedInto("utun100", tunnel: nil), "无隧道 → false")
check(!TUNDNSAddress.routedInto(nil, tunnel: nil), "双空 → false")

print("── isPlausibleIPv4 / isAnswerableHost：形状与语义分离 ──")
check(TUNDNSAddress.isPlausibleIPv4("198.18.0.0"), "★ .0 形状合法（语义上它也确实应答，见实测）")
check(TUNDNSAddress.isPlausibleIPv4("0.0.0.0") && TUNDNSAddress.isPlausibleIPv4("255.255.255.255"),
      "极值地址形状合法")
check(!TUNDNSAddress.isPlausibleIPv4("1.2.3") && !TUNDNSAddress.isPlausibleIPv4("1.2.3.256")
      && !TUNDNSAddress.isPlausibleIPv4("not-an-ip") && !TUNDNSAddress.isPlausibleIPv4(""),
      "段数不足/越界/非数字/空 → 形状非法")
// 保留的旧谓词：它编码的前提已被证伪，此处把证伪本身固化为断言，
// 防止后人再把 isAnswerableHost 当作可达性判据使用。
check(!TUNDNSAddress.isAnswerableHost("198.18.0.0"),
      "★ isAnswerableHost 拒绝 .0 —— 这正是它不该被用作可达性判据的原因（实测 .0 应答正常）")

print("── gateway(observed:fromInet4Addresses:)：观测优先 ──")
// 2026-10-09 实机现场：mihomo 无视 tun.inet4-address，内核把 utun100 绑在 .0，
// 而配置前缀 /30 换算出来是 .1 —— 两者必然背离。App 必须以观测到的接口地址为准。
check(TUNDNSAddress.gateway(observed: ["198.18.0.0"], fromInet4Addresses: ["198.18.0.0/30"]) == "198.18.0.0",
      "★ 接口实际持有 .0 时写 .0（实机现场：旧代码会算出 .1，与内核背离）")
check(TUNDNSAddress.gateway(observed: ["198.18.0.1"], fromInet4Addresses: ["198.18.0.0/30"]) == "198.18.0.1",
      "接口实际持有 .1 时写 .1")
check(TUNDNSAddress.gateway(observed: ["198.19.0.1"], fromInet4Addresses: ["198.18.0.0/30"]) == "198.19.0.1",
      "★ 接口实际持有 198.19.0.1 时写它，而非配置前缀算出的 198.18.0.1")
check(TUNDNSAddress.gateway(observed: ["10.0.0.5"], fromInet4Addresses: ["198.18.0.0/30"]) == "10.0.0.5",
      "任何观测到的地址都优先于配置（可达性由路由闸门负责把关）")
// 观测落空（接口还没起来 / getifaddrs 抓不到）才回落到前缀换算。
check(TUNDNSAddress.gateway(observed: [], fromInet4Addresses: ["198.18.0.0/30"]) == "198.18.0.1",
      "观测为空 → 回落到前缀换算 .1")
check(TUNDNSAddress.gateway(observed: [], fromInet4Addresses: []) == "198.18.0.1",
      "观测与配置都空 → 回落兜底网关")
check(TUNDNSAddress.gateway(observed: ["198.18.0.0", "198.18.0.1"], fromInet4Addresses: []) == "198.18.0.0",
      "★ 观测多个时取第一个（.0 不再被跳过）")
check(TUNDNSAddress.gateway(observed: ["not-an-ip"], fromInet4Addresses: ["198.18.0.0/30"]) == "198.18.0.1",
      "观测值形状非法 → 回落配置，绝不原样写出去")
check(TUNDNSAddress.gateway(observed: ["1.2.3"], fromInet4Addresses: []) == "198.18.0.1",
      "观测值段数不足 → 回落兜底")

print("── shouldSweepResidueOn(hasProvenance:isDefaultService:otherTunnelIsUp:)：残留清理门槛 ──")
// 2026-10-10：清理候选服务从「pinned + 默认」扩到全部服务后，必须有明确门槛。
// 旧判据 `!flagged && !pinned && service != services.last` 会永久跳过
// 「旧版本遗留、无标志、非默认接口」的残留 —— 正是清理逻辑存在的理由。
check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: true, isDefaultService: false, otherTunnelIsUp: false) == true,
      "★ 有来源证据 → 清理（我们写的我们自己收）")
check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: true, isDefaultService: false, otherTunnelIsUp: true) == true,
      "★ 有来源证据 + 共存代理在 → 仍清理（是我们的残留）")
check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: false, isDefaultService: true, otherTunnelIsUp: false) == true,
      "默认接口上的残留 → 清理（当前实际解析路径，黑洞即现成故障）")
check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: false, isDefaultService: true, otherTunnelIsUp: true) == true,
      "★ 默认接口 + 共存代理在 → 仍清理（旧版本遗留残留正落在这条路径）")
check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: false, isDefaultService: false, otherTunnelIsUp: false) == true,
      "★ 无证据、非默认、无共存隧道 → 清理（旧判据在此永久跳过，是本次修的盲区）")
check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: false, isDefaultService: false, otherTunnelIsUp: true) == false,
      "★ 无证据、非默认、有共存隧道 → 跳过（那一段可能确属他人）")

print("")
if failed == 0 {
    print("全部通过（\(total) 项）")
} else {
    print("失败 \(failed)/\(total) 项")
    exit(1)
}
