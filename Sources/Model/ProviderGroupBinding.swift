import Foundation

// MARK: - 订阅（proxy-provider）→ 策略组（proxy-group）归属
//
// 纯逻辑：无 SwiftUI、无文件 IO、无 MainActor，可单独编译进回归套件
// （`Tests/ProviderGroupBinding`，登记在 `Scripts/run-tests.sh`）。
//
// 为什么需要它：订阅节点只有被某个策略组的 `use:` 引用才会出现在「代理节点」
// 页。旧实现（`EngineControl.writeProxyProviders` 第 4 步）把**第一个**策略组的
// `use:` 整块重写成「当前全部 provider」——用户无法按组分配，改名还会静默退出
// 所有组。这里把「解析组 / 查归属 / 按目标归属改写 YAML」收敛成唯一入口。
//
// 解析口径与 `ProviderUsage` 完全一致（同一份行扫描，不引入第二套 YAML 理解）：
//   - 使用 ProviderUsage 的任意空格缩进 scanner，不再维护第二份组边界；
//   - `use:` 支持块状列表与带转义的内联数组两种写法；
//   - 不解析锚点、多行标量、`use: [` 换行续写的流式数组；看不懂的行原样保留。
//
// 改写原则（回归套件逐字节钉住）：
//   - 只动目标组里的 `use:`；未受影响的组、`proxies:`、`rules:`、注释全部原样；
//   - 已有条目顺序不重排，新条目追加到末尾；块内注释不删除；
//   - 名字统一加双引号写入；比较时走 `ProviderUsage.scalar` 去引号/注释。

enum ProviderGroupBinding {

    typealias Group = ProviderUsage.Group

    /// 读取与 ProviderUsage.groupNames 使用同一 scanner，不另建名称正则。
    static func groups(in yaml: String) -> [Group] { ProviderUsage.scanGroups(in: yaml) }

    /// IO 前能力预检；有不支持的组时不能“成功”返回一半改写。
    static func supportsRewrite(_ yaml: String,
                                desired: [String: Set<String>],
                                removed: Set<String>,
                                renamed: [String: String]) -> Bool {
        if desired.isEmpty && removed.isEmpty && renamed.isEmpty { return true }
        let lines = yaml.components(separatedBy: "\n")
        let parsed = groups(in: yaml)
        let names = Set(ProviderUsage.groupNames(in: yaml))
        guard desired.values.allSatisfy({ $0.isSubset(of: names) }) else { return false }
        if let section = ProviderConfiguration.section(in: lines, key: "proxy-groups") {
            let value = ProviderConfiguration.field(lines[section.lowerBound])?.value
            guard value == "" || value == "[]" else { return false }
            if value == "[]" { return desired.values.allSatisfy(\.isEmpty) }
            // 未识别的 alias 组可能继承 use；删改名必须拒绝，不能遗留悬空引用。
            let sequenceLines = ((section.lowerBound + 1)..<section.upperBound).filter {
                let text = ProviderConfiguration.clean(lines[$0])
                return text == "-" || text.hasPrefix("- ") || text.hasPrefix("-\t")
            }
            if let indent = sequenceLines.map({ ProviderConfiguration.indent(lines[$0]) }).min() {
                let count = sequenceLines.filter { ProviderConfiguration.indent(lines[$0]) == indent }.count
                if count != parsed.count { return false }
            }
        }
        for group in parsed where !group.canRewrite {
            if group.hasUnknownMembers { return false }
            if group.providers.contains(where: { removed.contains($0) || renamed[$0] != nil }) { return false }
            if !group.includesAllProviders && desired.contains(where: {
                $0.value.contains(group.name) != group.providers.contains($0.key)
            }) { return false }
        }
        return true
    }

