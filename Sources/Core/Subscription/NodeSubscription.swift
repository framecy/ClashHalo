import Foundation

/// Base64 编码的「纯节点订阅」（`vless://` / `hysteria2://` / `vmess://` … 每行一个
/// 分享链接）→ 可直接交给 mihomo 的 YAML 配置。
///
/// 为什么需要这一层：mihomo 只吃 YAML。大量机场/自建面板给的订阅是 `.txt` +
/// base64 编码的分享链接列表（HTTP 头就是 `text/plain`），mihomo 拿它当配置会直接
/// 解析失败；`ConfigStore` 旧实现下载后用 `content.contains(":")` 判有效、用
/// `looksLikeMihomoConfig` 拒刷新，于是这类订阅「始终无法使用」——base64 字母表
/// 不含冒号，连导入这一步都过不去。
///
/// 纯逻辑：无网络、无文件、无 MainActor、无 AppKit。`Tests/NodeSubscription`
/// 直接编译本文件做断言（`Scripts/run-tests.sh` 登记 `nodesubscription-tests`）。
public enum NodeSubscription {

    // MARK: - 判定

    public enum Kind: Equatable {
        /// 已经是 mihomo YAML（含 `proxies:` / `proxy-groups:` 等顶层键）。
        case mihomoConfig
        /// base64（或明文）的分享链接列表。
        case shareLinks
        /// 两者都不是（HTML 错误页、空响应等）。
        case unknown
    }

    /// 支持的分享链接 scheme。`ssr` 故意不在列表里：mihomo 的 ssr 字段需要
    /// 二次 base64 拆解，本轮不做，宁可如实报告「暂不支持」也不生成半截配置。
    static let supportedSchemes: Set<String> = [
        "vless", "vmess", "trojan", "hysteria2", "hy2", "hysteria", "ss", "tuic"
    ]

    public static func detect(_ text: String) -> Kind {
        if looksLikeMihomoConfig(text) { return .mihomoConfig }
        if let decoded = decodeBase64(text), containsShareLink(decoded) { return .shareLinks }
        if containsShareLink(text) { return .shareLinks }
        return .unknown
    }

    /// 与 `ConfigStore.looksLikeMihomoConfig` 同口径的顶层键检查（此处单独一份
    /// 是为了让本文件保持零依赖；两处的键集合必须同步）。
    static func looksLikeMihomoConfig(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { return false }
        for raw in content.components(separatedBy: "\n") {
            guard !raw.hasPrefix(" "), !raw.hasPrefix("\t") else { continue }
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("proxies:") || t.hasPrefix("proxy-groups:") || t.hasPrefix("rules:")
                || t.hasPrefix("mixed-port:") || t.hasPrefix("port:") || t.hasPrefix("socks-port:") {
                return true
            }
        }
        return false
    }

    public static func isShareLink(_ line: String) -> Bool {
        guard let range = line.range(of: "://") else { return false }
        let scheme = line[line.startIndex..<range.lowerBound].lowercased()
        return supportedSchemes.contains(scheme)
    }

