import Foundation

/// 手动添加 / 分享链接粘贴 / 从订阅节点分叉出来的本地节点——UI 表单操作的类型化
/// 模型，落盘时经 `toEntry()`/`from(_:)` 与 `EngineControl.LocalProxyEntry`
/// （顶层 `proxies:` 里的一条 flat key-value 记录）互转。
///
/// 范围限定：只覆盖 VMess / VLESS / Trojan / Shadowsocks / Hysteria2 五种协议的
/// TCP/TLS 直连字段。不支持 ws-opts / grpc-opts 传输层配置——这类节点的传输参数
/// 会随手改配置一起原样保留在 `EngineControl.LocalProxyEntry.extraLines` 里，
/// 但本表单不提供编辑它们的入口（后续按需加）。
struct LocalProxy: Identifiable, Equatable {
    var name: String
    var kind: Kind
    var server: String = ""
    /// 表单是文本输入，暂存字符串；保存前用 `AppModel`/表单校验层做数字校验。
    var port: String = ""
    var uuid: String = ""            // vmess / vless
    var alterId: String = "0"        // vmess
    var cipher: String = ""          // vmess（加密方式，默认 auto）/ ss（默认 aes-256-gcm）
    var password: String = ""        // trojan / ss / hysteria2
    var flow: String = ""            // vless（xtls flow，留空即不启用）
    var sni: String = ""             // trojan / vless / hysteria2 的 TLS SNI
    var skipCertVerify: Bool = false
    var tls: Bool = false            // vmess 的 TLS 开关（vless/hysteria2 恒为 true，trojan 协议本身即 TLS）
    var udp: Bool = true
    // REALITY（仅 vless）——`publicKey` 非空即视为启用。真实订阅里 REALITY 相当
    // 常见（VLESS 用它规避常规 TLS 指纹检测），fork-on-edit 必须能正确带出这三个
    // 字段，否则分叉出来的"本地副本"握手参数不全，看着正常、实际连不上。
    var publicKey: String = ""
    var shortId: String = ""
    var fingerprint: String = ""     // uTLS 指纹伪装，如 chrome/firefox/safari
    /// 非 nil = 从某个订阅节点分叉而来（fork-on-edit），值是原节点名。
    /// UI 用它显示"已分叉·不再跟随订阅"标识。
    var forkedFrom: String? = nil

    var id: String { name }

    enum Kind: String, CaseIterable, Identifiable, Equatable {
        case vmess, vless, trojan, ss, hysteria2
        var id: String { rawValue }
        var label: String {
            switch self {
            case .vmess: return "VMess"
            case .vless: return "VLESS"
            case .trojan: return "Trojan"
            case .ss: return "Shadowsocks"
            case .hysteria2: return "Hysteria2"
            }
        }
    }

    init(name: String = "", kind: Kind = .vmess) {
        self.name = name
        self.kind = kind
    }
}

extension LocalProxy {
    /// 组装成引擎层能写回 config.yaml 的 flat 字典。`preservingExtraLines`
    /// 传入编辑前读到的 `extraLines`（未知字段 / 嵌套块），原样带回去，
    /// 不因为这次编辑而把手改过的额外内容冲掉。
    func toEntry(preservingExtraLines extraLines: [String] = []) -> EngineControl.LocalProxyEntry {
        var fields: [String: String] = [
            "type": kind.rawValue,
            "server": server,
            "port": port,
            "udp": udp ? "true" : "false",
        ]
        switch kind {
        case .vmess:
            fields["uuid"] = uuid
            fields["alterId"] = alterId
            fields["cipher"] = cipher.isEmpty ? "auto" : cipher
            fields["tls"] = tls ? "true" : "false"
            if tls, !sni.isEmpty { fields["servername"] = sni }
        case .vless:
            fields["uuid"] = uuid
            if !flow.isEmpty { fields["flow"] = flow }
            fields["tls"] = "true"
            if !sni.isEmpty { fields["servername"] = sni }
            if !publicKey.isEmpty {
                fields["client-fingerprint"] = fingerprint.isEmpty ? "chrome" : fingerprint
            }
        case .trojan:
            fields["password"] = password
            if !sni.isEmpty { fields["sni"] = sni }
        case .ss:
            fields["password"] = password
            fields["cipher"] = cipher.isEmpty ? "aes-256-gcm" : cipher
        case .hysteria2:
            fields["password"] = password
            if !sni.isEmpty { fields["sni"] = sni }
        }
        if skipCertVerify { fields["skip-cert-verify"] = "true" }
        return EngineControl.LocalProxyEntry(
            name: name, fields: fields,
            realityPublicKey: publicKey.isEmpty ? nil : publicKey,
            realityShortId: shortId.isEmpty ? nil : shortId,
            extraLines: extraLines
        )
    }

    /// 从引擎层读回的条目重建表单模型。`type` 字段无法识别（不在五种协议内，
    /// 或是手改文件里的其它协议）时返回 nil——调用方应把这类节点当只读处理，
    /// 不允许在表单里打开编辑（会因为字段丢失而写坏）。
    static func from(_ entry: EngineControl.LocalProxyEntry) -> LocalProxy? {
        guard let typeStr = entry.fields["type"], let kind = Kind(rawValue: typeStr) else { return nil }
        var p = LocalProxy(name: entry.name, kind: kind)
        p.server = entry.fields["server"] ?? ""
        p.port = entry.fields["port"] ?? ""
        p.uuid = entry.fields["uuid"] ?? ""
        p.alterId = entry.fields["alterId"] ?? "0"
        p.cipher = entry.fields["cipher"] ?? ""
        p.password = entry.fields["password"] ?? ""
        p.flow = entry.fields["flow"] ?? ""
        p.sni = entry.fields["sni"] ?? entry.fields["servername"] ?? ""
        p.skipCertVerify = entry.fields["skip-cert-verify"] == "true"
        p.tls = entry.fields["tls"] == "true"
        p.udp = entry.fields["udp"] != "false"
        p.publicKey = entry.realityPublicKey ?? ""
        p.shortId = entry.realityShortId ?? ""
        p.fingerprint = entry.fields["client-fingerprint"] ?? ""
        return p
    }
}
