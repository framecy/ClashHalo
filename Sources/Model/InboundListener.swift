import Foundation

// MARK: - 入站端口转发（mihomo `listeners:` 块）
//
// 纯逻辑：无 SwiftUI、无 MainActor、无文件读写、无内核交互，可单独编译进回归套件
// （`Tests/InboundListener`，登记在 `Scripts/run-tests.sh`）。
//
// 为什么单独成文件：这个块是**直接暴露到网络上的监听端口**。写错一个字段的后果
// 不是界面难看，而是把端口开到整个局域网（甚至校验通过、用户毫不知情）。
//
// 2026-10-20 用本机内核逐条实测（mihomo Meta v1.19.32）：
//   - 真正决定监听地址的是 `listen`，**`bind-address` 对 listener 无效**：
//     `listen: 127.0.0.1` → `TCP 127.0.0.1:18085`；`bind-address: 127.0.0.1` →
//     `TCP *:18081`（全网卡！）；**不写 listen 也是 `*`**。所以默认必须显式写
//     `listen: 127.0.0.1`，不能指望内核默认值。
//   - `network: tcp` 报 `'network' is not a slice` → 必须写成数组 `[tcp, udp]`。
//   - 缺 `target` 报 `listener 0: '' has unset fields: target`；重名报 `listener t ...`。
//   - 未知字段（如 `enabled:`）**不会报错但也不生效** → 开关只能靠注释掉整条。

enum ListenerType: String, CaseIterable {
    case tunnel
    case socks
    case http
    case mixed

    var label: String {
        switch self {
        case .tunnel: return "端口转发"
        case .socks:  return "SOCKS5"
        case .http:   return "HTTP"
        case .mixed:  return "混合"
        }
    }

    /// 只有 tunnel 需要目标地址。
    var needsTarget: Bool { self == .tunnel }
}

enum ListenerNetwork: String, CaseIterable, Hashable {
    case tcp, udp

    var label: String { self.rawValue.uppercased() }
}

struct InboundListener: Identifiable, Equatable {
    /// mihomo 里 `name` 是唯一键，也用于连接页「来源」段。
    var id: String { name }
    var name: String
    var type: ListenerType
    var port: Int
    /// `127.0.0.1`（仅本机）或 `0.0.0.0`（允许局域网）。
    var listen: String
    /// 仅 tunnel 使用，形如 `192.168.1.233:8080`。
    var target: String
    var network: Set<ListenerNetwork>
    var isEnabled: Bool

