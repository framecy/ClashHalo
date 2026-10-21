import Foundation

/// 基于游标的词法行解析器，用于安全替换 YAML 中的 `rules:` 节点，
/// 100% 保护其上下的所有配置（proxies, proxy-groups, 甚至文件头部的注释）。
public final class YamlRuleASTEngine {
    
    public enum EngineError: Error {
        case fileReadError
        case parseError(String)
    }
    
    /// mihomo 认可的规则**参数**（写在第 4 个字段）。除此之外的备注一律写成
    /// YAML 行尾注释：第 4 个字段是参数槽，把「公司内网」这类散文写进去，
    /// 内核不会报错（2026-10-20 实测 `-t` 通过）但语义是错的，而且与真实选项名
    /// 撞车时会静默改变行为（备注写成 `src` 就真成了参数）。
    static let ruleParameterTokens: Set<String> = ["no-resolve", "src"]

    /// 将 RuleNode 序列化为符合 Clash 规范的字符串
    public static func serialize(node: RuleNode) -> String {
        let prefix = node.isEnabled ? "-" : "# -"
        let rawNote = node.note?.trimmingCharacters(in: .whitespaces) ?? ""
        let parameter: String? = ruleParameterTokens.contains(rawNote.lowercased()) ? rawNote : nil
        let comment: String? = (parameter == nil && !rawNote.isEmpty) ? rawNote : nil

        func line(_ body: String) -> String {
            var out = "\(prefix) \(body)"
            if let parameter { out += ",\(parameter)" }
            if let comment { out += " # \(comment)" }
            return out
        }

        // MATCH 规则无需 match 参数
        if node.type == .match {
            let actionStr = node.action == .proxy ? (node.proxyGroup ?? "PROXY") : node.action.rawValue
            return line("MATCH,\(actionStr)")
        }

        let actionStr = node.action == .proxy ? (node.proxyGroup ?? "PROXY") : node.action.rawValue
        return line("\(node.type.rawValue),\(node.match),\(actionStr)")
    }

    /// 取行尾注释（`#` 之后的内容）。与 `YamlScalar.stripInlineComment` 同一口径：
    /// 只认空白之后的 `#`，引号开头的不算注释。用于把注释读回 `note`，
    /// 保证「写出去 → 读回来」不丢用户填的备注。
    static func trailingComment(in text: String) -> String? {
        guard let first = text.first, first != "'", first != "\"" else { return nil }
        var cut: String.Index?
        for sep in [" #", "\t#"] {
            if let r = text.range(of: sep), cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
        }
        guard let c = cut else { return nil }
        // `c` 是空白字符的位置，注释正文在 `#` 之后。
        let hash = text.index(after: c)
        guard text[hash] == "#" else { return nil }
        let comment = text[text.index(after: hash)...].trimmingCharacters(in: .whitespaces)
        return comment.isEmpty ? nil : comment
    }
    
    /// 将单行规则反序列化为 RuleNode
    public static func parseLine(_ line: String) -> RuleNode? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isEnabled = !trimmed.hasPrefix("#")
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        guard cleaned.hasPrefix("-") else { return nil }
        