    /// provider → 显式引用它的组名（按文件顺序，组内去重）。
    ///
    /// 只统计 `use:`；`include-all-providers` 组的成员来自全部订阅，不算显式引用
    /// （UI 另有展示，避免把「组里能看到节点」误报成「用户选了这个组」）。
    static func membership(in yaml: String) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for group in groups(in: yaml) {
            for provider in group.providers where !provider.isEmpty {
                if map[provider] == nil { map[provider] = [] }
                if map[provider]?.contains(group.name) == false {
                    map[provider]?.append(group.name)
                }
            }
        }
        return map
    }

    // MARK: - 改写

    /// 按目标归属改写 YAML。
    /// - `desired`: 本次要调整归属的 provider → 目标组集合（只包含被编辑的订阅）。
    /// - `removed`: 本次删除的 provider（从所有组的 `use:` 里清掉）。
    /// - `renamed`: 旧名 → 新名（先把引用原位换名，再按 `desired` 收敛）。
    ///
    /// 未出现在 `desired` 里的 provider 不受影响；`include-all-providers` 组跳过。
    static func rewrite(_ yaml: String,
                        desired: [String: Set<String>],
                        removed: Set<String>,
                        renamed: [String: String]) -> String {
        guard !desired.isEmpty || !removed.isEmpty || !renamed.isEmpty else { return yaml }
        guard supportsRewrite(yaml, desired: desired, removed: removed, renamed: renamed) else { return yaml }

        var lines = yaml.components(separatedBy: "\n")
        // 从后往前改：前面组的行号不受后面组增删的影响。
        for group in groups(in: yaml).reversed() {
            guard group.canRewrite else { continue }
            let affected = group.providers.contains { removed.contains($0) || renamed[$0] != nil }
                || (!group.includesAllProviders && desired.contains {
                    $0.value.contains(group.name) != group.providers.contains($0.key)
                })
            guard affected else { continue }
            var final: [String] = []
            var seen = Set<String>()
            var needsChange = false

            for entry in group.providers {
                let resolved = renamed[entry] ?? entry
                if resolved != entry { needsChange = true }
                if removed.contains(resolved) { needsChange = true; continue }
                if seen.insert(resolved).inserted {
                    final.append(resolved)
                } else {
                    needsChange = true
                }
            }

            // include-all-providers 的组不需要按 desired 增删（订阅本来就全含），
            // 但改名/删除仍需清理已有条目，否则旧名会变成悬空引用让 mihomo -t 失败。
            if !group.includesAllProviders {
                for provider in desired.keys.sorted() {
                    let wanted = desired[provider]?.contains(group.name) ?? false
                    let present = final.contains(provider)
                    if wanted && !present {
                        final.append(provider)
                        needsChange = true
                    } else if !wanted && present {
                        final.removeAll { $0 == provider }
                        needsChange = true
                    }
                }
            }

            // 目标里包含了被删的 provider：以 removed 为准。
            if final.contains(where: { removed.contains($0) }) {
                final.removeAll { removed.contains($0) }
                needsChange = true
            }

            guard needsChange else { continue }

            if let useLine = group.useLine {
                if group.useInline {
                    lines = rewriteInline(lines, useLine: useLine,
                                          indent: group.fieldIndent,
                                          final: final)
                } else {
                    lines = rewriteBlock(lines, group: group, final: final,
                                         renamed: renamed)
                }
            } else if !final.isEmpty {
                lines = insertUse(lines, group: group, final: final)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 改写内部

    private static func rewriteInline(_ lines: [String], useLine: Int, indent: Int,
                                      final: [String]) -> [String] {
        var out = lines
        guard useLine < out.count else { return out }
        if final.isEmpty {
            out.remove(at: useLine)
            return out
        }
        let (_, comment) = splitComment(out[useLine])
        let prefix = String(repeating: " ", count: indent)
        let items = final.map { "\"\(escape($0))\"" }.joined(separator: ", ")
        out[useLine] = prefix + "use: [" + items + "]" + comment
        return out
    }

    private static func rewriteBlock(_ lines: [String], group: Group, final: [String],
                                     renamed: [String: String]) -> [String] {
        guard let useLine = group.useLine else { return lines }
        var out = lines
        let itemIndent = group.itemIndent ?? (group.fieldIndent + 2)

        // 收集块状条目行（注释/空行跳过，遇到同缩进字段或组边界即结束）。
        var entryLines: [Int] = []
        var j = useLine + 1
        while j < out.count {
            let raw = out[j]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { j += 1; continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            if trimmed.hasPrefix("#") { j += 1; continue }
            if indent < group.fieldIndent || (indent == group.fieldIndent && !trimmed.hasPrefix("- ")) { break }
            if trimmed.hasPrefix("- ") { entryLines.append(j) }
            j += 1
        }

        // 逐条决定保留/换名/删除，保持原顺序。
        var emitted = Set<String>()
        var deleteIndexes: [Int] = []
        for idx in entryLines {
            let raw = out[idx]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(trimmed.dropFirst(2))
            guard let name = ProviderUsage.scalar(body) else { continue }
            let resolved = renamed[name] ?? name
            let shouldKeep = final.contains(resolved) && emitted.insert(resolved).inserted
            if shouldKeep {
                if resolved != name {
                    let indent = String(raw.prefix(while: { $0 == " " }))
                    let (_, comment) = splitComment(raw)
                    out[idx] = indent + "- \"\(escape(resolved))\"" + comment
                }
            } else {
                deleteIndexes.append(idx)
            }
        }
        for idx in deleteIndexes.reversed() { out.remove(at: idx) }

        // 追加新增条目：接在最后一个块状条目之后；没有条目就接在 use: 之后。
        let additions = final.filter { !emitted.contains($0) }
        if !additions.isEmpty {
            var insertAt = useLine + 1
            var k = useLine + 1
            while k < out.count {
                let raw = out[k]
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { k += 1; continue }
                let indent = raw.prefix(while: { $0 == " " }).count
                if trimmed.hasPrefix("#") { k += 1; continue }
                if indent < group.fieldIndent || (indent == group.fieldIndent && !trimmed.hasPrefix("- ")) { break }
                if trimmed.hasPrefix("- ") { insertAt = k + 1 }
                k += 1
            }
            let prefix = String(repeating: " ", count: itemIndent)
            let eol = out[useLine].hasSuffix("\r") ? "\r" : ""
            out.insert(contentsOf: additions.map { prefix + "- \"\(escape($0))\"" + eol }, at: insertAt)
        }

        // 最后一条也删掉：整块 use: 移除（块内注释/空行留给组，不误删）。
        if final.isEmpty {
            out.remove(at: useLine)
        }
        return out
    }

    private static func insertUse(_ lines: [String], group: Group, final: [String]) -> [String] {
        var out = lines
        let indent = String(repeating: " ", count: group.fieldIndent)
        var block = [indent + "use:"]
        block += final.map { indent + "  - \"\(escape($0))\"" }

        // 插在 type: 之后；没有 type 就插在组起始行之后。
        var anchor = group.startLine
        var k = group.startLine + 1
        while k < min(group.endLine, out.count) {
            let trimmed = out[k].trimmingCharacters(in: .whitespacesAndNewlines)
            if ProviderConfiguration.indent(out[k]) == group.fieldIndent,
               ProviderConfiguration.field(trimmed)?.key == "type" { anchor = k; break }
            k += 1
        }
        if lines[group.startLine].hasSuffix("\r") { block = block.map { $0 + "\r" } }
        out.insert(contentsOf: block, at: min(anchor + 1, out.count))
        return out
    }

    /// 把行尾注释从正文里拆出来（`    # 备注`，含分隔空白）。
    ///
    /// 不能用 `YamlScalar.stripInlineComment` 的长度差来切：它会把**行首缩进**
    /// 一起 trim 掉，缩进行里算出来的后缀会错位（实测把 `"OLD"` 又拼回了一截）。
    /// 这里只做一件事：跳过引号内的 `#`，找到空白分隔的注释起点。
    private static func splitComment(_ raw: String) -> (body: String, comment: String) {
        ProviderConfiguration.splitComment(raw)
    }

    private static func escape(_ name: String) -> String {
        String(ProviderConfiguration.quoted(name).dropFirst().dropLast())
    }

    private static func boolValue(_ raw: String) -> Bool {
        let v = (ProviderUsage.scalar(raw) ?? "").lowercased()
        return v == "true" || v == "yes" || v == "on"
    }
}
