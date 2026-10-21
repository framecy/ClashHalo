import Foundation

// MARK: - 连接「来源」判定
//
// 纯逻辑：无 SwiftUI、无 MainActor、无系统调用、无内核交互，可单独编译进回归套件
// （`Tests/ConnOrigin`，登记在 `Scripts/run-tests.sh`）。
//
// 为什么不能只看 `sourceIP`：TUN 模式下 mihomo 对本机进程上报的 `sourceIP` 恒为
// fake-ip 网关地址 `198.18.0.0`（2026-10-20 实测 98 条连接里 96 条如此），它既不是
// 客户端地址也不是本机地址。只看它，会把「本机 App」「局域网设备」统统判成本机。
//
// 真正的判据是流量从哪条入站进来（`inboundName`），加上源地址：
//   - TUN：`DEFAULT-TUN` + `198.18.0.0`（本机进程）
//   - TUN 网关：`DEFAULT-TUN` + 局域网设备真实地址（跨三层时可能拿不到）
//   - 混合/HTTP/SOCKS 端口：`DEFAULT-MIXED` 等 + `127.0.0.1`（本机）或局域网地址
//   - listener 端口转发：`inboundName` 即 listener 的 `name`
//   - 内核内部连接：`inboundName` 与 `sourceIP` 都是空串
//
// 判不出就如实说「未知来源」，不猜（与设备身份 OUI 的保守口径一致）。

/// 一条连接的来源归属。
enum ConnOriginKind: String, Equatable {
    /// 本机进程（含经本机端口的本机应用）。
    case local
    /// 局域网内的其它设备（网关模式下）。
    case lan
    /// 本机之外的公网对端（对外开放监听端口时才会出现）。
    case external
    /// 内核没给够证据（老连接 / 内部连接）。
    case unknown
}

/// 来源判定结果。`inbound` 与 `peer` 分开保存，是为了让 UI 能分两行展示，
/// 也为了测试能分别断言「归属」与「证据」，不被拼接文案淹没。
struct ConnOrigin: Equatable {
    let kind: ConnOriginKind
    /// 对端标识：局域网/外部为 IP，本机为空串（本机用进程名标识）。
    let peer: String
    /// 归一化后的入站名，可能带端口；空串表示内核未提供。
    let inbound: String

    /// 第一行：`本机 · Aside Helper` / `局域网 · 192.168.1.33` / `外部 · 1.2.3.4`。
    func title(process: String) -> String {
        switch kind {
        case .local:
            let p = process.trimmingCharacters(in: .whitespaces)
            let name = (p.isEmpty || p == "—") ? "未知进程" : p
            return "本机 · \(name)"
        case .lan:
            return "局域网 · \(peer)"
        case .external:
            return "外部 · \(peer)"
        case .unknown:
            return "未知来源"
        }
    }

    /// 第二行：入站证据；未知来源且有源地址时补上源地址（那是它唯一的证据）。
    ///
    /// 局域网/外部不在副标题里重复回显地址——它已经在 `title` 里，重复只会挤占宽度。
    func subtitle(sourceIP: String) -> String {
        let src = sourceIP.trimmingCharacters(in: .whitespaces)
        if inbound.isEmpty {
            if kind == .unknown, !src.isEmpty, !ConnOriginClassifier.isFakeIP(src) {
                return "源 \(src)"
            }
            return "内核未提供入站信息"
        }
        if kind == .unknown, !src.isEmpty, !ConnOriginClassifier.isFakeIP(src) {
            return "\(inbound) · 源 \(src)"
        }
        return inbound
    }
}

enum ConnOriginClassifier {

    /// mihomo 默认入站名 → 中文。未知/自定义 listener 名原样保留：那是用户自己起的
    /// 名字，翻译反而丢信息。
    ///
    /// `portIsListen` 决定要不要把 `inboundPort` 拼上去。**TUN 的 `inboundPort` 不是
    /// 监听端口**，而是每条连接在隧道里的源端口（实测 `DEFAULT-TUN` + `55677`/`0`
    /// 各不相同），拼上会读成「TUN 监听在 55677」，是错的。只有端口型入站的
    /// `inboundPort` 才是真正的监听端口（实测 `DEFAULT-MIXED` + `7890`）。
    private static let knownInbounds: [String: (label: String, portIsListen: Bool)] = [
        "DEFAULT-TUN": ("TUN 入站", false),
        "DEFAULT-MIXED": ("混合端口", true),
        "DEFAULT-SOCKS": ("SOCKS 端口", true),
        "DEFAULT-HTTP": ("HTTP 端口", true),
        "DEFAULT-TPROXY": ("透明代理入站", true),
        "DEFAULT-REDIR": ("重定向入站", true),
    ]

