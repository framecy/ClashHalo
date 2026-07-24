import Foundation

/// 解析 `vmess://` `vless://` `trojan://` `ss://` `hysteria2://`（含 `hy2://` 别名）
/// 分享链接为 `LocalProxy`。解析失败返回 nil，调用方应回落到手动表单，而不是报硬错误
/// ——分享链接格式在生态里有不少变体，解析不出来不代表链接一定无效。
///
/// 明确不支持、故意返回 nil 的情况：链接要求 websocket/gRPC 等传输层封装
/// （`net`/`type` 查询参数非 tcp）。`LocalProxy` 目前只覆盖 TCP/TLS 直连字段，
/// 静默丢弃传输层参数会生成一个连不通的"看起来正常"的节点——宁可解析失败、
/// 让用户去手填或用支持传输层的工具生成配置，也不做这种看似成功实则半残的导入。
enum ShareLinkParser {
    static func parse(_ raw: String) -> LocalProxy? {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.hasPrefix("vmess://") { return parseVMess(link) }
        if link.hasPrefix("vless://") { return parseVLESS(link) }
        if link.hasPrefix("trojan://") { return parseTrojan(link) }
        if link.hasPrefix("ss://") { return parseSS(link) }
        if link.hasPrefix("hysteria2://") || link.hasPrefix("hy2://") { return parseHysteria2(link) }
        return nil
    }

    // MARK: - vmess://<base64 JSON>

    private static func parseVMess(_ link: String) -> LocalProxy? {
        let payload = String(link.dropFirst("vmess://".count))
        guard let json = base64Decode(payload),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func str(_ key: String) -> String {
            if let s = obj[key] as? String { return s }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            return ""
        }

        // net 非 tcp（ws/grpc/h2/quic 等）需要传输层封装，本模型不支持——解析失败。
        let net = str("net")
        guard net.isEmpty || net == "tcp" else { return nil }

        guard let server = obj["add"].flatMap({ "\($0)" }), !server.isEmpty,
              let uuid = obj["id"].flatMap({ "\($0)" }), !uuid.isEmpty else { return nil }

        var p = LocalProxy(name: str("ps").isEmpty ? server : str("ps"), kind: .vmess)
        p.server = server
        p.port = str("port")
        p.uuid = uuid
        p.alterId = str("aid").isEmpty ? "0" : str("aid")
        p.cipher = str("scy").isEmpty ? "auto" : str("scy")
        let tlsRaw = str("tls")
        p.tls = tlsRaw == "tls" || tlsRaw == "1" || tlsRaw == "true"
        p.sni = str("sni").isEmpty ? str("host") : str("sni")
        return p.port.isEmpty ? nil : p
    }

    // MARK: - vless://<uuid>@host:port?...#remark

    private static func parseVLESS(_ link: String) -> LocalProxy? {
        guard let comps = URLComponents(string: link),
              let host = comps.host, !host.isEmpty,
              let port = comps.port,
              let uuid = comps.user, !uuid.isEmpty else { return nil }

        let q = queryDict(comps)
        // type（网络层）非 tcp 需要传输层封装——本模型不支持。
        let net = q["type"] ?? ""
        guard net.isEmpty || net == "tcp" else { return nil }

        var p = LocalProxy(name: displayName(comps, fallback: host), kind: .vless)
        p.server = host
        p.port = String(port)
        p.uuid = uuid
        p.flow = q["flow"] ?? ""
        p.sni = q["sni"] ?? q["servername"] ?? ""
        p.skipCertVerify = (q["allowInsecure"] == "1") || (q["insecure"] == "1")
        // security=reality：真实订阅里相当常见（VLESS 常用它规避 TLS 指纹检测）。
        // pbk/sid 缺一个都无法完成 REALITY 握手，两个都有才当作 REALITY 处理，
        // 否则退化成普通 TLS——半吊子的 reality-opts 写进配置只会让 mihomo -t 校验失败。
        if q["security"] == "reality", let pbk = q["pbk"], !pbk.isEmpty,
           let sid = q["sid"], !sid.isEmpty {
            p.publicKey = pbk
            p.shortId = sid
            p.fingerprint = q["fp"] ?? "chrome"
        }
        return p
    }

    // MARK: - trojan://<password>@host:port?...#remark

    private static func parseTrojan(_ link: String) -> LocalProxy? {
        guard let comps = URLComponents(string: link),
              let host = comps.host, !host.isEmpty,
              let port = comps.port,
              let password = comps.user, !password.isEmpty else { return nil }

        let q = queryDict(comps)
        var p = LocalProxy(name: displayName(comps, fallback: host), kind: .trojan)
        p.server = host
        p.port = String(port)
        p.password = password
        p.sni = q["sni"] ?? q["peer"] ?? ""
        p.skipCertVerify = (q["allowInsecure"] == "1") || (q["insecure"] == "1")
        return p
    }

