import Foundation

// MARK: - 网关 DNS 监听的真实体检
//
// 为什么重写
// ----------
// 旧判定靠 `netstat -an -f inet -p udp` 的文本匹配找 `*.53`（`EngineControl.
// dnsWildcardPort53Bound`，2026-09 引入）。在本机 macOS 27.3 上实测：
//
//     shell 里跑        → 74 行，含 `udp46  0  0  *.53  *.*`
//     App 里 fork 出来跑 → **0 字节**（rc=0，stderr 为空），同参数
//
// 也就是说「App 里跑的 netstat」拿不到 socket 表，而「shell 里跑的 netstat」
// 拿得到——同一台机器、同一条命令。附带证据：`udpPort53Bindings()`（同样的
// netstat 家族）在归因时报告「53 端口当前无任何 UDP 监听」，而同一秒钟
// mihomo 自己日志写着 `DNS server(UDP) listening at: [::]:53`、`dig @127.0.0.1`
// 正常返回 NOERROR。
//
// 后果是确定的、不是偶发：`app.log` 里 12 次启动对应 12 次
// 「网关 DNS 未在 53 端口监听 → 正在重新应用（第 1/2 次）」，而每次重新应用
// 都是 `PUT /configs?force=true`——重建 DNS、全部 in/outbound 与 TUN，**丢掉
// 全部在途连接**。启动一次断两次网，代价全由用户付。
//
// 所以探测换成真实查询：向同一台机器上的 53 端口要一次解析。客户端能不能
// 解析，才是网关 DNS 唯一要回答的问题；一个 NOERROR 应答同时证明监听存在、
// socket 是 DNS、解析路径通，缺一不可。报文构造与校验复用 `DNSProbe`
// （TUNDataPlaneProbe.swift），SERVFAIL/NXDOMAIN 一律不算健康——那是断网签名。
//
// 第二件事更重要：**谁能触发内核重载**
// ----------------------------------
// 全量重载是唯一会丢掉全部在途连接的动作，而旧代码把「探测不到监听」当成
// 它的理由。端口被别的进程占用、内核刚起还没绑好、上游解析失败——这三种都
// 修不了重载，却都被重载「处理」过，而且每次处理都再断一次网。
// 现在只有「配置里的网关声明丢了」（allow-lan 关掉 / dns.listen 不再是
// 0.0.0.0:53，典型成因是切订阅）允许重载；探测不到应答只报告，不动内核。
//
// 本文件的判定半边是纯逻辑（无 socket、无进程、无 MainActor），由
// `Tests/GatewayDNSHealth` 钉住；发送半边只有一个函数，就是下面那个
// `GatewayDNSProbe.probe`。

/// 「配置声明了网关」的唯一口径。
let kGatewayDNSListen = "0.0.0.0:53"

/// 一次地址级探测的结果，和它的地址绑在一起（日志/归因都要能指名道姓）。
struct GatewayDNSObservation: Equatable {
    let address: String
    let outcome: DNSProbe.Outcome
}

/// 网关 DNS 的健康结论。
enum GatewayDNSVerdict: Equatable {
    /// 声明在，且至少一个局域网地址实测拿到 NOERROR：唯一算健康的状态。
    case healthy(lanAddresses: [String])
    /// 配置里的网关声明丢了（`allow-lan` 关 / `dns.listen` 不是 0.0.0.0:53）。
    case declarationDrift(allowLan: Bool, dnsListen: String?)
    /// 声明在，但局域网地址上没有 NOERROR 应答。
    ///   - `gotReply`：有字节回来但 RCODE≠0（SERVFAIL 等）→ DNS 活着，上游/规则坏了
    ///   - `loopbackAnswered`：127.0.0.1:53 拿到 NOERROR → 内核 DNS 活着，
    ///     只是没在局域网地址上应答（监听范围/端口占用）
    case lanUnanswered(lanAddresses: [String], gotReply: Bool, loopbackAnswered: Bool)
    /// 探测没能得出结论（没有可探测的物理网卡地址等）：不打任何结论，也不动内核。
    case undetermined(String)

