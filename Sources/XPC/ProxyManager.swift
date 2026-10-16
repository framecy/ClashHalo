import Foundation
import SystemConfiguration

public class ProxyManager {
    private static func log(_ msg: String) {
        NSLog("[ClashHalo Helper ProxyManager] %@", msg)
    }

    /// Apply system-proxy settings to every non-virtual currently-active
    /// service (shared `ProxyServicePlan` selection), reporting a per-service
    /// outcome. This is the authoritative entry point — the legacy
    /// `setSystemProxy(enabled:port:) -> Bool` wrapper maps `.full` → true so a
    /// partial result is never reported up-stack as success.
    @discardableResult
    public static func setSystemProxyDetailed(enabled: Bool, port: Int) -> SystemProxyApplyOutcome {
        let services = ProxyServicePlan.liveTargetServices()
        guard !services.isEmpty else {
            log("setSystemProxy: no network services")
            return .failed
        }
        var okList: [String] = []
        var failedList: [String] = []
        for svc in services {
            let ok: Bool
            if enabled {
                // Proxy bypass domains: localhost + loopback + mDNS + RFC1918
                // private ranges + link-local + CGNAT (kProxyBypassDomains). LAN/
                // intranet/SD-WAN hosts bypass the proxy so they never hit mihomo
                // (which can't route to them, surfacing as 502).
                //
                // `-setwebproxy` writes host/port but on some macOS builds does NOT
                // flip the enable bit by itself — always follow with `-*proxystate on`
                // (same as the GUI fallback path in EngineControl).
                ok = run(["-setwebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsecurewebproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setsocksfirewallproxy", svc, "127.0.0.1", "\(port)"])
                    && run(["-setproxybypassdomains", svc] + kProxyBypassDomains)
                    && run(["-setwebproxystate", svc, "on"])
                    && run(["-setsecurewebproxystate", svc, "on"])
                    && run(["-setsocksfirewallproxystate", svc, "on"])
            } else {
                ok = run(["-setwebproxystate", svc, "off"])
                    && run(["-setsecurewebproxystate", svc, "off"])
                    && run(["-setsocksfirewallproxystate", svc, "off"])
            }
            if ok {
                okList.append(svc)
            } else {
                failedList.append(svc)
                log("setSystemProxy(\(enabled)) failed for service: \(svc)")
            }
        }
        let outcome = ProxyServicePlan.classify(succeeded: okList, failed: failedList)
        log("setSystemProxy(enabled: \(enabled), port: \(port)) ok=\(okList) failed=\(failedList)")
        return outcome
    }

    /// Legacy XPC-facing Bool wrapper. Only full success maps to true; partial
    /// and failure both return false, so callers stop marking the system proxy
    /// "on" when only one of several target services actually got configured.
    public static func setSystemProxy(enabled: Bool, port: Int) -> Bool {
        setSystemProxyDetailed(enabled: enabled, port: port).isSuccess
    }

    /// All enabled network services, via the shared parser. DNS restore paths
    /// (unlike proxy writes) deliberately span every enabled service.
    /// 2026-10-14: 枚举失败不再静默返回 []——死亡清理会整体空转且无人知晓。
    /// 重试一次，仍失败打具名错误日志再返回 []（保持返回值语义，调用方零改动）。
    private static func enabledNetworkServices() -> [String] {
        var out = runOutput(["-listallnetworkservices"])
        if out == nil {
            // networksetup 偶发卡顿（SC 动态存储锁竞争）会超时；立即重试一次
            out = runOutput(["-listallnetworkservices"])
            if out == nil {
                log("enabledNetworkServices: -listallnetworkservices 两次均失败（超时/错误），枚举按空处理——死亡清理本轮将空转，GUI 侧 sweep 需兜底")
            }
        }
        guard let output = out else { return [] }
        return ProxyServicePlan.enabledServices(listOutput: output)
    }

    /// Per-command timeout. Keep well under the GUI XPC budget (15s for proxy).
    /// DNS 恢复类命令不适用 1.2s：networksetup 写入被中途 terminate 会留下
    /// 半提交状态且账本已丢（2026-10-14 审查中-5）。恢复路径统一走 5s。
    private static let cmdTimeout: TimeInterval = 1.2
    private static let restoreCmdTimeout: TimeInterval = 5.0

