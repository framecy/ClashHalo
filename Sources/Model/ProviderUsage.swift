import Foundation

/// 策略组的唯一行扫描入口。归属展示、规则目标、写入定位共用同一视图。
/// 支持任意合法空格缩进、后置 name、单行 flow 组、带逗号及转义的名称；
/// 不认识的结构标记为不可写，不能把“未读懂”误当作空组。
enum ProviderUsage {
    struct Group {
        let name: String
        let type: String?
        let providers: [String]
        let proxyCount: Int
        let includesAllProviders: Bool
        let includesAllProxies: Bool
        let startLine: Int
        let endLine: Int
        let useLine: Int?
        let useInline: Bool
        let fieldIndent: Int
        let itemIndent: Int?
        let canRewrite: Bool
        let hasUnknownMembers: Bool
    }

    static func scalar(_ raw: String) -> String? {
        let text = ProviderConfiguration.clean(raw)
        guard !text.isEmpty, !["*", "&", "!", "|", ">", "[", "{"].contains(where: text.hasPrefix) else { return nil }
        let decoded = ProviderConfiguration.unquote(text)
        return decoded.isEmpty ? nil : decoded
    }

    static func parseInlineList(_ raw: String) -> [String] {
        list(raw) ?? []
    }

    /// nil 与 [] 不同：前者是不支持的表达式，绝不能据此删除来源或补 DIRECT。
    private static func list(_ raw: String) -> [String]? {
        let text = ProviderConfiguration.clean(raw)
        if text.isEmpty { return [] }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { return nil }
            let inner = String(text.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
            let parts = ProviderConfiguration.split(inner)
            let values = parts.compactMap(scalar)
            return values.count == parts.count ? values : nil
        }
        return scalar(text).map { [$0] }
    }

