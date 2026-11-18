import Foundation

/// 订阅清单的只读解析：块映射、flow 映射、anchor/alias/merge 共用一套口径。
/// 不重排/重写原 YAML；仅取 provider 的直接子字段，绝不把 health-check.url 当源。
/// 这是配置读取子集，不代替 mihomo 的完整 YAML 校验；不支持的值保持不可用。
public enum ProviderConfiguration {
    public struct Entry: Equatable {
        public let name: String
        public let url: String
        public let type: String
        public let path: String
    }

    public static func entries(in yaml: String) -> [Entry] {
        let parser = Parser(yaml)
        let root = parser.parse()
        guard let providers = parser.mapping(root).first(where: { $0.0 == "proxy-providers" })?.1 else { return [] }
        let result: [Entry] = parser.mapping(providers).compactMap { name, value in
            guard name != "<<" else { return nil }
            let fields = parser.mapping(value)
            guard !fields.isEmpty else { return nil }
            func scalar(_ key: String) -> String {
                guard let node = fields.first(where: { $0.0 == key })?.1 else { return "" }
                return parser.scalar(node) ?? ""
            }
            return Entry(name: name, url: scalar("url"), type: scalar("type"), path: scalar("path"))
        }
        return parser.exhausted ? [] : result
    }

    /// 旧的订阅编辑器只会保真处理标准 2/4 空格块。扩大读取能力不能让
    /// flow / 模板 / 深缩进 file provider 随添加另一条订阅被重建成空 HTTP。
    /// 这些配置仍可刷新；结构编辑暂时拒绝，直到写入器支持保真改写。
    static func supportsLegacyRewrite(in yaml: String) -> Bool {
        let lines = yaml.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { field($0)?.key == "proxy-providers" && !$0.hasPrefix(" ") }) else {
            return entries(in: yaml).isEmpty
        }
        guard lines[start].hasPrefix("proxy-providers:"), field(lines[start])?.value == "" else { return false }
        var names: [String] = []
        for line in lines.dropFirst(start + 1) {
            let text = clean(line)
            if text.isEmpty {
                // 旧写入器把零缩进注释误作块结束；保守拒绝跨过它写盘。
                if line.hasPrefix("#") { return false }
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 { break }
            guard let pair = field(line) else { continue }
            if pair.key == "<<" || pair.value.hasPrefix("&") || pair.value.hasPrefix("*") { return false }
            if pair.key == "type" && !text.hasPrefix("type:") { return false }
            if indent == 2 {
                guard pair.value.isEmpty else { return false }
                let legacyName = String(text.dropLast()).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                guard legacyName == pair.key else { return false }
                names.append(pair.key)
            } else if names.isEmpty { return false }
        }
        return names == entries(in: yaml).map(\.name)
    }