    @discardableResult
    private static func run(_ args: [String], timeout: TimeInterval = cmdTimeout) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if p.isRunning {
                p.terminate()
            }
        }

        do {
            try p.run()
            timer.resume()
            p.waitUntilExit()
            timer.cancel()
            return p.terminationStatus == 0
        } catch {
            timer.cancel()
            return false
        }
    }

    private static func runOutput(_ args: [String], timeout: TimeInterval = cmdTimeout) -> String? {
        return runOutput("/usr/sbin/networksetup", args, timeout: timeout)
    }

    private static func runOutput(_ binPath: String, _ args: [String], timeout: TimeInterval = cmdTimeout) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binPath)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if p.isRunning {
                p.terminate()
            }
        }

        do {
            try p.run()
            timer.resume()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return String(data: data, encoding: .utf8)
        } catch {
            timer.cancel()
            return nil
        }
    }

    // `restoreDNS()` (blanket "Empty over every active service, fallback to a
    // hardcoded 223.5.5.5") was removed on 2026-08-29: it had zero callers and
    // its fallback semantics clobber a user's own custom DNS. Death cleanup
    // uses `restoreDNSIfTunnelPinned()`; GUI teardown uses EngineControl's
    // applySystemDNS with the snapshot/restore state machine.

    /// True when something still accepts TCP connections on 127.0.0.1:53 —
    /// a local resolver (mihomo's redir-host listener, or the user's own
    /// AdGuard / dnsmasq) is alive. On loopback connect() answers instantly,
    /// so no timeout handling is needed; inconclusive errors count as alive —
    /// we never clobber a resolver we cannot prove is dead.
    ///
    /// 2026-10-14（审查低-1 修复）：mihomo 的 DNS 监听是 UDP 优先（dns-hijack
    /// any:53 也是 UDP），纯 TCP 探测会把「只有 UDP 在监听」误判为死，进而
    /// 错误清掉 127.0.0.1。现在判死需要两条证据同时成立：TCP 明确拒绝
    /// **且** UDP 最小查询 300ms 内无应答。任一应答即活。
    private static func isLoopbackDNSLive() -> Bool {
        if loopbackTCP53Connects() { return true }
        return loopbackUDP53Answers()
    }

    /// TCP 半边：connect 127.0.0.1:53。inconclusive 一律算活。
    private static func loopbackTCP53Connects() -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = UInt16(53).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return true }
        switch errno {
        case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EADDRNOTAVAIL: return false
        default: return true
        }
    }

    /// UDP 半边：向 127.0.0.1:53 发最小 DNS 根查询（17 字节：header + 根 QNAME
    /// + QTYPE/QCLASS），300ms 内收到任意长度 >0 的应答即视为活。发不出去或
    /// 超时返回 false——是否判死由调用方结合 TCP 半边决定。
    private static func loopbackUDP53Answers() -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = UInt16(53).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // 最小查询：id=0x4841, RD=1, QDCOUNT=1, QNAME=root("."),
        // QTYPE=A(1), QCLASS=IN(1)。root 查询不需要真实域名，探测只关心
        // 有没有字节回来（格式校验交给端口本身是 DNS 的事实）。
        let query: [UInt8] = [
            0x48, 0x41,             // ID
            0x01, 0x00,             // FLAGS: recursion desired
            0x00, 0x01,             // QDCOUNT = 1
            0x00, 0x00,             // ANCOUNT
            0x00, 0x00,             // NSCOUNT
            0x00, 0x00,             // ARCOUNT
            0x00,                   // QNAME: root
            0x00, 0x01,             // QTYPE = A
            0x00, 0x01              // QCLASS = IN
        ]
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                query.withUnsafeBytes { buf in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return false }
        // 300ms 接收超时：本机回环上活着的解析器应答在毫秒级
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0
    }

    /// 单次 DNS 恢复的明细结果（2026-10-14 审查低-3）。
    /// 旧实现返回 `anyOK: Bool`，「有一个服务恢复了」和「全部恢复了」在调用方
    /// 看起来完全一样，单服务失败被聚合掩盖——而这里失败的后果正是系统 DNS 仍
    /// 钉在 198.18.x 上的断网形态。按服务分类回报，helper.log 里能直接看出
    /// 是哪个服务没恢复、卡在读还是写。
    public struct DNSRestoreReport {
        /// 已成功还原（写回 Empty）的服务
        public var restored: [String] = []
        /// 尝试还原但 networksetup 写入失败的服务：原值保留，等 GUI 侧 sweep 续修
        public var failed: [String] = []
        /// 连 DNS 现状都读不到（超时/错误）的服务：本轮完全没动过
        public var unreadable: [String] = []

        /// 没有任何服务处于需要还原的状态（既非隧道钉扎，也无死掉的 loopback DNS）
        public var nothingToDo: Bool { restored.isEmpty && failed.isEmpty && unreadable.isEmpty }
        /// 全部干净：没有遗留待续修的服务
        public var allClear: Bool { failed.isEmpty && unreadable.isEmpty }

        /// 单行中文摘要，直接进日志
        public var summary: String {
            if nothingToDo { return "无需还原（没有服务的 DNS 处于隧道钉扎或 loopback 死值状态）" }
            var parts: [String] = []
            if !restored.isEmpty { parts.append("已还原 [\(restored.joined(separator: ", "))]") }
            if !failed.isEmpty { parts.append("写入失败 [\(failed.joined(separator: ", "))]（原值保留，待 GUI sweep 续修）") }
            if !unreadable.isEmpty { parts.append("读取失败 [\(unreadable.joined(separator: ", "))]（本轮未动）") }
            return parts.joined(separator: "；")
        }
    }

    /// Restore DNS only for services whose resolver is pinned at the mihomo
    /// fake-ip gateway (198.18.x / 198.19.x). Client-death cleanup uses this
    /// instead of the blanket `restoreDNS()` so a user's custom DNS — or the
    /// saved DNS the GUI already restored during a normal quit — is never
    /// clobbered back to "Empty" when the tunnel redirect wasn't even active.
    ///
    /// 2026-10-14（审查中-5 修复）：
    /// - 恢复类命令统一 5s 超时——1.2s 会把写入中的 networksetup 打断，
    ///   半提交状态 + 账本已丢 = 永久残留；
    /// - 删除 223.5.5.5 兜底：与 2026-08-29 移除 blanket restoreDNS 的理由
    ///   相同，公网兜底会践踏用户自己的自定义 DNS。恢复失败只打日志，
    ///   保留原值交 GUI 侧 sweep 续修；
    /// - getdnsservers 读取失败从静默 continue 改为具名日志，并连同写入失败
    ///   一起进 `DNSRestoreReport`（低-3），调用方不再只看到一个聚合 Bool。
    @discardableResult
    public static func restoreDNSIfTunnelPinned() -> DNSRestoreReport {
        var report = DNSRestoreReport()
        for svc in enabledNetworkServices() {
            guard let out = runOutput(["-getdnsservers", svc], timeout: restoreCmdTimeout) else {
                log("restoreDNSIfTunnelPinned: 读取 \(svc) DNS 失败（超时/错误），本服务本轮跳过，保留原值待 GUI sweep 续修")
                report.unreadable.append(svc)
                continue
            }
            let entries = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let tunnelPinned = entries.contains { $0.hasPrefix("198.18.") || $0.hasPrefix("198.19.") }
            // 1.0.28: a bare `127.0.0.1` entry is the redir-host mode's
            // fingerprint (system DNS → mihomo's port-53 listener). Reset it
            // only when NOTHING answers DNS on 127.0.0.1:53 anymore — a
            // user-run loopback resolver keeps the port bound and must be
            // left alone (TCP or UDP 任一应答即视为活)。
            let loopbackDead = entries.contains { $0 == "127.0.0.1" } && !isLoopbackDNSLive()
            guard tunnelPinned || loopbackDead else { continue }
            let ok = run(["-setdnsservers", svc, "Empty"], timeout: restoreCmdTimeout)
            log("restoreDNSIfTunnelPinned: \(svc) was tunnel-pinned, reset \(ok ? "ok" : "FAILED（保留原值，待 GUI sweep 续修）")")
            if ok { report.restored.append(svc) } else { report.failed.append(svc) }
        }
        return report
    }

    /// Read the effective system proxy state (no root required). Returns true
    /// when HTTP proxy is enabled and points to 127.0.0.1 — i.e. "our" proxy.
    public static func readCurrentState() -> Bool {
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        let httpOn = dict[kCFNetworkProxiesHTTPEnable as String] as? Int == 1
        let httpHost = dict[kCFNetworkProxiesHTTPProxy as String] as? String
        return httpOn && httpHost == "127.0.0.1"
    }

    /// Whether any enabled network service currently routes HTTP/HTTPS/SOCKS
    /// through a loopback proxy — i.e. a proxy that can only be ours (or another
    /// local proxy app), and which black-holes traffic once the kernel is gone.
    ///
    /// Queried via `networksetup` rather than `SCDynamicStoreCopyProxies` because
    /// this runs inside a root LaunchDaemon with no user session, where the
    /// dynamic-store proxy snapshot is not a reliable view of per-service state.
    /// Used as the reality-based fallback for client-death cleanup: the helper's
    /// in-memory session flags are lost whenever the helper itself restarts
    /// (e.g. right after its own upgrade), and without this a force-quit then
    /// left a stale 127.0.0.1 proxy pointing at a dead kernel — total blackout.
    ///
    /// - Parameter port: When set, only a proxy pointing at THAT port counts as
    ///   ours — the helper passes the port it last wrote. The unscoped match
    ///   (any loopback proxy) would also wipe a *co-resident* proxy app's
    ///   settings (Surge/ClashX on their own port) when only our client died:
    ///   the same unasserted-ownership class as the fake-ip DNS incident. The
    ///   unscoped form remains as the fallback for a helper that restarted and
    ///   forgot the port — in that amnesiac state the blackout guarantee wins.
    public static func anyServiceProxiesToLoopback(port: Int? = nil) -> Bool {
        for svc in enabledNetworkServices() {
            for cmd in ["-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy"] {
                guard let out = runOutput([cmd, svc]) else { continue }
                let parsed = ProxyServicePlan.parseGetProxyOutput(out)
                let loopback = parsed.host == "127.0.0.1" || parsed.host == "::1"
                    || parsed.host == "localhost"
                let portMatches = port.map { $0 == parsed.port } ?? true
                if parsed.enabled && loopback && portMatches { return true }
            }
        }
        return false
    }

    /// Clean up TUN residual after mihomo exits: delete default routes pointing
    /// to utun interfaces bearing mihomo's 198.18.x.x addresses, bring those
    /// interfaces down, and remove their IP addresses. macOS utun interfaces
    /// created via AF_SYSTEM sockets cannot be destroyed with `ifconfig destroy`
    /// — they persist until their controlling socket FD is closed. Bringing them
    /// down + removing addresses neutralizes their Supplemental DNS resolvers
    /// and prevents traffic from routing into a dead tunnel.
    /// - Parameter downedOnly: When true, only neutralize interfaces whose
    ///   flags no longer carry UP — i.e. true zombie residue. Client-death
    ///   cleanup passes true so a *healthy* co-resident VPN tunnel sharing the
    ///   198.18.x space (e.g. Shadowrocket, still UP) is never torn down.
    @discardableResult
    public static func cleanupTUNResidual(downedOnly: Bool = false) -> Bool {
        // 1. Find utun interfaces with 198.18.x.x addresses (mihomo TUN signature)
        let ifconfigOut = runGeneric("/sbin/ifconfig", ["-a"])
        guard let output = ifconfigOut else {
            log("cleanupTUNResidual: ifconfig failed")
            return false
        }

        var mihomoUtuns: [(iface: String, addr: String)] = []
        var currentIface: String?
        var currentIfaceUp = false
        for line in output.split(separator: "\n") {
            let s = String(line)
            // Interface header line: "utunN: flags=8051<UP,POINTOPOINT,...>"
            if !s.hasPrefix("\t") && !s.hasPrefix(" "), s.contains(": flags=") {
                currentIface = String(s.prefix(while: { $0 != ":" }))
                // UP flag lives in the <...> segment of the header line.
                if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt {
                    let flags = s[s.index(after: lt)..<gt].split(separator: ",")
                    currentIfaceUp = flags.contains("UP")
                } else {
                    currentIfaceUp = false
                }
            }
            // inet line with 198.18.x.x → this is mihomo's TUN
            if let iface = currentIface, iface.hasPrefix("utun"),
               s.contains("198.18."), s.contains("inet ") {
                // 清理资格（2026-10-14 审查低-6 修复）。198.18.0.0/15 是共享地址
                // 段，共存 VPN（Shadowrocket 等）也在用，所以按「接口状态 + 设备名」
                // 两条证据判归属，对齐 GUI 侧既有纪律：
                // • DOWN：一律可清。共存 VPN 工作时自己的隧道是 UP 的，DOWN 的
                //   198.18 utun 只可能是残留——含 pin 之前的老构建残留，而那正是
                //   本自愈存在的理由（Models.hasDownedMihomoTun 刻意不按设备名门控：
                //   名字门控会拿一次真实恢复去换一个不可能发生的冲突）。
                // • UP：只认固定设备名 kPinnedTunDevice。UP 且同名才是本 App 的僵尸
                //   形态（配置已关却仍 UP 且承载路由，见 upDetachedMihomoTun）；UP 且
                //   异名可能是共存 VPN 正在工作，宁漏不误伤——漏掉的代价只是留下一个
                //   仍在应答 DNS 的隧道，误伤的代价是用户另一条 VPN 直接断网。
                if currentIfaceUp {
                    if downedOnly {
                        log("cleanupTUNResidual: skip \(iface) — still UP (downedOnly)")
                        continue
                    }
                    if iface != kPinnedTunDevice {
                        log("cleanupTUNResidual: skip \(iface) — UP 且非固定设备名 \(kPinnedTunDevice)，可能是共存 VPN 正在工作的隧道，宁漏不误伤")
                        continue
                    }
                    log("cleanupTUNResidual: \(iface) UP 且为固定设备名，按僵尸残留清理")
                }
                // Extract the IP address: "inet 198.18.0.1 --> ..."
                let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if let idx = parts.firstIndex(of: "inet"), idx + 1 < parts.count {
                    mihomoUtuns.append((iface: iface, addr: String(parts[idx + 1])))
                } else {
                    mihomoUtuns.append((iface: iface, addr: "198.18.0.1"))
                }
            }
        }

        guard !mihomoUtuns.isEmpty else {
            log("cleanupTUNResidual: no mihomo utun interfaces found")
            return true  // nothing to clean
        }

        let ifaceNames = mihomoUtuns.map(\.iface)
        log("cleanupTUNResidual: found mihomo utun interfaces: \(ifaceNames)")

        // 2. Delete default routes pointing to these utun interfaces.
        //    2026-10-14（审查低-4 后续）：原先这里的两条 `-interface` 变体是
        //    死代码——`man route` 核验 delete 只认 `-ifscope` 作用域修饰符
        //    （`-interface` 是 add 语义，放进 delete 不参与匹配、只会静默
        //    失败）。但 `-ifscope` 只覆盖接口作用域的 default；mihomo
        //    auto-route 装的**全局** default 需要单独一步——整表 flush 兜底
        //    已删，这里是唯一覆盖点。归属先经 `route -n get default` 确认：
        //    只有全局 default 确实指向 mihomo utun 才删，绝不盲删（en0 的
        //    合法默认路由必须在清理后存活）。
        let v4DefaultOwner = currentDefaultRouteInterface(inet6: false)
        let v6DefaultOwner = currentDefaultRouteInterface(inet6: true)
        for (iface, _) in mihomoUtuns {
            // 接口作用域 default：无条件尝试，只可能命中绑定到该接口的条目
            _ = runGeneric("/sbin/route", ["-n", "delete", "default", "-ifscope", iface])
            _ = runGeneric("/sbin/route", ["-n", "delete", "-inet6", "default", "-ifscope", iface])
            // 全局 default：仅在归属确证后删除（route 成功时 stdout 含 "delete"）
            if v4DefaultOwner == iface {
                let out = runGeneric("/sbin/route", ["-n", "delete", "default"]) ?? ""
                log("cleanupTUNResidual: global default pointed at \(iface), delete \(out.contains("delete") ? "ok" : "FAILED")")
            }
            if v6DefaultOwner == iface {
                let out = runGeneric("/sbin/route", ["-n", "delete", "-inet6", "default"]) ?? ""
                log("cleanupTUNResidual: global IPv6 default pointed at \(iface), delete \(out.contains("delete") ? "ok" : "FAILED")")
            }
        }

        // 3. Delete any residual 198.18.0.0/15 routes (mihomo fake-ip range)
        _ = runGeneric("/sbin/route", ["-n", "delete", "198.18.0.0/15"])

        // 4. Bring interfaces down and remove their IP addresses to neutralize
        //    Supplemental DNS resolvers. utun can't be `destroy`ed, but down +
        //    address removal makes the system stop using it for DNS/routing.
        for (iface, addr) in mihomoUtuns {
            _ = runGeneric("/sbin/ifconfig", [iface, "down"])
            _ = runGeneric("/sbin/ifconfig", [iface, "inet", addr, "delete"])
            log("cleanupTUNResidual: \(iface) down + deleted \(addr)")
        }

        // 5. 2026-10-14（审查低-4 修复）：不再执行全局 `route -n flush`——它冲掉
        //    的是整张路由表（含 Tailscale/其他 VPN 的注入路由），不是"缓存"。
        //    mihomo 残留的可观测足迹只有两类：指向这些 utun 的默认路由（第 2
        //    步已删）与 fake-ip 网段本身，这里按接口作用域精确补一刀即可。
        //    只保留 `-ifscope`：`man route` 的 delete 语法是
        //    `route [-n] command [-net|-host] [-ifscope boundif] destination gateway`，
        //    作用域修饰符只有 `-ifscope`；`-interface` 是 add 的语义（"目标经该接口
        //    直达，gateway 为本机在该网络上的地址"），放进 delete 不参与匹配、只会
        //    静默失败。无作用域的那条 198.18.0.0/15 第 3 步已经删过，这里不需要
        //    第二条形式，留着等于死代码。
        for (iface, _) in mihomoUtuns {
            _ = runGeneric("/sbin/route", ["-n", "delete", "198.18.0.0/15", "-ifscope", iface])
        }

        // 已知设计限制（2026-10-14 审查评估，记录在案）：split-route 模式下
        // mihomo 会装几百条非默认、非 198.18 网段的路由（如 1/10、1.64/12…），
        // 本函数没有任何一步覆盖它们——旧的整表 flush 能抹掉但那个行为本身
        // 是 bug（连 Tailscale 等第三方 VPN 的注入路由一起冲）。这些残留是
        // 惰性的：第 4 步 `ifconfig down` 触发 BSD if_down()，关联路由的
        // RTF_UP 被清掉，查找会跳过它们并回落到物理网卡的默认路由；接口被
        // 销毁时条目才真正移除。逐条按 (dest, gateway, iface) 三元组精确删
        // 需要 500+ 次进程生成，XPC 调用可能中途超时留下半清理状态——
        // 「表脏」不值得换「半途而废」。
        log("cleanupTUNResidual: split 路由残留（如有）依赖 if_down 清 RTF_UP 惰性化，不逐条删除（已知设计限制）")

        return true
    }

    /// 解析 `route -n get default` 的 `interface:` 行，判定当前全局默认路由
    /// 指向哪个接口。命令失败、无默认路由或解析不出时返回 nil——调用方把
    /// nil 当「归属不明」处理并跳过全局 default 删除（宁可留一条惰性残留，
    /// 也不能误删物理网卡的合法默认路由）。
    private static func currentDefaultRouteInterface(inet6: Bool) -> String? {
        let args = inet6 ? ["-n", "get", "-inet6", "default"] : ["-n", "get", "default"]
        guard let out = runGeneric("/sbin/route", args) else { return nil }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                let v = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Run an arbitrary command and return its stdout (nil on failure). 5s timeout.
    private static func runGeneric(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 5.0)
        timer.setEventHandler {
            if p.isRunning {
                log("runGeneric timeout: killing \(executable) \(args)")
                p.terminate()
            }
        }

        do {
            try p.run()
            timer.resume()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            return String(data: data, encoding: .utf8)
        } catch {
            timer.cancel()
            return nil
        }
    }
}
