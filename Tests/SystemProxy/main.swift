import Foundation

// 系统代理回归：直接编译生产源码 Sources/XPC/HelperProtocol.swift（共享
// ProxyServicePlan），不复制规则。钉住的故障形态来自综合审查结论：
//   1) activeNetworkServices 分支顺序错误——"(Hardware Port:" 同样以 "("
//      开头，先匹配通用前缀会让硬件端口分支不可达，服务与设备永远配不上
//      对，选服务退化到全量启用列表（开关显示成功、浏览器仍直连）；
//   2) Helper 与 GUI fallback 各自枚举——同一操作在 Helper 可用/不可用时
//      写入范围不同；
//   3) anyOK 语义——一个服务成功就返回 true，部分成功被当成完全成功；
//   4) 2 服务上限——以太网/USB 网卡等上联不被配置。

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

// 真实 `networksetup -listnetworkserviceorder` 输出形态（含禁用服务尾注）。
let orderOutput = """
(1) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(2) Ethernet Adapter (en5)
(Hardware Port: USB 10/100/1000 LAN, Device: en5)

(3) Tailscale Tunnel
(Hardware Port: Tailscale Tunnel, Device: utun8)

(4) iPhone USB
(Hardware Port: iPhone USB, Device: en7)

An asterisk (*) denotes that a network service is disabled.
(*) Bluetooth PAN
(Hardware Port: Bluetooth PAN, Device: en6)
"""

let listOutput = """
An asterisk (*) denotes that a network service is disabled.
Wi-Fi
Ethernet Adapter (en5)
Tailscale Tunnel
*Bluetooth PAN
iPhone USB
"""

section("serviceDevicePairs — 分支顺序回归（硬件端口行先于通用前缀）")
let pairs = ProxyServicePlan.serviceDevicePairs(orderOutput: orderOutput)
expect(pairs.count == 4, "解析出 4 对服务/设备（实得 \(pairs.count)：\(pairs)）")
expect(pairs.contains { $0.service == "Wi-Fi" && $0.device == "en0" }, "Wi-Fi ↔ en0 配对成功")
expect(pairs.contains { $0.service == "Ethernet Adapter (en5)" && $0.device == "en5" }, "USB 网卡服务 ↔ en5 配对成功")
expect(pairs.contains { $0.service == "iPhone USB" && $0.device == "en7" }, "iPhone USB ↔ en7 配对成功")
// 禁用服务 "(*)" 括号后无名字 → 其硬件端口行必须被吸收，不得产生配对。
expect(!pairs.contains { $0.service.contains("Bluetooth") }, "禁用的 Bluetooth PAN 不产生配对")
// 旧 bug 的直接回归形态：若通用 "(" 分支先吞掉硬件端口行，配对数必为 0。
expect(!pairs.isEmpty, "配对非空（分支顺序错误时恒为 0）")
// 设备名提取必须取 "Device:" 之后、行尾 ")" 之前，不吃进尾括号。
expect(pairs.first(where: { $0.service == "Wi-Fi" })?.device.hasSuffix(")") == false, "设备名不带尾括号")

section("serviceDevicePairs — 边界输入")
expect(ProxyServicePlan.serviceDevicePairs(orderOutput: "").isEmpty, "空输出 → 空配对")
// 硬件端口行出现在任何服务行之前（畸形输入）不得崩溃或伪造配对。
expect(ProxyServicePlan.serviceDevicePairs(orderOutput: "(Hardware Port: Wi-Fi, Device: en0)").isEmpty,
       "孤立硬件端口行被丢弃")
// 无 Device 字段的硬件端口行（如 Thunderbolt Bridge 桥接）不产生配对。
let bridge = "(1) Thunderbolt Bridge\n(Hardware Port: Thunderbolt Bridge, Device: bridge0)\n"
expect(ProxyServicePlan.serviceDevicePairs(orderOutput: bridge).first?.device == "bridge0",
       "bridge0 设备照常配对（活性由 deviceActive 决定）")

section("enabledServices — 全量启用列表解析")
let enabled = ProxyServicePlan.enabledServices(listOutput: listOutput)
expect(enabled == ["Wi-Fi", "Ethernet Adapter (en5)", "Tailscale Tunnel", "iPhone USB"],
       "跳过表头与 * 禁用项（实得 \(enabled)）")

section("targetServices — 活性过滤 + 虚拟服务排除 + 无 2 服务上限")
let active = ProxyServicePlan.targetServices(
    orderOutput: orderOutput, listOutput: listOutput,
    deviceActive: { $0 == "en0" || $0 == "en5" || $0 == "en7" })
expect(active.count == 3, "三个活跃物理服务全部入选，无 2 服务上限（实得 \(active.count)：\(active)）")
expect(!active.contains("Tailscale Tunnel"), "虚拟/VPN 服务名（utun/tailscale）被排除")
expect(active.first == "Wi-Fi", "Wi-Fi/Ethernet 排序靠前（实得首位 \(active.first ?? "nil")）")

let wifiOnly = ProxyServicePlan.targetServices(
    orderOutput: orderOutput, listOutput: listOutput, deviceActive: { $0 == "en0" })
