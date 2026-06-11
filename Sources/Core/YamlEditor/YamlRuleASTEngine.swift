import Foundation

/// 基于游标的词法行解析器，用于安全替换 YAML 中的 `rules:` 节点，
/// 100% 保护其上下的所有配置（proxies, proxy-groups, 甚至文件头部的注释）。
public final class YamlRuleASTEngine {
    
    public enum EngineError: Error {
        case fileReadError
        case parseError(String)
    }
    
    /// 将 RuleNode 序列化为符合 Clash 规范的字符串
    public static func serialize(node: RuleNode) -> String {
        let prefix = node.isEnabled ? "-" : "# -"
        // MATCH 规则无需 match 参数
        if node.type == .match {
            let actionStr = node.action == .proxy ? (node.proxyGroup ?? "PROXY") : node.action.rawValue
            return "\(prefix) MATCH,\(actionStr)"
        }
        
        let actionStr = node.action == .proxy ? (node.proxyGroup ?? "PROXY") : node.action.rawValue
        
        if let note = node.note, !note.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(prefix) \(node.type.rawValue),\(node.match),\(actionStr),\(note)"
        } else {
            return "\(prefix) \(node.type.rawValue),\(node.match),\(actionStr)"
        }
    }
    
    /// 将单行规则反序列化为 RuleNode
    public static func parseLine(_ line: String) -> RuleNode? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isEnabled = !trimmed.hasPrefix("#")
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        guard cleaned.hasPrefix("-") else { return nil }
        
        var content = cleaned.dropFirst().trimmingCharacters(in: .whitespaces)
        // Strip inline YAML comments if present
        if let hashRange = content.range(of: "#") {
            content = String(content[..<hashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
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
        
        let note = parts.count > 3 ? parts[3] : nil
        
        return RuleNode(type: type, match: match, action: action, sort: 0, isEnabled: isEnabled, proxyGroup: proxyGroup, note: note)
    }
    
    /// 获取文件中的所有规则
    public static func extractRules(from yaml: String) -> [RuleNode] {
        let lines = yaml.components(separatedBy: .newlines)
        var rules: [RuleNode] = []
        var inRulesBlock = false
        var sortIndex = 0
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
    
    /// 将新的 RuleNode 列表安全注入到 YAML 字符串中
    public static func injectRules(_ nodes: [RuleNode], into yaml: String) throws -> String {
        let lines = yaml.components(separatedBy: .newlines)
        var newLines: [String] = []
        
        var inRulesBlock = false
        var rulesInjected = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
            // 如果在 rules 块内，丢弃原来的子行（因为我们已经注入了新规则）
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
