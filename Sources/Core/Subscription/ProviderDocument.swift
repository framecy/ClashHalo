import Foundation

/// 订阅编辑的纯文档事务：只改 provider 定义、组 use，永不按同名删除 proxies/rules。
/// 普通块映射按原行修改；flow/anchor/merge 保留可读，但不支持结构编辑时显式抛错。
public enum ProviderDocument {
    public enum Failure: LocalizedError {
        case unsupported, invalidPlan
        public var errorDescription: String? {
            switch self {
            case .unsupported: return "配置包含暂不支持安全改写的订阅或策略组结构，请先在配置编辑器中调整。"
            case .invalidPlan: return "订阅名称、改名关系或策略组归属无效，未修改配置。"
            }
        }
    }

    public static func rewrite(_ yaml: String,
                               providers: [(name: String, url: String)],
                               memberships: [String: Set<String>] = [:],
                               renamed: [String: String] = [:]) throws -> String {
        let originalLines = yaml.components(separatedBy: "\n")
        guard uniqueSection(originalLines, key: "proxy-providers"), uniqueSection(originalLines, key: "proxy-groups") else {
            throw Failure.unsupported
        }
        let entries = ProviderConfiguration.entries(in: yaml)
        let oldNames = Set(entries.map(\.name))
        let names = Set(providers.map(\.name))
        guard names.count == providers.count, oldNames.count == entries.count,
              providers.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("\n") && !$0.name.contains("\r") }),
              renamed.allSatisfy({ oldNames.contains($0.key) && names.contains($0.value) }),
              Set(renamed.values).count == renamed.count,
              Set(memberships.keys).isSubset(of: names) else { throw Failure.invalidPlan }
        let resolved = entries.map { renamed[$0.name] ?? $0.name }
        guard Set(resolved).count == resolved.count else { throw Failure.invalidPlan }
        let removed = Set(entries.filter { !names.contains(renamed[$0.name] ?? $0.name) }.map(\.name))
        let desired = Dictionary(uniqueKeysWithValues: providers.map { ($0.name, $0.url) })
        let structuralChange = Set(resolved) != names
            || entries.contains { desired[renamed[$0.name] ?? $0.name] != $0.url }
            || renamed.contains { $0.key != $0.value }
        guard ProviderGroupBinding.supportsRewrite(yaml, desired: memberships, removed: removed, renamed: renamed) else {
            throw Failure.unsupported
        }
        var lines = yaml.components(separatedBy: "\n")
        if structuralChange {
            guard let blocks = ProviderConfiguration.providerBlocks(in: lines),
                  blocks.map(\.name) == entries.map(\.name) else { throw Failure.unsupported }
            let newline = yaml.contains("\r\n") ? "\r" : ""
            for block in blocks.reversed() {
                let name = renamed[block.name] ?? block.name
                guard let targetURL = desired[name] else {
                    lines.removeSubrange(block.range)
                    continue
                }
                let entry = entries.first { $0.name == block.name }!
                // 本地文件记录按 profile+providerName 绑定；普通文本改名不能迁移 source store。
                if entry.type.lowercased() == "file" && name != block.name { throw Failure.unsupported }
                if targetURL != entry.url {
                    // 本地 provider 的源地址属于 source store，不可把它悄悄转成 http。
                    guard entry.type.lowercased() != "file", !targetURL.isEmpty else { throw Failure.unsupported }
                    if let url = block.fields.first(where: { $0.key == "url" }) {
                        guard ProviderConfiguration.isSimpleScalar(url, lines: lines) else { throw Failure.unsupported }
                        lines[url.range.lowerBound] = ProviderConfiguration.replacingValue(
                            in: lines[url.range.lowerBound], with: ProviderConfiguration.quoted(targetURL))
                    } else {
                        lines.insert(String(repeating: " ", count: block.fieldIndent) + "url: "
                                     + ProviderConfiguration.quoted(targetURL) + newline, at: block.range.lowerBound + 1)
                    }
                }
                if name != block.name {
                    let old = lines[block.range.lowerBound]
                    // provider 首行只有键和注释，无值；仅换掉键名。
                    let suffix = ProviderConfiguration.splitComment(old).comment
                    lines[block.range.lowerBound] = String(repeating: " ", count: block.indent)
                        + ProviderConfiguration.quoted(name) + ":" + suffix
                }
            }
            let existing = Set(resolved)
            let additions = providers.filter { !existing.contains($0.name) }
            if !additions.isEmpty {
                guard additions.allSatisfy({ !$0.url.isEmpty }) else { throw Failure.invalidPlan }
                let level = blocks.first?.indent ?? 2
                let fieldLevel = blocks.first?.fieldIndent ?? (level + 2)
                let template = additions.flatMap { provider -> [String] in
                    let pad = String(repeating: " ", count: level)
                    let child = String(repeating: " ", count: fieldLevel)
                    return [pad + ProviderConfiguration.quoted(provider.name) + ":",
                            child + "type: http", child + "url: " + ProviderConfiguration.quoted(provider.url),
                            child + "interval: 3600", child + "health-check:",
                            child + "  enable: true", child + "  url: https://www.gstatic.com/generate_204",
                            child + "  interval: 300"].map { $0 + newline }
                }
                if let section = ProviderConfiguration.section(in: lines, key: "proxy-providers") {
                    if ProviderConfiguration.field(lines[section.lowerBound])?.value == "{}" {
                        lines[section.lowerBound] = ProviderConfiguration.replacingValue(in: lines[section.lowerBound], with: "")
                    }
                    lines.insert(contentsOf: template, at: section.lowerBound + 1)
                } else {
                    append(["proxy-providers:" + newline] + template, to: &lines, newline: newline)
                }
            }
            // 空映射应是 {} 而不是 YAML null；不触及其他块或注释。
            if providers.isEmpty, let section = ProviderConfiguration.section(in: lines, key: "proxy-providers") {
                lines[section.lowerBound] = ProviderConfiguration.replacingValue(in: lines[section.lowerBound], with: "{}")
            }
        }
        let beforeGroups = ProviderUsage.scanGroups(in: yaml)
        let bound = ProviderGroupBinding.rewrite(lines.joined(separator: "\n"), desired: memberships,
                                                  removed: removed, renamed: renamed)
        // 只对本次由有来源变成空的组补 DIRECT；既有空组、未知来源和其他组不动。
        let previouslyFed = beforeGroups.map {
            !$0.providers.isEmpty || $0.proxyCount > 0 || $0.includesAllProviders || $0.includesAllProxies
        }
        var output = bound.components(separatedBy: "\n")
        let afterGroups = ProviderUsage.scanGroups(in: bound)
        for (index, group) in afterGroups.enumerated().reversed() {
            // use 改写不增删组；按文档位置配对，避免同名组互相影响。
            guard previouslyFed.count == afterGroups.count, previouslyFed[index],
                  group.canRewrite, !group.hasUnknownMembers,
                  group.providers.isEmpty, group.proxyCount == 0,
                  !group.includesAllProviders, !group.includesAllProxies else { continue }
            let eol = output[group.startLine].hasSuffix("\r") ? "\r" : ""
            let prefix = String(repeating: " ", count: group.fieldIndent)
            // 空 proxies 已有字段则原位填充，不生成重复键。
            if let line = ((group.startLine + 1)..<group.endLine).first(where: {
                ProviderConfiguration.indent(output[$0]) == group.fieldIndent
                    && ProviderConfiguration.field(output[$0])?.key == "proxies"
            }) {
                output[line] = ProviderConfiguration.replacingValue(in: output[line], with: "[DIRECT]")
            } else {
                output.insert(prefix + "proxies: [DIRECT]" + eol, at: group.startLine + 1)
            }
        }
        return output.joined(separator: "\n")
    }

    /// 活动配置编辑后，将 provider 定义与策略组归属同步到 profile。
    /// 只移植这两个顶层块；runtime 的 tun/dns/端口等绝不写回 profile。
    /// 使用原始行片段，块内 flow/anchor 也不展开或重新渲染。
    public static func synchronize(runtime: String, into profile: String) throws -> String {
        if runtime == profile { return profile }
        let keys = ["proxy-providers", "proxy-groups"]
        let source = runtime.components(separatedBy: "\n")
        var target = profile.components(separatedBy: "\n")
        let sourceScalarContent = ProviderConfiguration.blockScalarContentLines(in: source)
        let targetScalarContent = ProviderConfiguration.blockScalarContentLines(in: target)
        let sourceIndexes = Set(keys.flatMap { contentSection(source, key: $0).map(Array.init) ?? [] })
        let targetIndexes = Set(keys.flatMap { contentSection(target, key: $0).map(Array.init) ?? [] })
        do {
            // 只允许片段内闭合的模板关系。外部 anchor 值可能不同，不能仅核对 URL/type。
            let sourceAnchors = Set(sourceIndexes.subtracting(sourceScalarContent).flatMap { ProviderConfiguration.referenceTokens(source[$0], marker: "&") })
            let sourceAliases = Set(sourceIndexes.subtracting(sourceScalarContent).flatMap { ProviderConfiguration.referenceTokens(source[$0], marker: "*") })
            guard sourceAliases.isSubset(of: sourceAnchors) else { throw Failure.unsupported }
            let targetAnchors = Set(targetIndexes.subtracting(targetScalarContent).flatMap { ProviderConfiguration.referenceTokens(target[$0], marker: "&") })
            let outsideAliases = Set(target.indices.filter { !targetIndexes.contains($0) && !targetScalarContent.contains($0) }.flatMap {
                ProviderConfiguration.referenceTokens(target[$0], marker: "*")
            })
            let outsideAnchors = Set(target.indices.filter { !targetIndexes.contains($0) && !targetScalarContent.contains($0) }.flatMap {
                ProviderConfiguration.referenceTokens(target[$0], marker: "&")
            })
            guard outsideAliases.isDisjoint(with: targetAnchors.union(sourceAnchors)),
                  outsideAnchors.isDisjoint(with: sourceAnchors) else { throw Failure.unsupported }
        }
        for key in keys {
            guard uniqueSection(source, key: key), uniqueSection(target, key: key) else { throw Failure.unsupported }
            let sourceRange = contentSection(source, key: key)
            let targetRange = contentSection(target, key: key)
            let replacement = sourceRange.map { Array(source[$0]) } ?? []
            if let targetRange { target.replaceSubrange(targetRange, with: replacement) }
            else if !replacement.isEmpty {
                append(replacement, to: &target, newline: profile.contains("\r\n") ? "\r" : "")
            }
        }
        // 目标 profile 可能把组块放在 provider 块前。集合闭合不代表 YAML 顺序合法；
        // 移植后 alias 的 anchor 必须已出现，不能靠只读 parser 的延迟解析蒙混通过。
        // 单行片段完全未改字节，行内关系沿用 runtime；这里只拦跨行/跨块的新 forward alias。
        let resultIndexes = Set(keys.flatMap { contentSection(target, key: $0).map(Array.init) ?? [] })
        let resultScalarContent = ProviderConfiguration.blockScalarContentLines(in: target)
        var precedingAnchors = Set<String>()
        for index in resultIndexes.subtracting(resultScalarContent).sorted() {
            let anchors = ProviderConfiguration.referenceTokens(target[index], marker: "&")
            let aliases = ProviderConfiguration.referenceTokens(target[index], marker: "*")
            guard aliases.isSubset(of: precedingAnchors.union(anchors)) else { throw Failure.unsupported }
            precedingAnchors.formUnion(anchors)
        }
        let result = target.joined(separator: "\n")
        guard ProviderConfiguration.entries(in: result) == ProviderConfiguration.entries(in: runtime),
              ProviderUsage.groupNames(in: result) == ProviderUsage.groupNames(in: runtime),
              ProviderGroupBinding.membership(in: result) == ProviderGroupBinding.membership(in: runtime) else {
            throw Failure.unsupported
        }
        return result
    }

    private static func uniqueSection(_ lines: [String], key: String) -> Bool {
        lines.filter { ProviderConfiguration.indent($0) == 0 && ProviderConfiguration.field($0)?.key == key }.count <= 1
    }

    /// 块外尾部空行/注释属于 profile 自身，不能被 runtime 的排版覆盖。
    private static func contentSection(_ lines: [String], key: String) -> Range<Int>? {
        guard let range = ProviderConfiguration.section(in: lines, key: key) else { return nil }
        var end = range.upperBound
        let scalarContent = ProviderConfiguration.blockScalarContentLines(in: lines)
        while end > range.lowerBound + 1 && !scalarContent.contains(end - 1)
                && ProviderConfiguration.clean(lines[end - 1]).isEmpty { end -= 1 }
        return range.lowerBound..<end
    }

    private static func append(_ block: [String], to lines: inout [String], newline: String) {
        if lines.last == "" { lines.insert(contentsOf: block, at: lines.count - 1) }
        else if lines == [""] { lines = block }
        else {
            if let last = lines.indices.last, !lines[last].hasSuffix("\r") { lines[last] += newline }
            lines.append(contentsOf: block)
        }
    }
}
