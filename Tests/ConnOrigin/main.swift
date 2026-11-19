// Tests/ConnOrigin —— 直接编译生产源码 Sources/Model/ConnOrigin.swift。
// 钉住连接「来源」判定的三条口径：
//   1. TUN 下 sourceIP 恒为 fake-ip 网关 198.18.0.0（2026-10-20 实测 98 条中 96 条），
//      它必须判成本机，绝不能因为「不是环回」就判成局域网或外部；
//   2. inboundName 为空的老连接必须显示「未知来源」而不是空白；
//   3. 局域网设备（真实私有地址）与对外开放端口上的公网对端要分得开。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

let localIPs: Set<String> = ["192.168.31.10", "10.10.0.5"]

// ── 1. TUN 入站：fake-ip 源 = 本机进程 ─────────────────────────────────
print("== TUN：sourceIP=198.18.0.0（fake-ip 网关）必须判本机 ==")
let tunLocal = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-TUN", inboundPort: "55677",
    sourceIP: "198.18.0.0", localIPs: localIPs)
check(tunLocal.kind == .local, "kind = local")
check(tunLocal.peer.isEmpty, "本机不带对端地址")
check(tunLocal.title(process: "Aside Helper") == "本机 · Aside Helper", "标题含进程名")
check(tunLocal.subtitle(sourceIP: "198.18.0.0") == "TUN 入站",
      "副标题是入站证据；TUN 的 inboundPort 是每条连接的源端口(55677)，不是监听端口，不得拼出（\(tunLocal.subtitle(sourceIP: "198.18.0.0"))）")
check(tunLocal.title(process: "—") == "本机 · 未知进程", "进程缺失时不留空")

// ── 2. TUN 入站 + 局域网真实地址 = 局域网设备（网关模式） ──────────────
print("== TUN + 192.168.1.33（非本机网卡）必须判局域网 ==")
let tunLan = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-TUN", inboundPort: "0",
    sourceIP: "192.168.1.33", localIPs: localIPs)
check(tunLan.kind == .lan, "kind = lan")
check(tunLan.peer == "192.168.1.33", "对端地址透传")
check(tunLan.title(process: "?") == "局域网 · 192.168.1.33", "标题用 IP 而不是进程")
check(tunLan.subtitle(sourceIP: "192.168.1.33") == "TUN 入站",
      "端口 0 不得作为真实端口展示（\(tunLan.subtitle(sourceIP: "192.168.1.33"))）")

// ── 3. 混合端口：本机应用 / 局域网设备 / 公网对端 ─────────────────────
print("== 混合端口：环回→本机、私有→局域网、公网→外部 ==")
let mixedLocal = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-MIXED", inboundPort: "7890",
    sourceIP: "127.0.0.1", localIPs: localIPs)
check(mixedLocal.kind == .local, "127.0.0.1 → 本机")
check(mixedLocal.subtitle(sourceIP: "127.0.0.1") == "混合端口 7890",
      "入站带真实监听端口（\(mixedLocal.subtitle(sourceIP: "127.0.0.1"))）")

let mixedLan = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-MIXED", inboundPort: "7890",
    sourceIP: "192.168.31.44", localIPs: localIPs)
check(mixedLan.kind == .lan, "局域网地址 → 局域网")
check(mixedLan.peer == "192.168.31.44", "对端地址正确")

let mixedPublic = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-MIXED", inboundPort: "7890",
    sourceIP: "1.2.3.4", localIPs: localIPs)
check(mixedPublic.kind == .external, "公网地址 → 外部")
check(mixedPublic.title(process: "curl") == "外部 · 1.2.3.4", "外部标题不回显进程")

// 本机网卡地址（含非环回）同样算本机：系统代理指向本机 LAN IP 时会出现
let ownIface = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-MIXED", inboundPort: "7890",
    sourceIP: "192.168.31.10", localIPs: localIPs)
check(ownIface.kind == .local, "本机网卡地址 → 本机（不是局域网设备）")

// ── 4. 老连接 / 内部连接：inboundName 与 sourceIP 都空 ────────────────
print("== 空证据不得留空，必须说未知来源 ==")
let nothing = ConnOriginClassifier.classify(
    inboundName: "", inboundPort: "", sourceIP: "", localIPs: localIPs)
check(nothing.kind == .unknown, "kind = unknown")
check(nothing.title(process: "curl") == "未知来源", "标题 = 未知来源")
check(nothing.subtitle(sourceIP: "") == "内核未提供入站信息", "副标题说明原因")

// 入站缺失但有源地址：归属仍可判，副标题补证据
let noInboundLan = ConnOriginClassifier.classify(
    inboundName: nil, inboundPort: nil, sourceIP: "10.10.0.9", localIPs: localIPs)
check(noInboundLan.kind == .lan, "无入站名但有私有源地址 → 局域网")
check(noInboundLan.title(process: "x") == "局域网 · 10.10.0.9", "标题已带对端地址")
check(noInboundLan.subtitle(sourceIP: "10.10.0.9") == "内核未提供入站信息",
      "副标题不重复标题里已有的地址，只说明缺什么")

let noInboundFake = ConnOriginClassifier.classify(
    inboundName: nil, inboundPort: nil, sourceIP: "198.19.3.7", localIPs: localIPs)