    /// 同时用于保守的块状改写定位；冒号必须在引号外，键名只去外围引号。
    static func field(_ raw: String) -> (key: String, value: String)? {
        let text = clean(raw)
        var delimiter: String.Index?
        scan(text) { i, ch, _ in
            guard delimiter == nil, ch == ":" else { return }
            let next = text.index(after: i)
            // plain 键的分隔符后须有空白/flow 值/行尾；URL 内的 :// 不是键。
            let quotedKey = text.first == "\"" || text.first == "'"
            if quotedKey || next == text.endIndex || text[next].isWhitespace
                || text[next] == "{" || text[next] == "[" { delimiter = i }
        }
        guard let delimiter else { return nil }
        let key = unquote(String(text[..<delimiter]).trimmingCharacters(in: .whitespaces))
        guard !key.isEmpty, !key.hasPrefix("- ") else { return nil }
        return (key, String(text[text.index(after: delimiter)...]).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 保真写入共用定位（不重建 YAML AST）

    static func indent(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }

    /// 标记 | / > 的内容行，供引用检查、字段定位和保真裁剪共用。
    /// 只识别范围，不解码折叠/换行值；内容中的 #、*、&、冒号都是原始文本。
    /// 显式缩进相对块字段（序列内紧凑映射则相对 key），空行属于标量尾部。
    static func blockScalarContentLines(in lines: [String]) -> Set<Int> {
        var content = Set<Int>()
        var active: (parent: Int, contentIndent: Int?)?
        var continuedQuote: Character?
        for i in lines.indices {
            let raw = lines[i]
            let blank = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let level = indent(raw)
            if var block = active {
                if blank {
                    // components(separatedBy:) 的 EOF 空串只是最后一个换行的哨兵，
                    // 不是额外空行；同步到文档中段时不得凭空增加 |+ 的末尾换行。
                    if i != lines.count - 1 || !raw.isEmpty { content.insert(i) }
                    continue
                }
                if block.contentIndent == nil, level > block.parent {
                    block.contentIndent = level
                    active = block
                }
                if let required = block.contentIndent, level >= required {
                    content.insert(i)
                    continue
                }
                active = nil
            }
            // 跨行引号中的 `note: |` 不是块头。这里只跟踪引号闭合，不屏蔽
            // 此类续行引用：不支持的引用形状仍保守拒绝，不能藏掉真实外部依赖。
            let quoteBefore = continuedQuote
            scan(raw, continuingQuote: &continuedQuote) { _, _, _ in }
            if quoteBefore != nil { continue }
            var text = clean(raw)
            guard !text.isEmpty else { continue }
            var parent = level
            // 支持 - |2 以及 - notes: |2；后者缩进基准在映射 key 处。
            var sequenceItem = false
            while text.hasPrefix("- ") {
                sequenceItem = true
                let remainder = text.dropFirst()
                let spaces = remainder.prefix(while: { $0 == " " }).count
                text = String(remainder.dropFirst(spaces))
                if field(text) != nil || text.hasPrefix("- ") { parent += 1 + spaces }
            }
            let value: String
            if let pair = field(text) { value = pair.value }
            else if sequenceItem { value = text }
            else { continue }
            guard let explicit = blockScalarIndent(in: value) else { continue }
            active = (parent, explicit == 0 ? nil : parent + explicit)
        }
        return content
    }

    /// 0 = 自动探测缩进；1...9 = 显式缩进；nil = 不是合法块标量头。
    private static func blockScalarIndent(in raw: String) -> Int? {
        var value = clean(raw)
        while value.hasPrefix("&") || value.hasPrefix("!") {
            if value.hasPrefix("!<") {
                guard let close = value.firstIndex(of: ">") else { return nil }
                value = String(value[value.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else {
                guard let end = value.firstIndex(where: \.isWhitespace) else { return nil }
                value = String(value[end...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard value.first == "|" || value.first == ">" else { return nil }
        var explicit = 0, chomp = false
        for ch in value.dropFirst() {
            if ch == "+" || ch == "-" {
                guard !chomp else { return nil }
                chomp = true
            } else if let digit = ch.wholeNumberValue, (1...9).contains(digit), explicit == 0,
                      ch.isASCII {
                explicit = digit
            } else { return nil }
        }
        return explicit
    }

    /// 顶层块的行范围；零缩进注释与空行不是块边界，等缩进序列也不是新键。
    static func section(in lines: [String], key: String) -> Range<Int>? {
        guard let start = lines.indices.first(where: {
            indent(lines[$0]) == 0 && field(lines[$0].replacingOccurrences(of: "\u{feff}", with: ""))?.key == key
        }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count {
            let text = clean(lines[i])
            if text.isEmpty { continue }
            if indent(lines[i]) == 0 && (field(lines[i]) != nil || text == "---" || text == "...") { end = i; break }
        }
        return start..<end
    }

    struct BlockField {
        let key: String
        let value: String
        let range: Range<Int>
    }

    struct ProviderBlock {
        let name: String
        let range: Range<Int>
        let indent: Int
        let fieldIndent: Int
        let fields: [BlockField]
    }

    /// 只放行可证明安全的普通块映射；共享 anchor/merge/flow 不就地结构写入。
    /// 读取仍用 entries（支持模板）；写入能力与读取能力有意分离。
    static func providerBlocks(in lines: [String]) -> [ProviderBlock]? {
        guard lines.filter({ indent($0) == 0 && field($0)?.key == "proxy-providers" }).count <= 1 else { return nil }
        guard let section = section(in: lines, key: "proxy-providers") else { return [] }
        let sectionValue = field(lines[section.lowerBound])?.value
        guard sectionValue == "" || sectionValue == "{}" else { return nil }
        if sectionValue == "{}" { return [] }
        let body = (section.lowerBound + 1)..<section.upperBound
        let scalarContent = blockScalarContentLines(in: lines)
        let nonempty = body.filter { !scalarContent.contains($0) && !clean(lines[$0]).isEmpty }
        if nonempty.isEmpty { return [] }
        guard !nonempty.contains(where: { lines[$0].prefix(while: { $0.isWhitespace }).contains("\t") }),
              let level = nonempty.map({ indent(lines[$0]) }).min(), level > 0 else { return nil }
        let starts = nonempty.filter { indent(lines[$0]) == level }
        var names = Set<String>(), blocks: [ProviderBlock] = []
        for (offset, start) in starts.enumerated() {
            guard let pair = field(lines[start]), pair.value.isEmpty, pair.key != "<<",
                  names.insert(pair.key).inserted else { return nil }
            var end = offset + 1 < starts.count ? starts[offset + 1] : section.upperBound
            // 尾部注释属于块间排版；删除 provider 不能顺带清除它们。
            while end > start + 1 && !scalarContent.contains(end - 1) && clean(lines[end - 1]).isEmpty { end -= 1 }
            let childLines = ((start + 1)..<end).filter { !scalarContent.contains($0) && !clean(lines[$0]).isEmpty }
            let directIndent = childLines.map { indent(lines[$0]) }.min() ?? (level + 2)
            guard directIndent > level else { return nil }
            let direct = childLines.filter { indent(lines[$0]) == directIndent }
            var fields: [BlockField] = [], keys = Set<String>()
            for (fieldOffset, line) in direct.enumerated() {
                guard let field = field(lines[line]), field.key != "<<", keys.insert(field.key).inserted else { return nil }
                let next = fieldOffset + 1 < direct.count ? direct[fieldOffset + 1] : end
                fields.append(BlockField(key: field.key, value: field.value, range: line..<next))
            }
            // 删除/改写带 anchor 的块会改变其他区域 alias 的含义；宁可拒绝。
            for line in childLines {
                if let field = field(lines[line]), field.key == "<<" { return nil }
                if hasReferenceSyntax(lines[line]) { return nil }
            }
            blocks.append(ProviderBlock(name: pair.key, range: start..<end, indent: level,
                                        fieldIndent: directIndent, fields: fields))
        }
        return blocks
    }

    /// 标量范围的最小替换，保留键、空白和注释（调用前须确认原值为单行标量）。
    static func replacingValue(in raw: String, with value: String) -> String {
        var delimiter: String.Index?
        scan(raw) { i, ch, _ in
            if delimiter == nil && ch == ":" { delimiter = i }
        }
        guard let delimiter else { return raw }
        var start = raw.index(after: delimiter)
        while start < raw.endIndex && (raw[start] == " " || raw[start] == "\t") { start = raw.index(after: start) }
        let suffix = splitComment(String(raw[start...])).comment
        let prefix = String(raw[..<start])
        return prefix + (start == raw.index(after: delimiter) ? " " : "") + value + suffix
    }

    static func splitComment(_ raw: String) -> (body: String, comment: String) {
        var commentStart: String.Index?
        scan(raw) { i, ch, _ in
            guard commentStart == nil, ch == "#",
                  i == raw.startIndex || raw[raw.index(before: i)].isWhitespace else { return }
            commentStart = i
        }
        if var cut = commentStart {
            while cut > raw.startIndex && raw[raw.index(before: cut)].isWhitespace { cut = raw.index(before: cut) }
            return (String(raw[..<cut]), String(raw[cut...]))
        }
        let end = raw.last == "\r" ? String(raw.dropLast()) : raw
        return (end, raw.last == "\r" ? "\r" : "")
    }

    /// anchor/alias 可出现在嵌套 flow 内。引号里的 &/* 是数据，不应误判。
    static func referenceTokens(_ raw: String, marker: Character) -> Set<String> {
        let text = clean(raw)
        var found = Set<String>()
        scan(text) { index, ch, _ in
            guard ch == marker else { return }
            if index != text.startIndex {
                let previous = text[text.index(before: index)]
                guard previous.isWhitespace || "[{,:".contains(previous) else { return }
            }
            let start = text.index(after: index)
            let name = text[start...].prefix { !$0.isWhitespace && !"[]{},".contains($0) }
            if !name.isEmpty { found.insert(String(name)) }
        }
        return found
    }

    static func hasReferenceSyntax(_ raw: String) -> Bool {
        !referenceTokens(raw, marker: "&").isEmpty || !referenceTokens(raw, marker: "*").isEmpty
    }

    static func quoted(_ value: String) -> String {
        // JSON 字符串是 YAML 双引号标量子集，控制字符也必须转义。
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!
    }

    static func isSimpleScalar(_ field: BlockField, lines: [String]) -> Bool {
        guard !field.value.isEmpty,
              !["&", "*", "!", "|", ">", "[", "{"].contains(where: field.value.hasPrefix) else { return false }
        return field.range.dropFirst().allSatisfy { clean(lines[$0]).isEmpty }
    }

    private indirect enum Node {
        case scalar(String), map([(String, Node)]), sequence([Node]), alias(String)
    }

    private final class Parser {
        let lines: [String]
        var anchors: [String: Node] = [:]
        // 导入文本不可信；重复 merge 即使无环也可指数展开，限制总解析工作量。
        var remaining = 50_000
        var exhausted = false
        func consume() -> Bool {
            guard remaining > 0 else { exhausted = true; return false }
            remaining -= 1
            return true
        }
        init(_ yaml: String) {
            lines = yaml.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
                .components(separatedBy: "\n")
        }

        func parse() -> Node {
            var index = 0
            return block(&index, indent: 0, depth: 0)
        }

        func block(_ index: inout Int, indent: Int, depth: Int) -> Node {
            guard depth < 64 else { return .scalar("") }
            var fields: [(String, Node)] = []
            var items: [Node] = []
            while index < lines.count {
                let raw = lines[index]
                let text = clean(raw)
                if text.isEmpty || text == "---" || text == "..." { index += 1; continue }
                let level = raw.prefix(while: { $0 == " " }).count
                if level < indent { break }
                guard level == indent else { index += 1; continue }
                if text.hasPrefix("- ") {
                    index += 1
                    items.append(value(String(text.dropFirst(2)), index: &index, parent: indent, depth: depth + 1))
                } else if let pair = field(text) {
                    index += 1
                    fields.append((pair.key, value(pair.value, index: &index, parent: indent, depth: depth + 1)))
                } else { index += 1 }
            }
            return fields.isEmpty && !items.isEmpty ? .sequence(items) : .map(fields)
        }

        func value(_ raw: String, index: inout Int, parent: Int, depth: Int) -> Node {
            guard depth < 64 else { return .scalar("") }
            var text = clean(raw)
            var anchor: String?
            if text.hasPrefix("&") {
                let token = text.dropFirst().prefix { !$0.isWhitespace && $0 != "{" && $0 != "[" }
                anchor = String(token)
                text = String(text.dropFirst(token.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            let node: Node
            if text.isEmpty {
                var next = index
                while next < lines.count && clean(lines[next]).isEmpty { next += 1 }
                if next < lines.count {
                    let childIndent = lines[next].prefix(while: { $0 == " " }).count
                    if childIndent > parent {
                        index = next
                        node = block(&index, indent: childIndent, depth: depth + 1)
                    } else if childIndent == parent && clean(lines[next]).hasPrefix("- ") {
                        // YAML 允许序列与所属键等缩进（常见于 <<: 模板列表）。
                        index = next
                        var items: [Node] = []
                        while index < lines.count {
                            let item = clean(lines[index])
                            if item.isEmpty { index += 1; continue }
                            guard lines[index].prefix(while: { $0 == " " }).count == parent,
                                  item.hasPrefix("- ") else { break }
                            index += 1
                            items.append(value(String(item.dropFirst(2)), index: &index, parent: parent, depth: depth + 1))
                        }
                        node = .sequence(items)
                    } else { node = .scalar("") }
                } else { node = .scalar("") }
            } else {
                // flow 映射可以换行，但不能吞掉下一个同级/顶层键。
                if text.hasPrefix("{") || text.hasPrefix("[") {
                    while balance(text) > 0 && index < lines.count {
                        let next = clean(lines[index])
                        let nextIndent = lines[index].prefix(while: { $0 == " " }).count
                        if !next.isEmpty && nextIndent <= parent && next != "}" && next != "]" { break }
                        text += " " + next
                        index += 1
                    }
                }
                node = inline(text, depth: depth + 1)
            }
            if let anchor, !anchor.isEmpty { anchors[anchor] = node }
            return node
        }

        func inline(_ raw: String, depth: Int) -> Node {
            guard depth < 64 else { return .scalar("") }
            let text = clean(raw)
            if text.hasPrefix("&") {
                let token = text.dropFirst().prefix { !$0.isWhitespace && $0 != "{" && $0 != "[" }
                let node = inline(String(text.dropFirst(token.count + 1)), depth: depth + 1)
                anchors[String(token)] = node
                return node
            }
            if text.hasPrefix("*") { return .alias(String(text.dropFirst())) }
            if text.hasPrefix("{"), text.hasSuffix("}") {
                let fields = split(String(text.dropFirst().dropLast())).compactMap { item -> (String, Node)? in
                    guard let pair = field(item) else { return nil }
                    return (pair.key, inline(pair.value, depth: depth + 1))
                }
                return .map(fields)
            }
            if text.hasPrefix("["), text.hasSuffix("]") {
                return .sequence(split(String(text.dropFirst().dropLast())).map { inline($0, depth: depth + 1) })
            }
            // 未闭合的 flow / 块标量不猜成订阅 URL。
            if text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("|") || text.hasPrefix(">") {
                return .scalar("")
            }
            return .scalar(unquote(text))
        }

        func scalar(_ node: Node, seen: Set<String> = []) -> String? {
            switch node {
            case .scalar(let text): return text
            case .alias(let name):
                guard !seen.contains(name), seen.count < 64, let target = anchors[name] else { return nil }
                return scalar(target, seen: seen.union([name]))
            default: return nil
            }
        }

        func mapping(_ node: Node, seen: Set<String> = []) -> [(String, Node)] {
            guard consume() else { return [] }
            switch node {
            case .alias(let name):
                guard !seen.contains(name), seen.count < 64, let target = anchors[name] else { return [] }
                return mapping(target, seen: seen.union([name]))
            case .map(let fields):
                var result: [(String, Node)] = []
                for (key, merge) in fields where key == "<<" {
                    let sources: [Node]
                    if case .sequence(let items) = merge { sources = items } else { sources = [merge] }
                    for source in sources {
                        for pair in mapping(source, seen: seen) where !result.contains(where: { $0.0 == pair.0 }) {
                            result.append(pair) // YAML merge 序列中较早模板优先。
                        }
                    }
                }
                for pair in fields where pair.0 != "<<" {
                    if let index = result.firstIndex(where: { $0.0 == pair.0 }) { result[index] = pair }
                    else { result.append(pair) } // 显式字段始终覆盖模板，与出现先后无关。
                }
                return result
            default: return []
            }
        }
    }

    /// 只在引号外且 # 前为空白时剥注释；URL 的 #fragment 保持原样。
    static func clean(_ raw: String) -> String {
        splitComment(raw.trimmingCharacters(in: .whitespacesAndNewlines)).body
            .trimmingCharacters(in: .whitespaces)
    }

    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var start = text.startIndex
        scan(text, flowItems: true) { index, ch, depth in
            if ch == "," && depth == 0 {
                parts.append(String(text[start..<index]))
                start = text.index(after: index)
            }
        }
        parts.append(String(text[start...]))
        return parts
    }

    private static func balance(_ text: String) -> Int {
        var result = 0
        scan(text) { _, ch, _ in
            if ch == "{" || ch == "[" { result += 1 }
            if ch == "}" || ch == "]" { result -= 1 }
        }
        return result
    }

    /// 引号只在标量起点有词法意义；O'Brien、组"名中的引号只是 plain 数据。
    /// flowItems 用于已经剥去外围 []/{} 的列表，逗号仍是成员边界。
    private static func scan(_ text: String, flowItems: Bool = false,
                             visit: (String.Index, Character, Int) -> Void) {
        var quote: Character?
        scan(text, flowItems: flowItems, continuingQuote: &quote, visit: visit)
    }

    private static func scan(_ text: String, flowItems: Bool = false,
                             continuingQuote quote: inout Character?,
                             visit: (String.Index, Character, Int) -> Void) {
        var escaped = false, scalarStart = true, property = false, quotedEnd = false
        var depth = 0
        for i in text.indices {
            let ch = text[i]
            let next = text.index(after: i)
            if let q = quote {
                if escaped { escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if q == "'" && ch == "'" && next < text.endIndex && text[next] == "'" { escaped = true }
                else if ch == q { quote = nil; quotedEnd = true }
                continue
            }
            if scalarStart && (ch == "\"" || ch == "'") {
                quote = ch; scalarStart = false; continue
            }
            visit(i, ch, depth)
            if ch == "#" && (i == text.startIndex || text[text.index(before: i)].isWhitespace) { return }
            if ch.isWhitespace {
                if property { property = false; scalarStart = true }
                continue
            }
            if scalarStart && (ch == "&" || ch == "!") { property = true; scalarStart = false; continue }
            if property { continue }
            if scalarStart && (ch == "{" || ch == "[") {
                depth += 1; quotedEnd = false; continue
            }
            if (ch == "}" || ch == "]") && depth > 0 {
                depth -= 1; scalarStart = false; quotedEnd = false; continue
            }
            if ch == "," && (depth > 0 || flowItems) { scalarStart = true; quotedEnd = false; continue }
            if ch == ":" && (quotedEnd || next == text.endIndex || text[next].isWhitespace
                              || text[next] == "{" || text[next] == "[") {
                scalarStart = true; quotedEnd = false; continue
            }
            if scalarStart && ch == "-" && (next == text.endIndex || text[next].isWhitespace) { continue }
            scalarStart = false; quotedEnd = false
        }
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if text.hasPrefix("\""), text.hasSuffix("\"") {
            // JSON 引号转义与常见 YAML 双引号标量兼容（含 Unicode / \/）。
            if let data = text.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                return decoded
            }
            let body = Array(text.dropFirst().dropLast())
            let escapes: [Character: String] = ["0": "\0", "a": "\u{7}", "b": "\u{8}", "t": "\t", "n": "\n",
                "v": "\u{b}", "f": "\u{c}", "r": "\r", "e": "\u{1b}", " ": " ", "\"": "\"", "/": "/", "\\": "\\",
                "N": "\u{85}", "_": "\u{a0}", "L": "\u{2028}", "P": "\u{2029}"]
            var decoded = "", i = 0
            while i < body.count {
                if body[i] != "\\" { decoded.append(body[i]); i += 1; continue }
                guard i + 1 < body.count else { return String(text.dropFirst().dropLast()) }
                let escape = body[i + 1]
                if let value = escapes[escape] { decoded += value; i += 2; continue }
                let digits = escape == "x" ? 2 : (escape == "u" ? 4 : (escape == "U" ? 8 : 0))
                guard digits > 0, i + 2 + digits <= body.count,
                      let value = UInt32(String(body[(i + 2)..<(i + 2 + digits)]), radix: 16),
                      let scalar = UnicodeScalar(value) else { return String(text.dropFirst().dropLast()) }
                decoded.unicodeScalars.append(scalar)
                i += 2 + digits
            }
            return decoded
        }
        return text
    }
}