    /// 判定一条连接的来源。
    /// - Parameters:
    ///   - inboundName: `metadata.inboundName`，可空。
    ///   - inboundPort: `metadata.inboundPort`，可空；只在已知入站上作为后缀补充。
    ///   - sourceIP: `metadata.sourceIP`，可空。
    ///   - localIPs: 本机所有网卡地址（不含环回），由调用方传入以保持本函数纯净。
    static func classify(inboundName: String?,
                         inboundPort: String?,
                         sourceIP: String?,
                         localIPs: Set<String>) -> ConnOrigin {
        let inbound = normalizeInbound(inboundName, port: inboundPort)
        let src = (sourceIP ?? "").trimmingCharacters(in: .whitespaces)

        // 没有源地址：内核只给了入站（或什么都没给）——归属判不出，但入站证据保留。
        // `0.0.0.0` / `::` 是「任意地址」占位，不是某台设备的地址，同样落到未知。
        guard !src.isEmpty, src != "0.0.0.0", src != "::" else {
            return ConnOrigin(kind: .unknown, peer: "", inbound: inbound)
        }
        // 环回、fake-ip、本机网卡地址 → 本机进程。fake-ip 必须先于「私有地址」判断，
        // 否则 198.18.0.0 会被当成局域网设备。
        if isLoopback(src) || isFakeIP(src) || localIPs.contains(src) {
            return ConnOrigin(kind: .local, peer: "", inbound: inbound)
        }
        if isPrivate(src) {
            return ConnOrigin(kind: .lan, peer: src, inbound: inbound)
        }
        return ConnOrigin(kind: .external, peer: src, inbound: inbound)
    }

    // MARK: - 归一化

    static func normalizeInbound(_ name: String?, port: String?) -> String {
        let raw = (name ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "" }
        guard let known = knownInbounds[raw.uppercased()] else { return raw }
        // 端口 0 是内核「没有端口」的占位，不是真实监听端口。
        let p = (port ?? "").trimmingCharacters(in: .whitespaces)
        if known.portIsListen, !p.isEmpty, p != "0" {
            return "\(known.label) \(p)"
        }
        return known.label
    }

    // MARK: - 地址分类

    /// mihomo 默认 fake-ip 段 `198.18.0.0/15`（v4）与 `fdfe:dcba:9876::1/126`（v6，
    /// 取自内核二进制里的默认值）。
    ///
    /// v6 这一条是**兜底**：`fake-ip-range6` 可被配置改成任意前缀，这里无法读配置，
    /// 只认内核默认值。改过默认值的用户会看到 v6 fake 地址落到「局域网」而不是
    /// 「本机」——两者都不会被误判成「外部」，代价可接受；且 v6 TUN 默认关闭
    /// （`ipv6: false`），今天不触发。
    static func isFakeIP(_ ip: String) -> Bool {
        if ip.contains(":") {
            return ip.lowercased().hasPrefix("fdfe:dcba:9876:")
        }
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        return a == 198 && (b == 18 || b == 19)
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip == "::1" || ip.hasPrefix("127.")
    }

    /// 私有/链路本地：10/8、172.16/12、192.168/16、169.254/16、IPv6 fe80::/10 与 fc00::/7。
    static func isPrivate(_ ip: String) -> Bool {
        if ip.contains(":") {
            let lower = ip.lowercased()
            return lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
                || lower.hasPrefix("fea") || lower.hasPrefix("feb")
                || lower.hasPrefix("fc") || lower.hasPrefix("fd")
        }
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        if a == 10 { return true }
        if a == 172, (16...31).contains(b) { return true }
        if a == 192, b == 168 { return true }
        if a == 169, b == 254 { return true }
        return false
    }
}
