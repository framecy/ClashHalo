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
    /// A quoted scalar is returned untouched: a `#` inside quotes is data, and
    /// unquoting belongs to the caller.
    public static func stripInlineComment(_ v: String) -> String {
        guard let first = v.first, first != "'", first != "\"" else { return v }
        var cut: String.Index?
        for sep in [" #", "\t#"] {
            if let r = v.range(of: sep) {
                if cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
            }
        }
        guard let c = cut else { return v }
        return String(v[..<c]).trimmingCharacters(in: .whitespaces)
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
            return inner.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return value
    }
}
