import Foundation

/// 把 `proxy-providers` 里一条 http provider 改写成「本地文件 provider」。
///
/// 为什么需要它：mihomo 的 http provider 只接受 `proxies:` 结构的 YAML，而一大类
/// 订阅（`.txt` + base64 编码的 `vless://` / `hysteria2://` 列表）根本不是 YAML。
/// 内核把 base64 当配置解析失败 → 该 provider 永远 0 节点 → 引用了它的策略组
/// 全空。现场表现为「订阅已经添加、状态也显示在拉取，但一个节点都用不了」。
///
/// 做法：由 App 下载并转换成 `proxies:` 文件，配置里只留 `type: file` + `path:`，
/// provider 名与引用关系（`use: [名字]`）全部不变——用户的策略组、规则一条都不用改。
///
/// 纯逻辑（只做文本行扫描），无 IO、无 MainActor。回归 `providerrewrite-tests`。
public enum ProviderRewrite {

    public struct Result {
        public var yaml: String
        /// 改写前的 provider 定义块（便于日志/校验）
        public var changed: Bool
    }

    /// `yaml` 是完整配置文本；`name` 是 provider 名；`filePath` 是 mihomo 视角的
    /// 路径（相对 `-d` 工作目录，如 `./provider-files/us-lh.yaml`）。
    ///
    /// 返回 nil 表示：没有 `proxy-providers:` 块、块里没有这个 name、或该
    /// provider 用的是 flow 映射（`{…}`）——后者的改写不在本函数的行扫描能力内，
    /// 宁可如实失败也不产出一份半改的配置。
    public static func convertToFile(_ yaml: String, name: String, filePath: String) -> Result? {
        var lines = yaml.components(separatedBy: "\n")
        guard let found = locate(&lines, name: name) else { return nil }
        let (start, end, providerIndent) = (found.start, found.end, found.indent)

        // flow 形式（`name: {type: http, url: …}`）不支持行扫描改写
        let headBody = String(lines[start].dropFirst(providerIndent))
        if let colon = headBody.firstIndex(of: ":") {
            let rest = headBody[headBody.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("{") { return nil }
        }

        // 直接子键的缩进：取块内第一个子键；没有子键则按 +2 处理
        let directIndent = directKeyIndent(lines, start: start, end: end, providerIndent: providerIndent)
        let pad = String(repeating: " ", count: directIndent)
        let quotedPath = YamlScalar.quoteIfNeeded(filePath)

        var body: [String] = []
        var wrotePath = false
        var sawType = false

        for i in (start + 1)..<end {
            let line = lines[i]
            guard let (indent, key) = keyLine(line), indent == directIndent else {
                body.append(line)   // 嵌套块（health-check 等）原样保留
                continue
            }
            switch key {
            case "type":
                sawType = true
                body.append("\(pad)type: file")
                body.append("\(pad)path: \(quotedPath)")
                wrotePath = true
            case "path":
                if !wrotePath {
                    body.append("\(pad)path: \(quotedPath)")
                    wrotePath = true
                }
            case "url", "interval":
                // http 专属字段：file provider 不认识
                continue
            default:
                body.append(line)
            }
        }

        if !sawType {
            body.insert("\(pad)type: file", at: 0)
            if !wrotePath { body.insert("\(pad)path: \(quotedPath)", at: 1) }
        }

        var out = lines
        out.replaceSubrange((start + 1)..<end, with: body)
        return Result(yaml: out.joined(separator: "\n"), changed: true)
    }

    /// 读某个 provider 当前的 http url（改写前的源地址，用于刷新时重新下载）。
    public static func httpURL(_ yaml: String, name: String) -> String? {
        var lines = yaml.components(separatedBy: "\n")
        guard let found = locate(&lines, name: name) else { return nil }
        let (start, end, providerIndent) = (found.start, found.end, found.indent)
        let directIndent = directKeyIndent(lines, start: start, end: end, providerIndent: providerIndent)
        for i in (start + 1)..<end {
            let line = lines[i]
            guard let (indent, key) = keyLine(line), indent == directIndent, key == "url" else { continue }
            let body = String(line.dropFirst(indent))
            guard let colon = body.firstIndex(of: ":") else { continue }
            var value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = unquote(YamlScalar.stripInlineComment(value))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 该 provider 当前是否已经是 file 类型（幂等：重复转换不再改写）。
    public static func isFileProvider(_ yaml: String, name: String) -> Bool {
        var lines = yaml.components(separatedBy: "\n")
        guard let found = locate(&lines, name: name) else { return false }
        let (start, end, providerIndent) = (found.start, found.end, found.indent)
        let directIndent = directKeyIndent(lines, start: start, end: end, providerIndent: providerIndent)
        for i in (start + 1)..<end {
            let line = lines[i]
            guard let (indent, key) = keyLine(line), indent == directIndent, key == "type" else { continue }
            let body = String(line.dropFirst(indent))
            guard let colon = body.firstIndex(of: ":") else { continue }
            let value = unquote(YamlScalar.stripInlineComment(
                String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            return value.lowercased() == "file"
        }
        return false
    }

    // MARK: - 块定位

    /// provider 块里「直接子键」的缩进。health-check / proxy / size 这类嵌套块
    /// 的键缩进更深，绝不能当成 type/url 来读——它们中间就有一个同名的 `url:`。
    private static func directKeyIndent(_ lines: [String], start: Int, end: Int,
                                        providerIndent: Int) -> Int {
        for i in (start + 1)..<end {
            if let (indent, _) = keyLine(lines[i]), indent > providerIndent { return indent }
        }
        return providerIndent + 2
    }

    /// 定位 `proxy-providers` 块内某个 provider 的 [start, end) 与它的键缩进。
    /// 三处调用（改写 / 读源 / 查类型）共用同一口径——各自重算一遍块边界正是
    /// 「health-check 的 url 被当成源地址」这类 bug 的来源。
    private static func locate(_ lines: inout [String], name: String)
        -> (start: Int, end: Int, indent: Int)? {
        guard let blockStart = lines.firstIndex(where: { isTopLevelKey($0, "proxy-providers") }) else {
            return nil
        }
        var blockEnd = lines.count
        for i in (blockStart + 1)..<lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { blockEnd = i; break }
        }

        var start: Int?
        var indent = 0
        for i in (blockStart + 1)..<blockEnd {
            guard let (ind, key) = keyLine(lines[i]) else { continue }
            if key == name { start = i; indent = ind; break }
        }
        guard let s = start else { return nil }

        var end = blockEnd
        for i in (s + 1)..<blockEnd {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let ind = line.prefix(while: { $0 == " " }).count
            if ind <= indent, keyLine(line) != nil { end = i; break }
        }
        return (s, end, indent)
    }

    // MARK: - 行扫描小工具

    /// 顶层键（无缩进、非注释、非空）。
    private static func isTopLevelKey(_ line: String, _ key: String) -> Bool {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") else { return false }
        guard line.hasPrefix(key) else { return false }
        let rest = line.dropFirst(key.count)
        return rest.first == ":"
    }

    /// `  "US-LH":` / `    type: http` → (缩进, 去引号键名)。值里的冒号不影响。
    private static func keyLine(_ line: String) -> (Int, String)? {
        guard !line.hasPrefix("\t") else { return nil }
        let indent = line.prefix(while: { $0 == " " }).count
        let body = String(line.dropFirst(indent))
        guard !body.isEmpty, !body.hasPrefix("#") else { return nil }
        // `- name: x` 这类列表项不是 provider 键
        guard !body.hasPrefix("- ") else { return nil }
        guard let colon = body.firstIndex(of: ":") else { return nil }
        var key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        key = unquote(key)
        return (indent, key)
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
