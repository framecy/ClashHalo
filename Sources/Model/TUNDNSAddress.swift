import Foundation

/// TUN 系统 DNS 重定向的地址换算（纯逻辑：无 UI、无进程管理、无 MainActor，
/// 直接被 `Tests/TUNDNSAddress` 编译）。
///
/// 2026-10-09 断网事故：开 TUN 后系统 DNS 被写成 **198.18.0.0**，那是
/// `198.18.0.0/30` 的**网络地址**（主机位全 0），内核永远不会应答它。
/// 实测 `dig @198.18.0.0 www.baidu.com` → `connection timed out; no servers
/// could be reached`，`ping 198.18.0.0` → 100% 丢包，而隧道的 utun100 好好
/// 地在那儿。TUN 开着时靠 mihomo 的 dns-hijack（`any:53`）硬兜住，勉强能解析；
/// 一旦 TUN 抖动/关闭/内核重启，utun100 消失、198.18.0.0 无路由，系统解析
/// 立刻全黑洞 —— 表现为「一开 TUN 就完全断网」。
///
/// 根因是拿前缀当地址用：配置里的 `tun.inet4-address` 是**前缀**
/// （mihomo 默认 `198.18.0.0/30`），把 `/30` 切掉就当网关写进系统 DNS 是错的。
/// 该前缀里可应答的网关是**第一个主机地址**（`198.18.0.1`），也就是网络地址 + 1。
enum TUNDNSAddress {

    /// mihomo 默认的 fake-ip 网关，配置里没有可用前缀时兜底。
    static let defaultFakeIPGateway = "198.18.0.1"

    /// 取 IPv4 前缀的第一个可用（主机）地址：`198.18.0.0/30` → `198.18.0.1`。
    ///
    /// - 无前缀的裸地址（mihomo 也接受 `inet4-address: 198.18.0.1`）原样返回，
    ///   不做 +1 —— 那已经是用户指定的具体地址。
    /// - `/31` 与 `/32` 没有网络/广播之分（RFC 3021），每个地址都是主机，
    ///   同样原样返回。
    /// - 解析不出合法 IPv4 前缀时返回 nil，由调用方兜底。
    static func firstHostAddress(inPrefix raw: String) -> String? {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        // "" and "/30" both split to fewer than one component — indexing parts[0]
        // would trap, and a config value is user-editable text, not a checked type.
        guard let address = parts.first, !address.isEmpty else { return nil }
        let octets = address.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }

        // The presence of a prefix is decided by the SEPARATOR, not by the split
        // result: Swift's `split` drops empty subsequences, so "198.18.0.0/"
        // yields a single element and would otherwise masquerade as a bare
        // address — returning the network address this type exists to reject.
        guard raw.contains("/") else { return address }