    static func containsShareLink(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { isShareLink($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Base64

    /// 解 base64，容忍：URL-safe 字母表、缺失 padding、换行/回车、首尾空白。
    /// 不是 base64 或字节不是 UTF-8 时返回 nil。
    public static func decodeBase64(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "\r", with: "")
        s = s.replacingOccurrences(of: "\n", with: "")
        s = s.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem != 0 { s += String(repeating: "=", count: 4 - rem) }
        // 空 Data 也要判失败：`.ignoreUnknownCharacters` 会把纯垃圾（`!!!!`）
        // 全部忽略，得到一个 0 字节结果，`String(data:)` 随即返回 ""。
        guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - 转换

    public struct Render {
        /// 完整 mihomo 配置；nil 表示没有任何一个节点解析成功。
        public var yaml: String?
        public var nodeCount: Int
        /// 逐条失败原因（协议不支持 / 字段缺失 / base64 坏），直接展示给用户。
        public var skipped: [String]
    }

    /// `text` 是订阅原始响应体：base64 或明文分享链接列表。
    public static func render(_ text: String, groupName: String = "PROXY") -> Render {
        let (proxies, skipped) = parseProxies(text)
        guard !proxies.isEmpty else {
            return Render(yaml: nil, nodeCount: 0, skipped: skipped)
        }
        return Render(yaml: compose(proxies, groupName: groupName), nodeCount: proxies.count, skipped: skipped)
    }

    /// 只产出 `proxies:` 列表——mihomo 本地 file provider 的文件格式。
    /// 用在「配置里那条 http provider 指向 base64 订阅」的场景：整份配置不能换，
    /// 只把节点来源换成这个文件（provider 名与 `use:` 引用保持不变）。
    public static func renderProviderFile(_ text: String) -> Render {
        let (proxies, skipped) = parseProxies(text)
        guard !proxies.isEmpty else {
            return Render(yaml: nil, nodeCount: 0, skipped: skipped)
        }
        return Render(yaml: composeProxies(proxies), nodeCount: proxies.count, skipped: skipped)
    }

    static func parseProxies(_ text: String) -> ([Proxy], [String]) {
        let decoded = decodeBase64(text) ?? text
        let lines = decoded
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var proxies: [Proxy] = []
        var skipped: [String] = []
        var used = Set<String>(["PROXY", "自动选择", "DIRECT", "REJECT"])

        for line in lines {
            guard isShareLink(line) else {
                let scheme = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "?"
                if line.hasPrefix("ssr://") {
                    skipped.append("ssr:// 暂不支持，请让订阅源提供 mihomo 配置")
                } else {
                    skipped.append("无法识别的一行（\(scheme.prefix(16))…）")
                }
                continue
            }
            do {
                var p = try parse(line)
                p.name = uniqueName(p.name, used: &used)
                proxies.append(p)
            } catch let e as ParseError {
                skipped.append(e.message)
            } catch {
                skipped.append("解析失败：\(line.prefix(12))…")
            }
        }
        return (proxies, skipped)
    }

    // MARK: - 单个分享链接 → Proxy

    struct ParseError: Error { let message: String }

    struct Proxy {
        var name: String
        var type: String
        var server: String
        var port: Int
        var fields: [(String, YamlValue)]
    }

    indirect enum YamlValue {
        case scalar(String)
        case block([(String, YamlValue)])
    }

    static func parse(_ raw: String) throws -> Proxy {
        guard let range = raw.range(of: "://") else {
            throw ParseError(message: "缺少 ://")
        }
        let scheme = raw[raw.startIndex..<range.lowerBound].lowercased()
        switch scheme {
        case "vless":            return try parseVLESS(raw)
        case "hysteria2", "hy2": return try parseHysteria2(raw)
        case "hysteria":         return try parseHysteria(raw)
        case "vmess":            return try parseVMess(raw)
        case "trojan":           return try parseTrojan(raw)
        case "ss":               return try parseShadowsocks(raw)
        case "tuic":             return try parseTUIC(raw)
        default:
            throw ParseError(message: "\(scheme):// 暂不支持")
        }
    }

    // MARK: vless

    private static func parseVLESS(_ raw: String) throws -> Proxy {
        guard let c = URLComponents(string: raw),
              let host = c.host, !host.isEmpty,
              let port = c.port,
              let uuid = c.user, !uuid.isEmpty else {
            throw ParseError(message: "vless：缺少 uuid / 服务器 / 端口")
        }
        let q = queryMap(c)
        let security = (q["security"] ?? "none").lowercased()
        let network = (q["type"] ?? q["network"] ?? "tcp").lowercased()

        var fields: [(String, YamlValue)] = [("uuid", .scalar(quote(uuid)))]

        if security == "tls" || security == "reality" || security == "xtls" {
            fields.append(("tls", .scalar("true")))
        }
        if let sni = firstNonEmpty(q["sni"], q["servername"], q["peer"]) {
            fields.append(("servername", .scalar(quote(sni))))
        }
        if let fp = firstNonEmpty(q["fp"], q["client-fingerprint"]) {
            fields.append(("client-fingerprint", .scalar(quote(fp))))
        }
        if let flow = firstNonEmpty(q["flow"]) {
            fields.append(("flow", .scalar(quote(flow))))
        }
        if q["allowinsecure"] == "1" || q["insecure"] == "1" {
            fields.append(("skip-cert-verify", .scalar("true")))
        }
        if security == "reality" {
            var reality: [(String, YamlValue)] = []
            if let pbk = firstNonEmpty(q["pbk"], q["publickey"]) {
                reality.append(("public-key", .scalar(quote(pbk))))
            }
            if let sid = firstNonEmpty(q["sid"], q["shortid"]) {
                reality.append(("short-id", .scalar(quote(sid))))
            }
            if !reality.isEmpty { fields.append(("reality-opts", .block(reality))) }
        }

        try appendTransport(network: network, query: q, into: &fields)
        return Proxy(name: displayName(c.fragment, fallback: host), type: "vless",
                     server: host, port: port, fields: fields)
    }

    // MARK: hysteria2 / hysteria

    private static func parseHysteria2(_ raw: String) throws -> Proxy {
        guard let c = URLComponents(string: raw),
              let host = c.host, !host.isEmpty,
              let port = c.port,
              let password = c.user, !password.isEmpty else {
            throw ParseError(message: "hysteria2：缺少密码 / 服务器 / 端口")
        }
        let q = queryMap(c)
        var fields: [(String, YamlValue)] = [("password", .scalar(quote(password)))]
        let sni = firstNonEmpty(q["sni"], q["peer"]) ?? host
        fields.append(("sni", .scalar(quote(sni))))
        if q["insecure"] == "1" || q["allowinsecure"] == "1" {
            fields.append(("skip-cert-verify", .scalar("true")))
        }
        if let obfs = firstNonEmpty(q["obfs"]) {
            fields.append(("obfs", .scalar(quote(obfs))))
            if let pw = firstNonEmpty(q["obfs-password"], q["obfs-pw"]) {
                fields.append(("obfs-password", .scalar(quote(pw))))
            }
        }
        if let up = firstNonEmpty(q["up"]) { fields.append(("up", .scalar(quote(bandwidth(up))))) }
        if let down = firstNonEmpty(q["down"]) { fields.append(("down", .scalar(quote(bandwidth(down))))) }
        return Proxy(name: displayName(c.fragment, fallback: host), type: "hysteria2",
                     server: host, port: port, fields: fields)
    }

    /// 旧 hysteria（v1）不是 mihomo 的 `hysteria2` 类型，混用会得到一条永远
    /// 连不上的节点。留在这里只为了给出准确原因。
    private static func parseHysteria(_ raw: String) throws -> Proxy {
        throw ParseError(message: "hysteria://（v1）暂不支持，请让订阅源提供 hysteria2")
    }

    // MARK: vmess

    private static func parseVMess(_ raw: String) throws -> Proxy {
        let body = String(raw.dropFirst("vmess://".count))
        guard let json = decodeBase64(body),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError(message: "vmess：不是合法的 base64 JSON")
        }
        func str(_ k: String) -> String? {
            if let s = obj[k] as? String { return s }
            if let i = obj[k] as? Int { return String(i) }
            return nil
        }
        guard let server = str("add"), !server.isEmpty,
              let portText = str("port"), let port = Int(portText),
              let uuid = str("id"), !uuid.isEmpty else {
            throw ParseError(message: "vmess：缺少 add / port / id")
        }
        let network = (str("net") ?? "tcp").lowercased()
        let tlsOn = (str("tls") ?? "").lowercased() == "tls"
        var fields: [(String, YamlValue)] = [
            ("uuid", .scalar(quote(uuid))),
            ("alterId", .scalar(str("aid") ?? "0")),
            ("cipher", .scalar(quote(str("scy") ?? "auto")))
        ]
        if tlsOn {
            fields.append(("tls", .scalar("true")))
            let servername = firstNonEmpty(str("sni"), str("host"))
            if let servername { fields.append(("servername", .scalar(quote(servername)))) }
        }
        if let alpn = firstNonEmpty(str("alpn")) {
            fields.append(("alpn", .scalar(listScalar(alpn))))
        }
        var q: [String: String] = [:]
        if let host = str("host") { q["host"] = host }
        if let path = str("path") { q["path"] = path }
        try appendTransport(network: network, query: q, into: &fields)
        return Proxy(name: displayName(str("ps"), fallback: server), type: "vmess",
                     server: server, port: port, fields: fields)
    }

    // MARK: trojan

    private static func parseTrojan(_ raw: String) throws -> Proxy {
        guard let c = URLComponents(string: raw),
              let host = c.host, !host.isEmpty,
              let port = c.port,
              let password = c.user, !password.isEmpty else {
            throw ParseError(message: "trojan：缺少密码 / 服务器 / 端口")
        }
        let q = queryMap(c)
        let network = (q["type"] ?? "tcp").lowercased()
        var fields: [(String, YamlValue)] = [("password", .scalar(quote(password)))]
        if let sni = firstNonEmpty(q["sni"], q["peer"]) {
            fields.append(("sni", .scalar(quote(sni))))
        }
        if q["allowinsecure"] == "1" || q["insecure"] == "1" {
            fields.append(("skip-cert-verify", .scalar("true")))
        }
        if let alpn = firstNonEmpty(q["alpn"]) {
            fields.append(("alpn", .scalar(listScalar(alpn))))
        }
        try appendTransport(network: network, query: q, into: &fields)
        return Proxy(name: displayName(c.fragment, fallback: host), type: "trojan",
                     server: host, port: port, fields: fields)
    }

    // MARK: ss

    private static func parseShadowsocks(_ raw: String) throws -> Proxy {
        var body = String(raw.dropFirst("ss://".count))
        var name = ""
        if let hash = body.firstIndex(of: "#") {
            name = percentDecode(String(body[body.index(after: hash)...]))
            body = String(body[..<hash])
        }
        if let qi = body.firstIndex(of: "?") { body = String(body[..<qi]) }

        var method = ""
        var password = ""
        var host = ""
        var port = 0

        if let at = body.firstIndex(of: "@") {
            // SIP002：userinfo 可能是 base64(method:password)，也可能是明文
            // `method:password`（注意其中的 `:` 会让 URLComponents 把前半段当用户）。
            let left = String(body[body.startIndex..<at])
            let hostPort = String(body[body.index(after: at)...])
            let decoded = decodeBase64(left)
            let credential = (decoded?.contains(":") == true) ? decoded! : percentDecode(left)
            guard let colon = credential.firstIndex(of: ":"),
                  let hp = splitHostPort(hostPort) else {
                throw ParseError(message: "ss：无法解析 method/password 或服务器端口")
            }
            method = String(credential[credential.startIndex..<colon])
            password = String(credential[credential.index(after: colon)...])
            host = hp.0; port = hp.1
        } else {
            // 旧格式：整段 base64(method:password@host:port)
            guard let decoded = decodeBase64(body),
                  let at = decoded.firstIndex(of: "@"),
                  let colon = decoded[decoded.startIndex..<at].firstIndex(of: ":") else {
                throw ParseError(message: "ss：不是合法的 SIP002 / base64 链接")
            }
            method = String(decoded[decoded.startIndex..<colon])
            password = String(decoded[decoded.index(after: colon)..<at])
            guard let hp = splitHostPort(String(decoded[decoded.index(after: at)...])) else {
                throw ParseError(message: "ss：服务器端口无法解析")
            }
            host = hp.0; port = hp.1
        }
        guard !method.isEmpty, !host.isEmpty, port > 0 else {
            throw ParseError(message: "ss：字段不完整")
        }
        let fields: [(String, YamlValue)] = [
            ("cipher", .scalar(quote(method))),
            ("password", .scalar(quote(password))),
            ("udp", .scalar("true"))
        ]
        if name.isEmpty { name = host }
        return Proxy(name: name, type: "ss", server: host, port: port, fields: fields)
    }

    // MARK: tuic

    private static func parseTUIC(_ raw: String) throws -> Proxy {
        guard let c = URLComponents(string: raw),
              let host = c.host, !host.isEmpty,
              let port = c.port,
              let uuid = c.user, !uuid.isEmpty,
              let password = c.password, !password.isEmpty else {
            throw ParseError(message: "tuic：缺少 uuid / password / 服务器 / 端口")
        }
        let q = queryMap(c)
        var fields: [(String, YamlValue)] = [
            ("uuid", .scalar(quote(uuid))),
            ("password", .scalar(quote(password)))
        ]
        if let sni = firstNonEmpty(q["sni"], q["peer"]) {
            fields.append(("sni", .scalar(quote(sni))))
        }
        if let alpn = firstNonEmpty(q["alpn"]) {
            fields.append(("alpn", .scalar(listScalar(alpn))))
        }
        if let cc = firstNonEmpty(q["congestion_control"], q["congestion-controller"]) {
            fields.append(("congestion-controller", .scalar(quote(cc))))
        }
        if let urm = firstNonEmpty(q["udp_relay_mode"], q["udp-relay-mode"]) {
            fields.append(("udp-relay-mode", .scalar(quote(urm))))
        }
        if q["allow_insecure"] == "1" || q["allowinsecure"] == "1" || q["insecure"] == "1" {
            fields.append(("skip-cert-verify", .scalar("true")))
        }
        return Proxy(name: displayName(c.fragment, fallback: host), type: "tuic",
                     server: host, port: port, fields: fields)
    }

    // MARK: - 传输层

    private static func appendTransport(network: String, query: [String: String],
                                        into fields: inout [(String, YamlValue)]) throws {
        switch network {
        case "ws", "websocket":
            fields.append(("network", .scalar("ws")))
            var opts: [(String, YamlValue)] = []
            if let path = firstNonEmpty(query["path"]) {
                opts.append(("path", .scalar(quote(path))))
            }
            if let host = firstNonEmpty(query["host"], query["ws-host"]) {
                opts.append(("headers", .block([("Host", .scalar(quote(host)))])))
            }
            if !opts.isEmpty { fields.append(("ws-opts", .block(opts))) }
        case "grpc":
            fields.append(("network", .scalar("grpc")))
            let service = firstNonEmpty(query["servicename"], query["serviceName"],
                                        query["grpc-service-name"], query["path"])
            if let service, !service.isEmpty {
                fields.append(("grpc-opts", .block([("grpc-service-name", .scalar(quote(service)))])))
            }
        case "h2", "http":
            fields.append(("network", .scalar("h2")))
            var opts: [(String, YamlValue)] = []
            if let path = firstNonEmpty(query["path"]) { opts.append(("path", .scalar(quote(path)))) }
            if let host = firstNonEmpty(query["host"]) {
                opts.append(("host", .block([("Host", .scalar(quote(host)))])))
            }
            if !opts.isEmpty { fields.append(("h2-opts", .block(opts))) }
        default:
            break   // tcp：mihomo 不需要额外字段
        }
    }

    // MARK: - 渲染

    private static func compose(_ proxies: [Proxy], groupName: String) -> String {
        var out: [String] = []
        out.append("mixed-port: 7890")
        out.append("allow-lan: false")
        out.append("mode: rule")
        out.append("log-level: info")
        out.append("external-controller: 127.0.0.1:9092")
        out.append("secret: \"\"")
        out.append("dns:")
        out.append("  enable: true")
        out.append("  enhanced-mode: fake-ip")
        out.append("  nameserver:")
        out.append("    - 119.29.29.29")
        out.append("    - 223.5.5.5")
        out.append(composeProxies(proxies))

        let names = proxies.map { quote($0.name) }
        out.append("proxy-groups:")
        out.append("  - name: \(quote(groupName))")
        out.append("    type: select")
        out.append("    proxies:")
        out.append("      - \(quote("自动选择"))")
        out.append("      - DIRECT")
        for n in names { out.append("      - \(n)") }
        out.append("  - name: \(quote("自动选择"))")
        out.append("    type: url-test")
        out.append("    url: https://www.gstatic.com/generate_204")
        out.append("    interval: 300")
        out.append("    tolerance: 50")
        out.append("    proxies:")
        for n in names { out.append("      - \(n)") }
        out.append("rules:")
        out.append("  - GEOIP,CN,DIRECT")
        out.append("  - MATCH,\(quote(groupName))")
        return out.joined(separator: "\n") + "\n"
    }

    /// `proxies:` 段落（file provider 文件就是它本身）。
    static func composeProxies(_ proxies: [Proxy]) -> String {
        var out: [String] = ["proxies:"]
        for p in proxies {
            out.append("  - name: \(quote(p.name))")
            out.append("    type: \(p.type)")
            out.append("    server: \(quote(p.server))")
            out.append("    port: \(p.port)")
            for (k, v) in p.fields {
                out.append(contentsOf: renderField(k, v, indent: 4))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func renderField(_ key: String, _ value: YamlValue, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .scalar(let s):
            return ["\(pad)\(key): \(s)"]
        case .block(let pairs):
            var out = ["\(pad)\(key):"]
            for (k, v) in pairs {
                out.append(contentsOf: renderField(k, v, indent: indent + 2))
            }
            return out
        }
    }

    // MARK: - 小工具

    static func quote(_ s: String) -> String { YamlScalar.quoteIfNeeded(s) }

    private static func queryMap(_ c: URLComponents) -> [String: String] {
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] {
            out[item.name.lowercased()] = item.value ?? ""
        }
        return out
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for v in values {
            if let v, !v.isEmpty { return v }
        }
        return nil
    }

    private static func displayName(_ fragment: String?, fallback: String) -> String {
        if let f = fragment, !f.trimmingCharacters(in: .whitespaces).isEmpty { return f }
        return fallback
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var i = 2
        while used.contains(candidate) {
            candidate = "\(name) (\(i))"
            i += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    /// hysteria2 的 `up=50` / `up=50 Mbps` 统一成 mihomo 吃的 `50 Mbps`。
    private static func bandwidth(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.rangeOfCharacter(from: CharacterSet.letters) != nil { return t }
        return "\(t) Mbps"
    }

    /// 逗号分隔的 query 值 → YAML flow 列表（`[h3, h2]` 形态不引号时安全，
    /// 但值本身可能含特殊字符，这里逐项 quote）。
    private static func listScalar(_ raw: String) -> String {
        let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let rendered = items.map { quote($0) }
        return "[" + rendered.joined(separator: ", ") + "]"
    }

    /// `host:port` / `[v6]:port` → (host, port)。
    static func splitHostPort(_ raw: String) -> (String, Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), port > 0 else { return nil }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        let portText = String(s[s.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portText), port > 0 else { return nil }
        return (host, port)
    }
}