        var content = cleaned.dropFirst().trimmingCharacters(in: .whitespaces)
        // 先取出可能的行尾注释：它可能是用户填的备注（见 serialize）。
        let commentNote = Self.trailingComment(in: content)
        // YAML semantics via YamlScalar: a `#` starts a comment only after
        // whitespace and never inside a quoted scalar — so `a.example.com#v2`
        // is data. The old first-`#` cut silently deleted any rule whose value
        // contained `#` the moment the editor saved.
        content = YamlScalar.stripInlineComment(content)
        let parts = content.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil } // 至少 TYPE,ACTION (MATCH)
        
        let typeStr = parts[0]
        guard let type = MihomoRuleType(rawValue: typeStr.uppercased()) else { return nil }
        
        if type == .match {
            let actionStr = parts[1].uppercased()
            var action: RuleAction = .proxy
            var proxyGroup: String? = parts[1]
            if actionStr == "DIRECT" { action = .direct; proxyGroup = nil }
            else if actionStr == "REJECT" { action = .reject; proxyGroup = nil }
            
            return RuleNode(type: type, match: "", action: action, sort: 0, isEnabled: isEnabled, proxyGroup: proxyGroup)
        }
        
        guard parts.count >= 3 else { return nil }
        let match = parts[1]
        let actionStr = parts[2].uppercased()
        
        var action: RuleAction = .proxy
        var proxyGroup: String? = parts[2] // 原始字符串，保留大小写
        if actionStr == "DIRECT" { action = .direct; proxyGroup = nil }
        else if actionStr == "REJECT" { action = .reject; proxyGroup = nil }
        
        let note = parts.count > 3 ? parts[3] : commentNote
        
        return RuleNode(type: type, match: match, action: action, sort: 0, isEnabled: isEnabled, proxyGroup: proxyGroup, note: note)
    }
    
    /// 获取文件中的所有规则
    public static func extractRules(from yaml: String) -> [RuleNode] {
        let lines = yaml.components(separatedBy: .newlines)
        var rules: [RuleNode] = []
        var inRulesBlock = false
        var inFence = false
        var sortIndex = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // App-managed fenced regions (Tailscale overlay) are opaque to the
            // editor: never parsed into user nodes, so saving can neither
            // reorder nor re-serialize them.
            if trimmed == TailscaleOverlay.fenceBegin { inFence = true; continue }
            if trimmed == TailscaleOverlay.fenceEnd { inFence = false; continue }
            if inFence { continue }

            let isTopLevelKey = !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if isTopLevelKey {
                inRulesBlock = line.hasPrefix("rules:")
                continue
            }

            if inRulesBlock {
                if let node = parseLine(line) {
                    var n = node
                    n.sort = sortIndex
                    rules.append(n)
                    sortIndex += 1
                }
            }
        }
        return rules
    }
    
    /// 在 `rules:` 块**首部**插入一行序列化后的规则，其余字节原样保留。
    ///
    /// 为什么需要它：`injectRules` 是「按节点列表重建整个规则块」，块内的注释行与
    /// 空行不属于任何节点，重建时会被丢弃——用真实配置实测一次空往返（extract →
    /// inject，不做任何修改）就是 925 行 → 875 行、43 行块内注释消失。连接页的
    /// 一键「独立制裁」只应增加一行规则，不该顺带删掉用户手写的证据注释。
    ///
    /// 只处理块状写法（`rules:` 裸键或 `rules: []`）。其它内联形式无法在不破坏语义
    /// 的前提下安全插入，返回 nil 让调用方如实报错，而不是写出一份坏 YAML。
    public static func insertRuleLine(_ line: String, into yaml: String) -> String? {
        let serialized = line.trimmingCharacters(in: .whitespaces)
        let lines = yaml.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count + 1)
        var inserted = false

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if !inserted, isTopLevelKey, trimmed.hasPrefix("rules:") {
                // 去掉行尾注释与空格再判断形态：`rules:` / `rules:  ` / `rules: # 备注`
                // 都是块状写法，`rules: []` 是空块，这两种才做手术。
                let head = YamlScalar.stripInlineComment(raw)
                    .replacingOccurrences(of: " ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if head == "rules:" {
                    out.append(raw)          // 原行照抄，行尾注释不能丢
                    out.append("  " + serialized)
                    inserted = true
                    continue
                }
                if head == "rules:[]" {
                    out.append("rules:")
                    out.append("  " + serialized)
                    inserted = true
                    continue
                }
                // 形如 `rules: [{…}]` 的内联数组：不做手术，交由调用方报错。
                return nil
            }
            out.append(raw)
        }

        guard inserted else {
            // 没有 rules: 块：末尾补一个（与 injectRules 的兜底一致）。
            if let last = out.last, !last.isEmpty { out.append("") }
            out.append("rules:")
            out.append("  " + serialized)
            return out.joined(separator: "\n")
        }
        return out.joined(separator: "\n")
    }

    /// 删除 `rules:` 块内匹配 `type + match` 的行，其余字节原样保留
    /// （含块内注释、空行与 Tailscale fence）。
    ///
    /// 判据复用 `parseLine`，保证「能删掉的」与规则页「能读出来的」是同一套理解，
    /// 不引入第二套 YAML 解析。
    public static func removeRuleLines(type: MihomoRuleType, match: String, from yaml: String) -> String {
        let lines = yaml.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inRulesBlock = false
        var inFence = false

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == TailscaleOverlay.fenceBegin || trimmed == TailscaleOverlay.fenceEnd {
                inFence = (trimmed == TailscaleOverlay.fenceBegin)
                out.append(raw)
                continue
            }
            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")
            if isTopLevelKey {
                inRulesBlock = trimmed == "rules:" || trimmed.hasPrefix("rules:")
                out.append(raw)
                continue
            }
            if inRulesBlock, !inFence, let node = parseLine(raw),
               node.type == type, node.match == match {
                continue  // 丢弃这一条同匹配规则；注释与空行不受影响
            }
            out.append(raw)
        }
        return out.joined(separator: "\n")
    }

    /// 按节点列表重写 `rules:` 块，**保留块内注释与空行**（注释跟随它原本描述的那条规则）。
    ///
    /// 这是 `injectRules` 的替代品，给规则页保存用。`injectRules` 把整个块按节点重建，
    /// 块内注释/空行不属于任何节点，于是每次保存都被清掉——真实配置实测一次空往返
    /// 925 行 → 875 行、含 `#` 的行 161 → 119 行。那些注释正是用户手写的证据链
    /// （「某域名 12 次 i/o timeout，故提前放行」），不能因为点一次保存就消失。
    ///
    /// 语义：
    /// - 注释/空行按「它后面紧邻的那条规则」归属；规则被删除时，注释转交给原本紧随
    ///   其后的存活规则，末尾无处可去则留在块尾——**任何情况下注释都不丢**。
    /// - Tailscale fence 区整段视为不透明内容，原样保留（与 `injectRules` 一致）。
    /// - 未改动的规则沿用原始行文本（缩进、行尾写法逐字节不变）。因此「打开规则页
    ///   不做任何修改直接保存」得到的文件与原文件完全一致。
    public static func injectRulesPreservingComments(_ nodes: [RuleNode],
                                                     into yaml: String,
                                                     loadedNodes: [RuleNode]) throws -> String {
        let lines = yaml.components(separatedBy: .newlines)
        var out: [String] = []
        out.reserveCapacity(lines.count + nodes.count)

        var inRulesBlock = false
        var rulesKeyLine: String? = nil
        var rows: [BlockRow] = []
        var fenceBuffer: [String]? = nil
        var blockDone = false

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // fence 区整段不透明：块内进 rows，块外原样输出。
            if trimmed == TailscaleOverlay.fenceBegin {
                fenceBuffer = [raw]
                continue
            }
            if fenceBuffer != nil {
                fenceBuffer?.append(raw)
                if trimmed == TailscaleOverlay.fenceEnd {
                    let block = (fenceBuffer ?? []).joined(separator: "\n")
                    fenceBuffer = nil
                    if inRulesBlock { rows.append(.plain(block)) } else { out.append(block) }
                }
                continue
            }

            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if isTopLevelKey {
                if inRulesBlock, !blockDone {
                    out.append(contentsOf: renderBlock(nodes: nodes, loadedNodes: loadedNodes, rows: rows))
                    blockDone = true
                }
                let startsRules = trimmed == "rules:" || (trimmed.hasPrefix("rules:") && !trimmed.hasPrefix("rules: ["))
                if startsRules {
                    inRulesBlock = true
                    rulesKeyLine = raw
                    rows = []
                } else {
                    inRulesBlock = false
                }
                out.append(raw)
                continue
            }

            if inRulesBlock {
                // 第 k 个能解析成规则的块内行，对应 load() 时的第 k 个节点。
                let parsedCount = rows.reduce(into: 0) { n, r in if case .rule = r { n += 1 } }
                if parseLine(raw) != nil, parsedCount < loadedNodes.count {
                    rows.append(.rule(id: loadedNodes[parsedCount].id, raw: raw))
                } else {
                    rows.append(.plain(raw))
                }
                continue
            }

            out.append(raw)
        }

        if inRulesBlock, !blockDone {
            out.append(contentsOf: renderBlock(nodes: nodes, loadedNodes: loadedNodes, rows: rows))
        }
        if let leftover = fenceBuffer { out.append(contentsOf: leftover) }

        // 没有 rules 块：末尾补建（与 injectRules 的兜底一致）。
        if rulesKeyLine == nil {
            if let last = out.last, !last.isEmpty { out.append("") }
            out.append("rules:")
            for node in nodes { out.append("  " + serialize(node: node)) }
        }
        return out.joined(separator: "\n")
    }

    /// 块内一行的归类。
    private enum BlockRow {
        /// 注释、空行，或整段 fence（可能含换行，原样输出）。
        case plain(String)
        /// 一条规则行；`id` 是 `load()` 时对应节点的 id。
        case rule(id: UUID, raw: String)
    }

    /// 重建 `rules:` 块。注释跟随规则移动，删掉的规则把注释移交给下一条存活规则。
    private static func renderBlock(nodes: [RuleNode],
                                    loadedNodes: [RuleNode],
                                    rows: [BlockRow]) -> [String] {
        var comments: [UUID: [String]] = [:]
        var pending: [String] = []

        for row in rows {
            switch row {
            case .plain(let text):
                pending.append(text)
            case .rule(let id, _):
                // 一条规则前的注释归它；若同一 id 已出现过（重复匹配的规则行），追加。
                comments[id, default: []].append(contentsOf: pending)
                pending = []
            }
        }
        var tail = pending

        // 被删掉的规则：注释移交给原本紧随其后的存活规则，末尾则留块尾。
        let alive = Set(nodes.map(\.id))
        var carry: [String] = []
        var effective: [UUID: [String]] = [:]
        for loaded in loadedNodes.reversed() {
            let own = comments[loaded.id] ?? []
            if alive.contains(loaded.id) {
                effective[loaded.id] = own + carry
                carry = []
            } else {
                carry = own + carry
            }
        }
        tail = carry + tail

        // `rules:` 这一行由扫描阶段原样输出（含行尾注释），这里只产出块内内容。
        var result: [String] = []

        // 原始行（用于未改动规则逐字节复用）与缩进。
        var rawByID: [UUID: String] = [:]
        for row in rows { if case .rule(let id, let raw) = row, rawByID[id] == nil { rawByID[id] = raw } }
        let loadedByID = Dictionary(loadedNodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for node in nodes {
            for extra in effective[node.id] ?? [] {
                result.append(contentsOf: extra.components(separatedBy: "\n"))
            }
            let unchanged = loadedByID[node.id].map { serialize(node: $0) == serialize(node: node) } ?? false
            if unchanged, let raw = rawByID[node.id] {
                result.append(raw)
            } else {
                let indent = rawByID[node.id].map { raw in
                    String(raw.prefix { $0 == " " || $0 == "\t" })
                } ?? "  "
                result.append(indent + serialize(node: node))
            }
        }
        for extra in tail {
            result.append(contentsOf: extra.components(separatedBy: "\n"))
        }
        return result
    }

    /// 将新的 RuleNode 列表安全注入到 YAML 字符串中
    public static func injectRules(_ nodes: [RuleNode], into yaml: String) throws -> String {
        let lines = yaml.components(separatedBy: .newlines)
        var newLines: [String] = []

        var inRulesBlock = false
        var inFence = false
        var rulesInjected = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced overlay regions inside the rules block must survive
            // editing verbatim — dropping them (the old behavior) broke the
            // overlay's strip∘apply idempotence and left injected rules
            // duplicated and unremovable. Outside the rules block the generic
            // pass-through below already keeps them.
            if trimmed == TailscaleOverlay.fenceBegin || trimmed == TailscaleOverlay.fenceEnd {
                inFence = (trimmed == TailscaleOverlay.fenceBegin)
                if inRulesBlock { newLines.append(line) }
                continue
            }
            if inFence {
                if inRulesBlock { newLines.append(line) }
                continue
            }

            let isTopLevelKey = !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if isTopLevelKey {
                if line.hasPrefix("rules:") {
                    inRulesBlock = true
                    newLines.append(line)

                    // 立刻注入新的规则
                    let sortedNodes = nodes.sorted { $0.sort < $1.sort }
                    for node in sortedNodes {
                        newLines.append("  " + serialize(node: node))
                    }
                    rulesInjected = true
                    continue
                } else {
                    inRulesBlock = false
                }
            }

            // 如果不在 rules 块内，保留原样
            if !inRulesBlock {
                newLines.append(line)
            }
            // 如果在 rules 块内，丢弃原来的子行（我们已经按节点列表重新序列化；
            // fence 区已在上方原样保留）
        }
        
        // 如果原文件没有 rules: 块，则在末尾追加
        if !rulesInjected {
            if !newLines.isEmpty && !newLines.last!.isEmpty {
                newLines.append("")
            }
            newLines.append("rules:")
            let sortedNodes = nodes.sorted { $0.sort < $1.sort }
            for node in sortedNodes {
                newLines.append("  " + serialize(node: node))
            }
        }
        
        return newLines.joined(separator: "\n")
    }
}