    // MARK: - hysteria2://<password>@host:port?...#remark（含 hy2:// 别名）

    private static func parseHysteria2(_ link: String) -> LocalProxy? {
        // URLComponents 不认识 hy2:// 也没关系，直接把 scheme 换成标准的再解析。
        let normalized = link.hasPrefix("hy2://")
            ? "hysteria2://" + link.dropFirst("hy2://".count)
            : link
        guard let comps = URLComponents(string: normalized),
              let host = comps.host, !host.isEmpty,
              let port = comps.port,
              let password = comps.user, !password.isEmpty else { return nil }

        let q = queryDict(comps)
        var p = LocalProxy(name: displayName(comps, fallback: host), kind: .hysteria2)
        p.server = host
        p.port = String(port)
        p.password = password
        p.sni = q["sni"] ?? ""
        p.skipCertVerify = (q["insecure"] == "1")
        return p
    }

    // MARK: - ss://...（SIP002 / 全量 base64 两种历史格式都要认）

    private static func parseSS(_ link: String) -> LocalProxy? {
        let body = String(link.dropFirst("ss://".count))
        let (main, fragment) = splitFragment(body)

        // 全量 base64 旧格式：ss://base64(method:password@host:port)，没有 @ 也没有 ?
        if !main.contains("@"), let decoded = base64Decode(main.components(separatedBy: "?").first ?? main) {
            return parseSSCredentialsHostPort(decoded, name: fragment)
        }

        // SIP002：ss://<base64 或明文 method:password>@host:port?...#remark
        guard let atIdx = main.firstIndex(of: "@") else { return nil }
        let userinfoRaw = String(main[main.startIndex..<atIdx])
        let hostPortAndQuery = String(main[main.index(after: atIdx)...])
        guard let comps = URLComponents(string: "ss://x@\(hostPortAndQuery)"),
              let host = comps.host, !host.isEmpty, let port = comps.port else { return nil }

        let userinfo = base64Decode(userinfoRaw) ?? userinfoRaw   // 明文 method:password 也支持
        guard let colonIdx = userinfo.firstIndex(of: ":") else { return nil }
        let method = String(userinfo[userinfo.startIndex..<colonIdx])
        let password = String(userinfo[userinfo.index(after: colonIdx)...])
        guard !method.isEmpty, !password.isEmpty else { return nil }

        var p = LocalProxy(name: fragment.isEmpty ? host : fragment, kind: .ss)
        p.server = host
        p.port = String(port)
        p.cipher = method
        p.password = password
        return p
    }

    private static func parseSSCredentialsHostPort(_ decoded: String, name: String) -> LocalProxy? {
        // decoded 形如 "method:password@host:port"
        guard let atIdx = decoded.firstIndex(of: "@") else { return nil }
        let cred = String(decoded[decoded.startIndex..<atIdx])
        let hostPort = String(decoded[decoded.index(after: atIdx)...])
        guard let colonIdx = cred.firstIndex(of: ":") else { return nil }
        let method = String(cred[cred.startIndex..<colonIdx])
        let password = String(cred[cred.index(after: colonIdx)...])
        guard let portIdx = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[hostPort.startIndex..<portIdx])
        let port = String(hostPort[hostPort.index(after: portIdx)...])
        guard !method.isEmpty, !password.isEmpty, !host.isEmpty, !port.isEmpty else { return nil }

        var p = LocalProxy(name: name.isEmpty ? host : name, kind: .ss)
        p.server = host
        p.port = port
        p.cipher = method
        p.password = password
        return p
    }

    // MARK: - 共用小工具

    /// URL-safe / 标准 base64 都试，并补齐缺失的 `=` padding
    /// （分享链接里的 base64 经常被各种工具裁掉了 padding）。
    private static func base64Decode(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = t.count % 4
        if padding > 0 { t += String(repeating: "=", count: 4 - padding) }
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func queryDict(_ comps: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in comps.queryItems ?? [] where item.value != nil {
            result[item.name] = item.value!
        }
        return result
    }

    private static func displayName(_ comps: URLComponents, fallback: String) -> String {
        let f = comps.fragment?.removingPercentEncoding ?? comps.fragment ?? ""
        return f.isEmpty ? fallback : f
    }

    /// 把 "...#remark" 拆成 (前半部分, URL-decode 后的 remark)；没有 # 就 remark 为空。
    private static func splitFragment(_ s: String) -> (String, String) {
        guard let hashIdx = s.firstIndex(of: "#") else { return (s, "") }
        let main = String(s[s.startIndex..<hashIdx])
        let frag = String(s[s.index(after: hashIdx)...])
        return (main, frag.removingPercentEncoding ?? frag)
    }
}