check(noInboundFake.kind == .local, "198.19/16 同属 fake-ip 段 → 本机")
check(noInboundFake.subtitle(sourceIP: "198.19.3.7") == "内核未提供入站信息",
      "fake-ip 地址不作为对端展示")

// ── 5. 入站名归一化 ──────────────────────────────────────────────────
print("== 入站名归一化 ==")
check(ConnOriginClassifier.normalizeInbound("DEFAULT-TUN", port: nil) == "TUN 入站", "DEFAULT-TUN")
check(ConnOriginClassifier.normalizeInbound("default-socks", port: nil) == "SOCKS 端口", "大小写不敏感")
check(ConnOriginClassifier.normalizeInbound("fwd-test", port: "18080") == "fwd-test",
      "自定义 listener 名原样保留（不加端口，避免误导）")
check(ConnOriginClassifier.normalizeInbound("", port: "1") == "", "空串保持空")
check(ConnOriginClassifier.normalizeInbound(nil, port: nil) == "", "nil 保持空")
check(ConnOriginClassifier.normalizeInbound("DEFAULT-HTTP", port: "0") == "HTTP 端口", "端口 0 不拼接")
check(ConnOriginClassifier.normalizeInbound("DEFAULT-TUN", port: "55677") == "TUN 入站",
      "TUN 源端口不得当作监听端口展示")

// ── 6. 地址分类边界 ──────────────────────────────────────────────────
print("== 地址分类边界 ==")
check(ConnOriginClassifier.isFakeIP("198.18.0.0") && ConnOriginClassifier.isFakeIP("198.19.255.254"),
      "198.18/15 两段都是 fake-ip")
check(!ConnOriginClassifier.isFakeIP("198.20.0.0"), "198.20 不是 fake-ip")
check(!ConnOriginClassifier.isFakeIP("198.18"), "残缺地址不当 fake-ip")
check(ConnOriginClassifier.isLoopback("127.0.0.1") && ConnOriginClassifier.isLoopback("::1"),
      "环回含 IPv6")
check(!ConnOriginClassifier.isLoopback("0.0.0.0"), "0.0.0.0 不是环回（是任意地址占位）")
let anyAddr = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-MIXED", inboundPort: "7890", sourceIP: "0.0.0.0", localIPs: localIPs)
check(anyAddr.kind == .unknown, "0.0.0.0 源地址 → 未知来源，不冒充本机/局域网")
check(ConnOriginClassifier.isPrivate("10.255.0.1") && ConnOriginClassifier.isPrivate("172.16.0.1")
      && ConnOriginClassifier.isPrivate("172.31.255.255") && ConnOriginClassifier.isPrivate("192.168.0.1")
      && ConnOriginClassifier.isPrivate("169.254.1.1"), "IPv4 私有/链路本地")
check(!ConnOriginClassifier.isPrivate("172.32.0.1") && !ConnOriginClassifier.isPrivate("8.8.8.8"),
      "172.32 与公网不算私有")
check(ConnOriginClassifier.isPrivate("fe80::1") && ConnOriginClassifier.isPrivate("fd00::1"),
      "IPv6 链路本地/ULA")

// v6 fake-ip：内核二进制默认 fdfe:dcba:9876::1/126。它落在 fc00::/7 里，
// 若只靠 isPrivate 会被判成「局域网设备」——那是别人的设备地址，不是本机进程。
print("== IPv6 fake-ip 默认段 ==")
let v6fake = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-TUN", inboundPort: "0",
    sourceIP: "fdfe:dcba:9876::2", localIPs: localIPs)
check(ConnOriginClassifier.isFakeIP("fdfe:dcba:9876::2"), "v6 默认 fake 段被识别")
check(v6fake.kind == .local, "v6 fake 源地址 → 本机（不是局域网）")
check(v6fake.subtitle(sourceIP: "fdfe:dcba:9876::2") == "TUN 入站",
      "v6 fake 地址不作为对端展示")
check(!ConnOriginClassifier.isFakeIP("fdfe:dcba:9877::2"), "相邻段不算 fake")
check(!ConnOriginClassifier.isFakeIP("2001:db8::1"), "公网 v6 不算 fake")
check(!ConnOriginClassifier.isPrivate("2001:db8::1"), "IPv6 公网不算私有")

let v6loop = ConnOriginClassifier.classify(
    inboundName: "DEFAULT-MIXED", inboundPort: "7890", sourceIP: "::1", localIPs: localIPs)
check(v6loop.kind == .local, "IPv6 环回 → 本机")

// ── 表格「来源」列的短标签 ────────────────────────────────────────────
// 列窄，本机不重复进程名（进程有自己那列）；局域网/外部要保留对端地址——
// 那是这一列唯一有用的信息。
print("== 短标签 ==")
check(tunLocal.shortLabel == "本机", "本机短标签不带进程名")
check(tunLan.shortLabel == "局域网 · 192.168.1.33", "局域网短标签带 IP")
check(mixedPublic.shortLabel == "外部 · 1.2.3.4", "外部短标签带 IP")
check(nothing.shortLabel == "未知", "未知来源短标签不编造")

print("")
if failures == 0 { print("ConnOrigin: 全部通过"); exit(0) }
print("ConnOrigin: \(failures) 处失败"); exit(1)