expect(wifiOnly == ["Wi-Fi"], "仅 en0 活跃 → 只选 Wi-Fi（实得 \(wifiOnly)）")

let tunActive = ProxyServicePlan.targetServices(
    orderOutput: orderOutput, listOutput: listOutput, deviceActive: { $0 == "utun8" })
// 唯一“活跃”设备是虚拟隧道 → 名单过滤后活跃集合为空 → 按设计回退到
// 启用列表（宁可全覆盖也不能返回空集）；物理服务入选，虚拟服务仍排除。
expect(!tunActive.contains("Tailscale Tunnel") && !tunActive.isEmpty,
       "仅 utun 活跃时回退启用列表且虚拟服务仍被名字过滤（实得 \(tunActive)）")

section("targetServices — 活性探测全空时回退启用列表")
let fallback = ProxyServicePlan.targetServices(
    orderOutput: orderOutput, listOutput: listOutput, deviceActive: { _ in false })
expect(fallback.contains("Wi-Fi") && fallback.contains("iPhone USB"), "回退到启用列表")
expect(!fallback.contains("Tailscale Tunnel") && !fallback.contains("Bluetooth PAN"),
       "回退路径同样过滤虚拟与禁用服务（实得 \(fallback)）")

section("parseGetProxyOutput — -get*proxy 读回解析")
let getOn = """
Enabled: Yes
Server: 127.0.0.1
Port: 7897
Authenticated Proxy Enabled: 0
"""
let parsedOn = ProxyServicePlan.parseGetProxyOutput(getOn)
expect(parsedOn.enabled && parsedOn.host == "127.0.0.1" && parsedOn.port == 7897,
       "开启态三元组解析正确")
let getOff = """
Enabled: No
Server: 127.0.0.1
Port: 7897
"""
let parsedOff = ProxyServicePlan.parseGetProxyOutput(getOff)
expect(!parsedOff.enabled, "Enabled: No → false（host/port 仍在但不算开启）")
let parsedEmpty = ProxyServicePlan.parseGetProxyOutput("")
expect(!parsedEmpty.enabled && parsedEmpty.host == nil && parsedEmpty.port == nil, "空输出 → 全空")

section("classify — 全部/部分/全部失败三态")
expect(ProxyServicePlan.classify(succeeded: ["Wi-Fi", "Ethernet"], failed: []) == .full,
       "全部成功 → .full")
expect(ProxyServicePlan.classify(succeeded: ["Wi-Fi", "Ethernet"], failed: []).isSuccess,
       ".full → isSuccess == true")
expect(ProxyServicePlan.classify(succeeded: ["Wi-Fi"], failed: ["Ethernet"]) == .partial(ok: ["Wi-Fi"], failed: ["Ethernet"]),
       "部分成功 → .partial(ok:failed:)（旧 anyOK 语义会当成功上报）")
expect(!ProxyServicePlan.classify(succeeded: ["Wi-Fi"], failed: ["Ethernet"]).isSuccess,
       ".partial → isSuccess == false（不得上报为成功）")
expect(ProxyServicePlan.classify(succeeded: [], failed: ["Wi-Fi", "Ethernet"]) == .failed,
       "全部失败 → .failed")
expect(!ProxyServicePlan.classify(succeeded: [], failed: []).isSuccess,
       "空集 → 非成功（无服务即失败）")

section("kProxyBypassDomains — 单一来源必备网段")
expect(kProxyBypassDomains.contains("localhost") && kProxyBypassDomains.contains("127.0.0.1"),
       "含 localhost/回环")
expect(kProxyBypassDomains.contains("*.local"), "含 mDNS *.local")
expect(kProxyBypassDomains.contains("10.*") && kProxyBypassDomains.contains("192.168.*")
        && kProxyBypassDomains.contains("172.16.*") && kProxyBypassDomains.contains("172.31.*"),
       "RFC1918 私有网段全覆盖")
expect(kProxyBypassDomains.contains("169.254.*"), "链路本地 169.254.*")
expect(kProxyBypassDomains.contains("100.64.*") && kProxyBypassDomains.contains("100.127.*"),
       "CGNAT 100.64.0.0/10 全覆盖")
expect(kProxyBypassDomains.contains("*.tailscale.com"), "Tailscale 控制面绕行")
expect(kProxyBypassDomains.count > 80, "总量 ≈86 条（实得 \(kProxyBypassDomains.count)）")

section("skipSubstrings — 虚拟服务名单")
for name in ["Shadowrocket", "WireGuard", "Tailscale Tunnel", "ZeroTier One", "Oray", "utun", "IPSec VPN", "OpenVPN"] {
    expect(ProxyServicePlan.isSkippableService(name), "“\(name)” 被排除")
}
expect(!ProxyServicePlan.isSkippableService("Wi-Fi"), "Wi-Fi 不被排除")
expect(!ProxyServicePlan.isSkippableService("USB 10/100/1000 LAN"), "USB 物理网卡不被排除")

print("")
if failures > 0 {
    print("✗ \(failures)/\(checks) 项失败")
    exit(1)
}
print("全部 \(checks) 项通过。")