    static func scanGroups(in yaml: String) -> [Group] {
        let lines = yaml.components(separatedBy: "\n")
        guard let section = ProviderConfiguration.section(in: lines, key: "proxy-groups"),
              ProviderConfiguration.field(lines[section.lowerBound])?.value == "" else { return [] }
        let body = (section.lowerBound + 1)..<section.upperBound
        let scalarContent = ProviderConfiguration.blockScalarContentLines(in: lines)
        let starts = body.filter {
            guard !scalarContent.contains($0) else { return false }
            let text = ProviderConfiguration.clean(lines[$0])
            return text == "-" || text.hasPrefix("- ") || text.hasPrefix("-\t")
        }
        guard let groupIndent = starts.map({ ProviderConfiguration.indent(lines[$0]) }).min() else { return [] }
        let boundaries = starts.filter { ProviderConfiguration.indent(lines[$0]) == groupIndent }
        var result: [Group] = []
        for (offset, start) in boundaries.enumerated() {
            let end = offset + 1 < boundaries.count ? boundaries[offset + 1] : section.upperBound
            let first = ProviderConfiguration.clean(String(ProviderConfiguration.clean(lines[start]).dropFirst()))
            let afterDash = String(lines[start].dropFirst(groupIndent + 1))
            let continuationIndent = ((start + 1)..<end).filter {
                !scalarContent.contains($0) && !ProviderConfiguration.clean(lines[$0]).isEmpty
            }.map { ProviderConfiguration.indent(lines[$0]) }.min()
            let fieldIndent = first.isEmpty ? (continuationIndent ?? (groupIndent + 2))
                : groupIndent + 1 + afterDash.prefix(while: { $0 == " " || $0 == "\t" }).count
            var name: String?, type: String?, useLine: Int?, itemIndent: Int?
            var providers: [String] = []
            var proxyCount = 0
            var useInline = false, allProviders = false, allProxies = false
            var writable = true, unknown = false
            var keys = Set<String>()

            func consume(_ key: String, _ value: String, line: Int) {
                if !keys.insert(key).inserted { writable = false; unknown = true }
                switch key {
                case "name": name = scalar(value)
                case "type": type = scalar(value)
                case "include-all-providers", "include-all-proxies", "include-all":
                    guard let included = boolValue(value) else {
                        writable = false; unknown = true; return
                    }
                    if key != "include-all-proxies" { allProviders = allProviders || included }
                    if key != "include-all-providers" { allProxies = allProxies || included }
                case "use", "proxies":
                    if key == "use" { useLine = line; useInline = !value.isEmpty }
                    if !value.isEmpty {
                        if let values = list(value) {
                            if key == "use" { providers = values } else { proxyCount = values.count }
                        } else { writable = false; unknown = true }
                    } else {
                        var i = line + 1
                        while i < end {
                            let text = ProviderConfiguration.clean(lines[i])
                            if text.isEmpty { i += 1; continue }
                            let indent = ProviderConfiguration.indent(lines[i])
                            // YAML 序列可以与 use/proxies 字段等缩进。
                            if indent < fieldIndent || (indent == fieldIndent && !text.hasPrefix("- ")) { break }
                            guard text.hasPrefix("- "), indent >= fieldIndent,
                                  let entry = scalar(String(text.dropFirst(2))) else {
                                writable = false; unknown = true; i += 1; continue
                            }
                            if key == "use" {
                                providers.append(entry)
                                if itemIndent == nil { itemIndent = indent }
                                if itemIndent != indent { writable = false; unknown = true }
                            } else { proxyCount += 1 }
                            i += 1
                        }
                    }
                    // 首行 use/proxies 无独立字段行，不做结构改写。
                    if line == start { writable = false }
                case "<<": writable = false; unknown = true
                default: break
                }
            }

            if first.hasPrefix("{"), first.hasSuffix("}") {
                writable = false
                for item in ProviderConfiguration.split(String(first.dropFirst().dropLast())) {
                    if let pair = ProviderConfiguration.field(item) { consume(pair.key, pair.value, line: start) }
                }
            } else if let pair = ProviderConfiguration.field(first) {
                consume(pair.key, pair.value, line: start)
            } else if !first.isEmpty { writable = false; unknown = true }

            for i in (start + 1)..<end {
                guard !scalarContent.contains(i) else { continue }
                let text = ProviderConfiguration.clean(lines[i])
                if text.isEmpty { continue }
                if lines[i].contains("\t") && lines[i].prefix(while: { $0.isWhitespace }).contains("\t") { writable = false }
                let indent = ProviderConfiguration.indent(lines[i])
                guard indent == fieldIndent, let pair = ProviderConfiguration.field(text) else { continue }
                if pair.value.hasPrefix("&") || pair.value.hasPrefix("*") { writable = false }
                consume(pair.key, pair.value, line: i)
            }
            guard let name else { continue }
            result.append(Group(name: name, type: type, providers: providers, proxyCount: proxyCount,
                                includesAllProviders: allProviders, includesAllProxies: allProxies,
                                startLine: start, endLine: end, useLine: useLine, useInline: useInline,
                                fieldIndent: fieldIndent, itemIndent: itemIndent,
                                canRewrite: writable, hasUnknownMembers: unknown))
        }
        return result
    }

    static func groupNames(in yaml: String) -> [String] { scanGroups(in: yaml).map(\.name) }

    static func groupReferences(in yaml: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for group in scanGroups(in: yaml) {
            for name in Set(group.providers) { counts[name, default: 0] += 1 }
        }
        return counts
    }

    static func groupsMissingMembers(in yaml: String) -> [String] {
        scanGroups(in: yaml).filter {
            !$0.hasUnknownMembers && $0.providers.isEmpty && $0.proxyCount == 0
                && !$0.includesAllProviders && !$0.includesAllProxies
        }.map(\.name)
    }

    static func summary(count: Int) -> String {
        count > 0 ? "被 \(count) 个策略组引用" : "未被任何策略组引用"
    }

    private static func boolValue(_ raw: String) -> Bool? {
        guard let value = scalar(raw)?.lowercased() else { return nil }
        if ["true", "yes", "on"].contains(value) { return true }
        if ["false", "no", "off"].contains(value) { return false }
        return nil
    }
}