    var allowsLAN: Bool { listen == "0.0.0.0" }
    var networkText: String {
        // 顺序固定，避免每次渲染字符串顺序漂移。
        ListenerNetwork.allCases.filter { network.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    static let loopback = "127.0.0.1"
    static let anyAddress = "0.0.0.0"
}

enum InboundListenerStore {

    // MARK: - 解析

    /// 解析 `listeners:` 块。禁用条目（整条被 `#` 注释）也会被读出来，`isEnabled = false`。
    static func parse(from yaml: String) -> [InboundListener] {
        var result: [InboundListener] = []
        var inBlock = false
        var current: [String: String] = [:]
        var currentDisabled = false
        var currentNetwork: Set<ListenerNetwork> = []

        func flush() {
            if let name = current["name"], !name.isEmpty {
                result.append(InboundListener(
                    name: name,
                    type: ListenerType(rawValue: current["type"] ?? "tunnel") ?? .tunnel,
                    port: Int(current["port"] ?? "") ?? 0,
                    listen: current["listen"] ?? InboundListener.anyAddress,
                    target: current["target"] ?? "",
                    network: currentNetwork,
                    isEnabled: !currentDisabled))
            }
            current = [:]
            currentNetwork = []
            currentDisabled = false
        }

        for raw in yaml.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if isTopLevelKey {
                if inBlock { flush(); inBlock = false }
                let head = trimmed.replacingOccurrences(of: " ", with: "")
                if head == "listeners:" || head == "listeners:[]" { inBlock = true }
                continue
            }
            guard inBlock else { continue }

            // 条目起始：`- name: x` 或 `# - name: x`
            let disabled = trimmed.hasPrefix("#")
            var body = trimmed
            if disabled {
                body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard body.hasPrefix("- ") else {
                // 条目内字段；禁用条目内的字段同样带 `#`。
                if current["name"] != nil, let (k, v) = field(body) {
                    applyField(k, v, to: &current, network: &currentNetwork)
                }
                continue
            }
            flush()
            currentDisabled = disabled
            let rest = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if let (k, v) = field(rest) {
                applyField(k, v, to: &current, network: &currentNetwork)
            }
        }
        if inBlock { flush() }
        return result
    }

    private static func field(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        value = value.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private static func applyField(_ key: String, _ value: String,
                                   to current: inout [String: String],
                                   network: inout Set<ListenerNetwork>) {
        if key == "network" {
            network = parseNetwork(value)
        } else {
            current[key] = value
        }
    }

    /// 支持 `[tcp, udp]` 与 `tcp`（内核会拒绝后者为规则来源，但读回旧文件时不该崩）。
    static func parseNetwork(_ value: String) -> Set<ListenerNetwork> {
        let cleaned = value
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        let parts = cleaned.split(whereSeparator: { $0 == "," || $0 == " " })
        return Set(parts.compactMap { ListenerNetwork(rawValue: $0.lowercased()) })
    }

    // MARK: - 序列化

    /// 生成块内条目（不含 `listeners:` 头）。禁用条目整条注释掉并保留原内容，
    /// 因为 `enabled:` 这类未知字段内核既不报错也不生效。
    static func render(_ listeners: [InboundListener], indent: String = "  ") -> [String] {
        var lines: [String] = []
        for l in listeners {
            let p = l.isEnabled ? "" : "# "
            let inner = l.isEnabled ? "" : "# "
            lines.append("\(indent)\(p)- name: \(l.name)")
            lines.append("\(indent)\(inner)  type: \(l.type.rawValue)")
            lines.append("\(indent)\(inner)  port: \(l.port)")
            // 必须显式写 listen：不写默认绑 `*`（全网卡）。
            lines.append("\(indent)\(inner)  listen: \(l.listen)")
            if l.type.needsTarget, !l.target.isEmpty {
                lines.append("\(indent)\(inner)  target: \(l.target)")
            }
            lines.append("\(indent)\(inner)  network: [\(l.networkText)]")
        }
        return lines
    }

    /// 用给定的 listener 列表替换整份 YAML 里的 `listeners:` 块。
    /// - 没有该块：追加到文件末尾。
    /// - 列表为空：整块删除（不是留一个空 `listeners: []`，避免歧义）。
    /// - 内联形式（`listeners: [{…}]`）无法安全手术：返回 nil，调用方如实报错。
    static func replaceBlock(in yaml: String, with listeners: [InboundListener]) -> String? {
        let lines = yaml.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count + listeners.count * 6)
        var i = 0
        var replaced = false
        var sawInline = false

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            guard isTopLevelKey, trimmed.hasPrefix("listeners:") else {
                out.append(raw)
                i += 1
                continue
            }
            if replaced { return nil }   // 第二份 listeners 块：不敢猜，交调用方报错

            let head = trimmed.replacingOccurrences(of: " ", with: "")
            if head != "listeners:" && head != "listeners:[]" { sawInline = true; return nil }

            // 跳过原块（含其后的缩进行）
            var j = i + 1
            while j < lines.count {
                let l = lines[j]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { j += 1; continue }
                if l.hasPrefix(" ") || l.hasPrefix("\t") { j += 1; continue }
                break
            }
            if !listeners.isEmpty {
                out.append("listeners:")
                out.append(contentsOf: render(listeners))
            }
            replaced = true
            i = j
        }

        if sawInline { return nil }
        if !replaced, !listeners.isEmpty {
            if let last = out.last, !last.isEmpty { out.append("") }
            out.append("listeners:")
            out.append(contentsOf: render(listeners))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 校验

    /// 校验一条 listener。返回中文错误说明，`nil` 表示可写入。
    /// - Parameter reservedPorts: 已被其它功能占用的端口（混合端口 / 控制端口 …），
    ///   冲突时给出可读原因，而不是让内核在 reload 时报一个数字。
    static func validate(_ l: InboundListener,
                         existing: [InboundListener],
                         reservedPorts: [Int: String] = [:]) -> String? {
        let name = l.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "名称不能为空" }
        if name.contains(" ") { return "名称不能包含空格" }
        if name.contains(":") { return "名称不能包含冒号" }

        if existing.contains(where: { $0.name == name }) {
            return "已存在同名转发「\(name)」"
        }
        if !(1...65535).contains(l.port) {
            return "端口需在 1–65535 之间"
        }
        if let owner = existing.first(where: { $0.port == l.port && $0.isEnabled }), owner.name != name {
            return "端口 \(l.port) 已被「\(owner.name)」占用"
        }
        if let reason = reservedPorts[l.port] {
            return "端口 \(l.port) 已被\(reason)占用"
        }
        if l.network.isEmpty { return "至少选择 TCP 或 UDP" }
        if l.listen != InboundListener.loopback && l.listen != InboundListener.anyAddress {
            return "监听地址只能是 127.0.0.1 或 0.0.0.0"
        }
        if l.type.needsTarget {
            let t = l.target.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return "端口转发必须填写目标地址（IP:端口）" }
            guard let colon = t.lastIndex(of: ":") else { return "目标地址格式应为 IP:端口" }
            let host = String(t[t.startIndex..<colon])
            let portText = String(t[t.index(after: colon)...])
            if host.isEmpty { return "目标地址缺少主机" }
            guard let p = Int(portText), (1...65535).contains(p) else {
                return "目标端口需在 1–65535 之间"
            }
        } else if !l.target.isEmpty {
            return "\(l.type.label) 类型的入站不需要目标地址"
        }
        return nil
    }
}