        // A prefix IS present, so it must be valid — a malformed or out-of-range
        // one returns nil rather than falling through to the raw address.
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            return nil
        }

        // /31 and /32 have no network/broadcast split — every address is a host
        // (RFC 3021). Advancing here would step outside the prefix.
        guard prefix <= 30 else { return address }

        // `~UInt32(0) << 32` is undefined; /0 needs its mask stated literally.
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        let network = octets.reduce(UInt32(0)) { ($0 << 8) | $1 } & mask
        let host = network &+ 1 // 越过全 0 的网络地址，落在第一个主机上
        return "\((host >> 24) & 0xFF).\((host >> 16) & 0xFF).\((host >> 8) & 0xFF).\(host & 0xFF)"
    }

    /// 配置里的 `tun.inet4-address` 列表 → 应写入系统 DNS 的网关。
    ///
    /// 列表为空或不可解析时返回兜底网关，绝不返回一个不可应答的地址 ——
    /// 这里的返回值会直接落到 `networksetup -setdnsservers`，写错就是全网解析黑洞。
    static func gateway(fromInet4Addresses addrs: [String]) -> String {
        guard let first = addrs.first, let gateway = firstHostAddress(inPrefix: first) else {
            return defaultFakeIPGateway
        }
        return gateway
    }

    /// **首选**路径：内核真正绑在 utun 上的地址 → 应写入系统 DNS 的网关。
    ///
    /// 2026-10-09 实机推翻「前缀换算」这条路线的适用性。mihomo **完全无视**
    /// `tun.inet4-address`（四处实测：PATCH 该键 +全新 bring-up / 写进 config.yaml
    /// + `PUT /configs?force=true` / 非法值 `NOT-AN-IP` 重载仍 HTTP 204 且无校验
    /// 报错），所以配置里的前缀**不代表内核的实际选择**。实机开启 TUN 后：
    ///
    ///     ifconfig utun100 → inet 198.18.0.0 --> 198.18.0.0 netmask 0xfffffffc
    ///
    /// 内核绑的是 `.0`（网络地址），而 `gateway(fromInet4Addresses:)` 不管配置写什么
    /// 都会算出 `.1`。两者**必然**背离，App 于是把系统 DNS 指向一个内核根本没配的地址。
    ///
    /// 所以以**观测到的接口地址**为准：接口上真的有哪个地址，就写哪个。
    /// - Parameter observed: 接口当前持有的 IPv4 地址（`getifaddrs` 得来）。
    /// - Parameter inet4Addresses: 配置里的 `tun.inet4-address`，仅在观测落空时兜底。
    static func gateway(observed: [String], fromInet4Addresses addrs: [String]) -> String {
        // 2026-10-09 更正：这里**不能**用 `isAnswerableHost` 过滤。实机实测，
        // 接口持有的正是 `.0`，而 `isAnswerableHost` 恰好拒绝 `.0` —— 过滤会
        // 把唯一的真实观测量丢掉、回落算出 `.1`，新旧逻辑输出完全相同，等于没改。
        // 而且「`.0` 是网络地址所以不应答」本身就是错的前提：`.0` 与 `.1`
        // 在活体隧道上都 NOERROR、都 0% 丢包，TUN 关闭时又都 timed out ——
        // 二者都只是「被 auto-route 送进隧道、由 dns-hijack 应答」的普通地址。
        // 真正决定可达性的是**路由**，不是主机位。故此处只做格式校验，
        // 可达性交给 `routedInto` / `shouldRedirectSystemDNS` 判断。
        if let live = observed.first(where: { isPlausibleIPv4($0) }) {
            return live
        }
        return gateway(fromInet4Addresses: addrs)
    }

    /// 地址格式是否合法（四段、每段 0…255）。**只**校验形状，不判语义 ——
    /// 见 `gateway(observed:fromInet4Addresses:)` 里为何不能用主机位判可达性。
    static func isPlausibleIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return false }
        // `compactMap` 会吞掉非数字段（"a.b.c.d" → 0 个），但 "1.2.3.4x" 的
        // "4x" 也解析不出、同样被吞成 3 段而落空 —— 所以段数校验足够。
        return octets.allSatisfy { $0 <= 255 }
    }

    /// 该地址是否被路由进**我们的**隧道 —— 真正的可达性判据。
    ///
    /// 实机取证（2026-10-09，活体 TUN）：
    ///
    ///     route -n get 198.18.0.0 → destination: default, gateway: 172.16.10.1, interface: en0
    ///     route -n get 198.18.0.1 → destination: 198.18.0.1, gateway: 198.18.0.0, interface: utun100
    ///
    /// 反直觉但关键：**接口自己的地址 `.0` 反而不按本地地址处理**（点对点接口上
    /// 它落到默认路由），而**没有任何接口配置的 `.1`** 才被 auto-route 的
    /// `198.18.0.0/15` 送进 utun100。两者之所以都能解析，是因为 mihomo 的
    /// `dns-hijack: any:53` 在整个网段上应答；TUN 一关，二者同时 timed out。
    ///
    /// 所以「该地址此刻走哪个接口」才是唯一诚实的判据：它同时覆盖
    /// 「隧道没起来」「路由被别的进程抢走」两种真实故障，且不依赖任何
    /// 关于主机位的、已被证伪的假设。
    /// - Parameter routedInterface: 地址当前实际出口的接口名（内核路由表查询）。
    /// - Parameter tunnel: 我们认为属于本 App 的隧道接口名。
    static func routedInto(_ routedInterface: String?, tunnel: String?) -> Bool {
        guard let routedInterface, let tunnel else { return false }
        return routedInterface == tunnel
    }

    /// fake-ip 网段（RFC 2544 基准测试段 `198.18.0.0/15`）——mihomo 的默认
    /// `dns.fake-ip-range`，也是所有 fake-ip 应答的来源。
    ///
    /// 落在这一段里的系统 DNS 服务器只在 TUN 开启（`198.18.0.0/15` 被路由
    /// 进隧道、由内核应答）时才有意义。TUN 关闭时它没有路由，查询必然超时 ——
    /// 所以「系统 DNS 是 fake-ip 地址」本身就是「这里有残留」的充分证据，
    /// 不需要依赖任何标志位去判断。
    static func isFakeIPResolver(_ server: String) -> Bool {
        let octets = server.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        // 198.18.0.0/15 = 198.18.x.x 与 198.19.x.x
        return octets[0] == 198 && (octets[1] == 18 || octets[1] == 19)
    }

    /// 某个服务上的 fake-ip 残留**是否该由我们清除**。
    ///
    /// 残留清理的候选服务从「pinned + 当前默认」扩到**全部服务**之后，需要一条
    /// 明确的动手指南，否则会去改共存代理的配置。判据与理由：
    ///
    /// - `hasProvenance`（我们写过这个服务的证据：`tun.dns.overridden` 标志、
    ///   或记录下来的 pinned 服务名）→ **清**。是我们写的，当然由我们回收。
    /// - `isDefaultService` → **清**。默认接口是当前实际解析路径，黑洞摆在那里
    ///   就是现成故障；且旧版本遗留的残留正落在这条路径上。
    /// - 否则（无来源证据、非默认接口）→ 只有在**没有别的内核隧道在跑**时才清。
    ///   地址本身已证明是 fake-ip 段（没有用户会手填 `198.18.x.x` 当解析器），
    ///   无隧道服务它就是死地址；但若共存代理正开着，那一段可能确属它所有。
    ///
    /// 2026-10-10 修正：旧判据是 `!flagged && !pinned && service != services.last`
    /// 直接 `continue`。它把「旧版本遗留、无标志、非默认接口」的残留永久跳过 ——
    /// 而那恰好是清理逻辑存在的理由。改动前已用场景验证复现该盲区。
    /// - Parameter hasProvenance: 有我们写过该服务的证据。
    /// - Parameter isDefaultService: 该服务是当前默认路由对应的服务。
    /// - Parameter otherTunnelIsUp: 存在非本 App 的内核隧道（共存代理）。
    static func shouldSweepResidueOn(hasProvenance: Bool,
                                     isDefaultService: Bool,
                                     otherTunnelIsUp: Bool) -> Bool {
        if hasProvenance || isDefaultService { return true }
        return !otherTunnelIsUp
    }

    /// 系统 DNS 重定向是否该写入 —— 写入点的完整不变量。
    ///
    /// 三条前提，缺一即是全网解析黑洞：
    ///
    /// 1. **接口在**（`interfacePresent`）—— 隧道不存在时那个地址没有任何路由。
    /// 2. **地址被路由进隧道**（`routedInto`）—— 这是 2026-10-09 实机修正后的
    ///    可达性判据，取代了原先「主机位不能全 0」的网络语义判断。
    /// 3. **隧道里真的有 DNS**（`dnsEnabled`）—— TUN 开着而 config.yaml 是
    ///    `dns.enable: false` 时实测：`curl /configs → dns = null`，
    ///    `dig @198.18.0.1` 与 `dig @198.18.0.0` 均 SERVFAIL，
    ///    `nslookup` 亦 SERVFAIL —— 重定向正在生效而全系统失去解析能力。
    ///
    /// 第 2 条为何不能用「主机位全 0 = 网络地址」：那是本次排查中被**实测证伪**
    /// 的假设。活体隧道上 `.0`（接口自己持有）与 `.1`（无接口持有）**都能解析**，
    /// TUN 关闭后**都超时**，二者行为完全一致 —— 可达性来自 auto-route 把
    /// `198.18.0.0/15` 送进隧道 + `dns-hijack: any:53` 应答，与主机位无关。
    /// 而 `.0` 走默认路由出 en0、`.1` 走 utun100 这一实测差异表明：
    /// 「此刻走哪个接口」才同时覆盖「隧道没起来」与「路由被抢走」两种真实故障。
    ///
    /// - Parameter routedInterface: 网关地址当前实际出口的接口名（内核路由查询）。
    /// - Parameter tunnel: 属于本 App 的隧道接口名（如 `utun100`）。
    static func shouldRedirectSystemDNS(dnsEnabled: Bool,
                                        interfacePresent: Bool,
                                        gateway: String,
                                        routedInterface: String? = nil,
                                        tunnel: String? = nil) -> Bool {
        guard interfacePresent else { return false }
        guard isPlausibleIPv4(gateway) else { return false }
        // fail-closed：只要调用方给出了路由证据（哪怕某一侧是 nil），就必须
        // 证明「出口 == 自家隧道」。用 `if let` 解包会让 nil 悄悄跳过检查 ——
        // 那正是「证据不足却放行」的写法，等于给黑洞开了后门。
        if routedInterface != nil || tunnel != nil {
            guard routedInto(routedInterface, tunnel: tunnel) else { return false }
        }
        return dnsEnabled
    }

    /// 该地址是不是一个「可应答的主机地址」——即不是 /30 之类的网络地址。
    ///
    /// ⚠️ **2026-10-09 实机证伪，已不再用于可达性判断。**
    ///
    /// 保留此函数只为兼容既有测试与历史调用点，但它编码的前提是错的：
    /// 实测活体隧道上 `198.18.0.0`（接口自身持有）**应答正常**
    /// （`dig` NOERROR ×3、`ping` 0.0% 丢包），而它是 `.0`。
    /// 「主机位全 0 所以永不应答」在点对点隧道 + auto-route + dns-hijack 的组合下
    /// 不成立。可达性请用 `routedInto(_:tunnel:)`。
    ///
    /// 当心：`isAnswerableHost("198.18.0.0") == false` 会让任何以它为过滤器的
    /// 「观测优先」逻辑把真实观测量丢掉 —— 这正是修复初版原地踏步的原因。
    static func isAnswerableHost(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        // 主机位全 0 = 网络地址（此处按 /30 语义判定：末两位为 0）。
        // 198.18.0.0/30 的可用主机是 .1 与 .2，.0 与 .3 分别是网络/广播地址。
        let last = octets[3]
        if last == 0 { return false }   // x.x.x.0 为 /24 网络地址，也是 .0/30 的网络地址
        if last == 255 { return false } // 广播地址
        return true
    }
}
