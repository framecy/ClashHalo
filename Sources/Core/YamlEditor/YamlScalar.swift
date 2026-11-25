import Foundation

/// Scalar-level YAML value handling shared by the line-scanning config reader.
///
/// Extracted from `EngineControl.readConfigFile` so the rules can be compiled
/// into the regression suite as *production source* rather than re-implemented
/// there (see `Scripts/run-tests.sh`). The bug this guards is not hypothetical:
/// every value parsed out of config.yaml used to carry its trailing comment, so
/// `route-exclude-address` came back as `"127.0.0.0/8            # 回环"` and
/// `mixed-port` failed `Int(_:)` and silently fell back to a default port. This
/// config format is heavily commented, so that was most of the file.
public enum YamlScalar {

    /// Drop a trailing YAML inline comment.
    ///
    /// A `#` only opens a comment when whitespace precedes it. That rule is what
    /// keeps this from truncating the two forms mihomo configs lean on hardest:
    ///
    ///   * `100.100.100.100#utun8` — nameserver pinned to an egress interface.
    ///     Losing the `#utun8` is not cosmetic: the query then leaves via the
    ///     physical NIC and a MagicDNS lookup to 100.100.100.100 times out.
    ///   * `https://dns.google/dns-query#默认代理` — nameserver pinned to a
    ///     policy group.
    ///
    /// A quoted scalar keeps its quotes (unquoting belongs to the caller), but a
    /// comment AFTER the closing quote is still stripped: `"9090" # 备注` used to
    /// survive whole, so the control port never entered the conflict table
    /// (CFG-14). A `#` inside the quotes remains data.
    public static func stripInlineComment(_ v: String) -> String {
        if let first = v.first, first == "'" || first == "\"" {
            guard let close = closingQuote(in: v, quote: first) else { return v }
            let rest = v[v.index(after: close)...]
            guard let cut = commentCut(in: rest) else { return v }
            return String(v[..<cut]).trimmingCharacters(in: .whitespaces)
        }
        guard let cut = commentCut(in: v[...]) else { return v }
        return String(v[..<cut]).trimmingCharacters(in: .whitespaces)
    }

    /// Earliest whitespace-preceded `#` (" #" / "\t#"); the returned index is the
    /// whitespace that opens the comment. nil = no comment.
    private static func commentCut(in text: Substring) -> String.Index? {
        var cut: String.Index?
        for sep in [" #", "\t#"] {
            if let r = text.range(of: sep), cut == nil || r.lowerBound < cut! {
                cut = r.lowerBound
            }
        }
        return cut
    }

    /// Index of the closing quote of a quoted scalar, honoring YAML escapes:
    /// doubled quotes in single-quoted scalars ('it''s'), backslash escapes in
    /// double-quoted ones ("a\"b"). nil when unterminated — leave the value alone.
    private static func closingQuote(in v: String, quote: Character) -> String.Index? {
        var i = v.index(after: v.startIndex)
        while i < v.endIndex {
            let ch = v[i]
            if quote == "\"" && ch == "\\" {
                i = v.index(after: i)
                if i < v.endIndex { i = v.index(after: i) }
                continue
            }
            if ch == quote {
                if quote == "'" {
                    let next = v.index(after: i)
                    if next < v.endIndex && v[next] == "'" {
                        i = v.index(after: next)
                        continue
                    }
                }
                return i
            }
            i = v.index(after: i)
        }
        return nil
    }

    /// Interpret a YAML scalar as Bool / Int / String, stripping any inline
    /// comment and surrounding quotes, and expanding flow-style arrays.
    public static func parse(_ raw: String) -> Any {
        let value = stripInlineComment(raw)
        if value == "true" { return true }
        if value == "false" { return false }
        if let i = Int(value) { return i }
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return [] as [String] }
            return splitFlowItems(inner).map {
                $0.trimmingCharacters(in: .whitespaces)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return value
    }

    /// Split a flow sequence on commas OUTSIDE quotes only: the comma in
    /// `"a,b"` is data, not a separator (F27). Single-quote doubling ('a''b')
    /// needs no special case — the close+reopen pair keeps interior commas
    /// protected.
    private static func splitFlowItems(_ inner: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if escaped { escaped = false }
                else if q == "\"" && ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; current.append(ch); continue }
            if ch == "," { items.append(current); current = ""; continue }
            current.append(ch)
        }
        items.append(current)
        return items
    }

    /// Read one scalar from a top-level mapping block using the same conventions
    /// as the config line scanners: `block:` starts at column 0, `key:` is an
    /// indented line inside it, the first match wins, and the next top-level key
    /// ends the block. Inline comments and surrounding quotes follow
    /// `stripInlineComment`, so a `#` inside the value stays data.
    public static func nestedScalar(in text: String, block: String, key: String) -> String? {
        let topKey = block + ":"
        let nestedKey = key + ":"
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inBlock = line.hasPrefix(topKey)
                continue
            }
            guard inBlock else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(nestedKey) else { continue }
            let stripped = stripInlineComment(
                String(trimmed.dropFirst(nestedKey.count)).trimmingCharacters(in: .whitespaces)
            )
            var value = stripped
            if value.count >= 2,
               ((value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'"))) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Quote a string scalar when the raw text would not survive a round-trip
    /// through YAML as a plain scalar.
    ///
    /// Moved here from `EngineControl` (where it was introduced for Gateway's
    /// `bind-address: "*"` — a bare `*` starts an alias node, i.e. a parse
    /// error) so the subscription renderer can use the same rule without
    /// pulling `EngineControl`'s SystemConfiguration/XPC dependencies into a
    /// pure-logic test target. `EngineControl.quoteYAMLScalarIfNeeded`
    /// forwards here; there is one implementation.
    public static func quoteIfNeeded(_ s: String) -> String {
        let indicators: Set<Character> = ["*", "&", "!", "|", ">", "%", "@", "`",
                                          "[", "]", "{", "}", ",", "#", "\"", "'",
                                          "?", ":", "-", " ", "\t"]
        let needsQuote = s.isEmpty
            || indicators.contains(s.first!)
            || s.contains(": ")
            || s.contains(" #")
            || s.hasSuffix(":")
        guard needsQuote else { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