    /// 唯一允许重载内核的分支。
    ///
    /// 任何新增结论都必须显式回答"它能不能触发重载"，默认答案是不行——见文件
    /// 头注释里「重载修不了端口占用，只会再断一次网」。
    var allowsKernelReload: Bool {
        if case .declarationDrift = self { return true }
        return false
    }

    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}

enum GatewayDNSCheck {
    /// 从真实观测得出结论。纯函数：同样的输入永远同样的结论，测试直接钉它。
    ///
    /// - Parameters:
    ///   - allowLan / dnsListen: 配置文件（不是运行态）里的两个网关声明字段。
    ///   - lan: 每个局域网 IPv4 地址各一条观测；空表示没有可探测地址。
    ///   - loopback: 对 127.0.0.1:53 的观测，用来区分「内核 DNS 死了」和
    ///     「内核 DNS 活着但没绑在 LAN 地址上」——这两种的处理方式完全不同。
    static func evaluate(allowLan: Bool,
                         dnsListen: String?,
                         lan: [GatewayDNSObservation],
                         loopback: DNSProbe.Outcome) -> GatewayDNSVerdict {
        // 1. 声明优先：文件里的声明丢了是唯一可修的漂移，且不依赖任何探测。
        guard allowLan, dnsListen == kGatewayDNSListen else {
            return .declarationDrift(allowLan: allowLan, dnsListen: dnsListen)
        }
        // 2. 没有可探测的局域网地址 → 不下结论，绝不因为「探不到」去动内核。
        guard !lan.isEmpty else {
            return .undetermined("没有可探测的局域网 IPv4 地址")
        }
        // 3. 任何一个局域网地址拿到 NOERROR 就算健康：wildcard 监听对所有
        //    局域网地址一视同仁，某个地址不答通常是对端网络策略，不是监听问题。
        let answered = lan.filter { $0.outcome == .valid }.map(\.address)
        if !answered.isEmpty {
            return .healthy(lanAddresses: answered)
        }
        // 4. 全部没拿到 NOERROR：只报告，不重载。
        return .lanUnanswered(
            lanAddresses: lan.map(\.address),
            gotReply: lan.contains { $0.outcome != .never },
            loopbackAnswered: loopback == .valid
        )
    }
}

// MARK: - 唯一的 socket 半边

/// 向指定地址的 UDP/53 发一次最小 A 查询，按 `DNSProbe.validate` 判定。
///
/// 与 `AppModel.probeLocalDNS53Once`（系统代理 DNS 事务）口径一致但不复用：
/// 那条路径每次写系统 DNS 前都要跑，任何改动都是高风险；这里只服务诊断。
enum GatewayDNSProbe {
    /// - Parameters:
    ///   - host: 目标地址字面量（`127.0.0.1` / `10.10.0.20`），不做名字解析。
    ///   - port: 目标端口，默认 53。
    ///   - queryName: 探测用的主机名。默认走 fake-ip 覆盖内的名字，使健康路径
    ///     由 mihomo 本地应答（NOERROR），不依赖上游可达性。
    ///   - timeout: 单次 wait 预算；超时返回 `.never`。
    nonisolated static func probe(host: String,
                                  port: UInt16 = 53,
                                  queryName: String = DNSProbe.probeHost,
                                  timeout: TimeInterval = 1.2) async -> DNSProbe.Outcome {
        await Task.detached(priority: .utility) { () -> DNSProbe.Outcome in
            let p = DNSProbe(txID: UInt16.random(in: 0x0101...0xfffe))
            let query = p.query(host: queryName)

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return .never }

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return .never }
            defer { close(fd) }
            var tv = timeval(tv_sec: Int(max(0, timeout)),
                             tv_usec: suseconds_t(max(0, timeout - floor(timeout)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let sent = query.withUnsafeBytes { raw -> Int in
                withUnsafePointer(to: &addr) { aptr -> Int in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, raw.baseAddress, query.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == query.count else { return .never }

            var buf = [UInt8](repeating: 0, count: 512)
            let n = withUnsafeMutablePointer(to: &addr) { aptr -> Int in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                    return recvfrom(fd, &buf, buf.count, 0, sa, &len)
                }
            }
            guard n > 0 else { return .never }
            return p.validate(response: Data(buf[0..<n]))
        }.value
    }
}
