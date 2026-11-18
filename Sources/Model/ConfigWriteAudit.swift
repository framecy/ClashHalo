import Foundation

/// Audit trail for every write to `config.yaml`.
///
/// ### Why this exists
/// `config.yaml` is written in place by eleven call sites (see `writeConfig`),
/// and several of them are user-driven: the 设置页 persists `geodata-mode`,
/// `unified-delay`, `find-process-mode`, `disable-keep-alive`… straight into the
/// running config, where they **outrank the activated profile** until the next
/// apply. There was no record of any of it. When the running config later
/// disagreed with the profile on eight top-level keys, the only way to find out
/// what happened was archaeology on `config.yaml.bak-*` — and even that could not
/// say *which* write flipped `dns.enable` to false, only that it was already
/// false at some point.
///
/// `app.log` was not it: it is capped at ~2 MB and carries no key-level detail.
/// This type produces a dedicated, append-only, machine-greppable trail whose
/// entire purpose is answering "who changed this key, when, and from what to
/// what" — the question that motivated this file.
///
/// ### What a record contains
/// For each write that actually changes a top-level scalar, one line:
///
///     [2026-10-09 16:02:11] setTopLevelScalars | find-process-mode: strict → always
///     [2026-10-09 16:02:11] setTopLevelScalars | unified-delay: true → false
///     [2026-10-09 16:02:11] setTopLevelScalars | geodata-loader: memconservative → standard
///
/// A write that changes nothing is still recorded, as `(no changes)`, so that a
/// suspicious *absence* of a record is distinguishable from a write that was
/// identical to what was already on disk.
///
/// ### Privacy
/// Values are logged, because "what did it become" is the whole point. The one
/// key that must never reach a log file is `secret`: the config carries it in
/// plain text and the file is already a credential, but a log is copied around
/// far more casually than the config is. `redactedValue(for:)` therefore masks
/// it (and anything else credential-shaped) to a stable fingerprint that still
/// reveals *that* it changed without revealing the value.
enum ConfigWriteAudit {

    /// Keys whose values must never be written to the log in clear.
    static let sensitiveKeys: Set<String> = [
        "secret",
        "authentication",
        "private-key",
        "private-key-passphrase",
    ]

    /// Key *paths* whose values are summarised rather than printed.
    ///
    /// A subscription URL is a bearer credential — anyone holding it can pull the
    /// user's whole node list — and `proxy-providers.NAME.url` is where it lives.
    /// The drift report only needs to say "this provider appeared / disappeared /
    /// changed", so the value is replaced by a stable fingerprint. The fingerprint
    /// is still stable across runs, so "same URL, new path" remains distinguishable
    /// from "different URL" without ever writing the URL down.
    static let summarizedKeySuffixes: [String] = [
        ".url",
        ".path",
        ".password",
        ".uuid",
        ".auth-key",
    ]

    /// Whether a key path should have its value replaced with a fingerprint.
    static func isSummarized(_ keyPath: String) -> Bool {
        let lower = keyPath.lowercased()
        if sensitiveKeys.contains(lower) { return true }
        let leaf = lower.split(separator: ".").last.map(String.init) ?? lower
        if sensitiveKeys.contains(leaf) || leaf == "token" { return true }
        return summarizedKeySuffixes.contains { lower == String($0.dropFirst()) || lower.hasSuffix($0) }
    }

    /// Stable, non-reversible fingerprint of a value. Derived from the
    /// value's bytes via `Hasher` with a process-stable seed is not available in
    /// this context, so a simple deterministic fold is used: the requirement is
    /// only that equal values fingerprint equally and different values do not.
    /// 全宽 64bit hex：旧版只留低 16 位，两条不同订阅 URL 在 4 万次写入的日志
    /// 尺度下足够撞出同指纹，把「URL 没变」误读成「URL 换了」（反之亦然）。
    static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a offset basis
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3               // FNV prime
        }
        return String(format: "<#%016llx>", hash)
    }

    /// Fixed replacement for a sensitive value. Deliberately constant so the
    /// log still shows "this changed" without leaking which secret it was.
    static let redaction = "<redacted>"

    /// Path of the append-only audit trail.
    ///
    /// Separate from `app.log` on purpose: `app.log` is truncated at ~2 MB and is
    /// read by humans; this file is the one that must still contain the answer
    /// months later, so it is truncated on a much larger budget (see `maxBytes`).
    static func auditPath() -> String {
        NSHomeDirectory() + "/Library/Logs/ClashHalo/config-writes.log"
    }

    /// Rotate threshold, ~4 MB: roughly 40k records at ~100 bytes each. Large
    /// enough to outlive any realistic debugging window, small enough that the
    /// log can never grow without bound on a machine left running for months.
    static let maxBytes = 4 * 1024 * 1024

    /// Render a sensitive value for the log: never the value itself, but a
    /// stable fingerprint, so a rotation still leaves a trace
    /// (`secret: <#a1b2> → <#c3d4>`). Equal values fingerprint equally, so
    /// "unchanged" stays distinguishable from "rotated" without ever writing
    /// the secret down（CFG-16：旧版返回常量 <redacted> 且 changes() 整条丢弃，
    /// secret 轮换零留痕）。
    static func redactedValue(for key: String, _ value: String) -> String {
        sensitiveKeys.contains(key.lowercased()) ? fingerprint(value) : value
    }

    /// Strip one layer of surrounding quotes.
    ///
    /// YAML treats `127.0.0.1:9090` and `'127.0.0.1:9090'` as the same scalar, and
    /// the profile legitimately quotes values the running config leaves bare. Without
    /// this, activating a profile whose `external-controller` was already correct
    /// logged a phantom change (`127.0.0.1:9090 → '127.0.0.1:9090'`), which is
    /// exactly the kind of noise that makes an audit trail untrustworthy — a reader
    /// who sees a change that did not happen stops believing the ones that did.
    static func normalizedValue(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("'") && value.hasSuffix("'")) ||
           (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Format one field of the "before → after" line, collapsing newlines so a
    /// multi-line value cannot break the one-record-per-line contract that makes
    /// the log greppable.
    static func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "(absent)" }
        let flattened = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if flattened == redaction { return flattened }
        return flattened.count > 120 ? String(flattened.prefix(120)) + "…" : flattened
    }

    /// Compare the top-level scalars of two config revisions and describe each
    /// change as `key: before → after`. Pure function: no I/O, so the diffing
    /// can be unit-tested against fixtures without touching a real config.
    ///
    /// Only top-level scalars are compared — the blocks people actually toggle
    /// from the settings page. Nested writes are reported by their parent key
    /// being absent from both sides is *not* silently dropped: callers pass the
    /// full flattened scalar view so a nested change still moves the parent.
    static func changes(from old: [String: String], to new: [String: String]) -> [String] {
        var out: [String] = []
        // 路径只标出使用方（url: *source），源值可能在任意模板键下。
        // 两版一起追踪依赖：删除 alias 引用的同一次写入也不能把旧源明文带出。
        let protectedSources = credentialSourceKeys(in: [old, new])
        for key in Set(old.keys).union(new.keys).sorted() {
            let before = old[key]
            let after = new[key]
            // Compare normalized so quote-style differences are not changes.
            let normBefore = before.map(normalizedValue)
            let normAfter = after.map(normalizedValue)
            guard normBefore != normAfter else { continue }
            // 使用方与源均保留稳定指纹，不能用常量遮盖凭据轮换。
            let protect = protectedSources.contains(key)
            out.append("\(key): \(render(before, forKey: key, forceSummary: protect)) → \(render(after, forKey: key, forceSummary: protect))")
        }
        return out
    }

    /// Parse the top-level scalar keys of a config revision.
    ///
    /// Mirrors the reader in `EngineControl.readConfigFile`: only unindented,
    /// non-comment lines with a colon, comment stripped with `YamlScalar`
    /// (whitespace-before-# rule, `#` inside quotes is data — so nameserver
    /// interface bindings like `100.100.100.100#utun8` survive intact). Nested
    /// blocks are represented by their parent key with value `(block)`, so a
    /// change confined to a nested block still shows up as a parent-level event
    /// rather than vanishing.
    static func topLevelScalars(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            guard !raw.isEmpty, !raw.hasPrefix(" "), !raw.hasPrefix("\t") else { continue }
            guard !raw.hasPrefix("#"), let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = YamlScalar.stripInlineComment(
                String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            ).trimmingCharacters(in: .whitespaces)
            out[key] = value.isEmpty ? "(block)" : value
        }
        return out
    }

    /// Top-level keys where the on-disk config disagrees with `profile`.
    ///
    /// Differences the app itself creates on every apply must NOT count as
    /// drift, or re-activating a profile would report drift on every single
    /// click. The exempt set is exactly `intentional` below — three writers
    /// （文档与代码对齐，F25：旧文档声称豁免「设置页 persistent 键」，代码里
    /// 并没有这一类，设置页键的漂移是调用方需要看到的真漂移）：
    ///   • hardenControllerConfig   → external-controller, secret
    ///   • forceTUNDisabled         → tun.enable
    ///   • injectMemoryOptimization → dns.size, dns.cache-algorithm
    /// Everything else appearing here means the running config has quietly
    /// diverged from what the profile says, which is what the caller needs in
    /// order to decide whether re-applying would be a no-op.
    ///
    /// Lives here rather than on `AppModel` so it can be compiled and fuzzed
    /// standalone: the app target pulls in SwiftUI, which no test harness can
    /// link against.
    static func drift(before: String, profile: String) -> [String] {
        // Keys the app rewrites on every apply by design, so a difference here is
        // the app working as intended rather than the config having drifted:
        //   • hardenControllerConfig  → external-controller, secret
        //   • forceTUNDisabled        → tun.enable
        //   • injectMemoryOptimization→ dns.size, dns.cache-algorithm
        // Treating these as drift would make every apply report differences and
        // destroy the signal — the whole point is that an *empty* result means
        // "re-applying would be a no-op".
        let intentional: Set<String> = [
            "external-controller",
            "secret",
            "tun.enable",
            "dns.size",
            "dns.cache-algorithm",
        ]
        let old = flattenedScalars(in: before)
        let new = flattenedScalars(in: profile)
        return changes(from: old, to: new).filter { line in
            guard let colon = line.firstIndex(of: ":") else { return true }
            let key = String(line[line.startIndex..<colon])
            return !intentional.contains(key)
        }
    }

    /// Every scalar key, with nested keys dotted by their parent (`dns.enable`).
    ///
    /// `topLevelScalars` alone is not enough to detect drift: it renders any
    /// nested block as the opaque value `(block)`, so a change confined inside one
    /// is invisible — measured, `dns.enable: true` → absent and
    /// `sniffer.enable: true` → `false` both produced *zero* drift, even though
    /// they are precisely the divergence seen on a real machine. A guard that
    /// cannot see the drift it exists to catch is worse than no guard, because it
    /// reports "nothing to repair" with confidence.
    ///
    /// Sequence values are rendered by count (`proxies: [3 items]`) rather than
    /// element-wise: proxies and rules carry subscription URLs and per-node
    /// credentials, and the point here is "did this change", not "what is in it".
    static func flattenedScalars(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []
        // Sequence elements (`- item`) are counted per owner rather than emitted
        // individually: proxies/rules carry subscription URLs and node
        // credentials, and the question here is whether the list changed, not
        // what is in it.
        var seqCounts: [String: Int] = [:]
        // Bug-2（test-core 探针实证）：序列项内嵌的更深缩进字段（`- name:` 下的
        // `server:` / `password:`）属于项本身，不是 owner 块的标量——旧实现把它们
        // 扁平成 proxies.server / proxies.password，节点服务器地址明文进审计日志，
        // 且 proxies 重排序产生幻影漂移。序列只按数量渲染（见上方文档），项内
        // 更深缩进一律跳过。
        var seqItemIndent: Int? = nil
        var blockScalar: (indent: Int, path: String)?

        for raw in text.components(separatedBy: "\n") {
            guard !raw.isEmpty else { continue }
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            let body = raw.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, !body.hasPrefix("#") else { continue }

            if let scalar = blockScalar {
                if indent > scalar.indent {
                    out[scalar.path, default: ""] += "\n" + body
                    continue
                }
                blockScalar = nil
            }
            if let si = seqItemIndent {
                if indent > si { continue }   // 项内嵌套内容，不展开
                seqItemIndent = nil
            }
            if body.hasPrefix("- ") || body == "-" {
                if let owner = stack.last {
                    let path = (stack.dropLast().map(\.key) + [owner.key]).joined(separator: ".")
                    seqCounts[path, default: 0] += 1
                }
                seqItemIndent = indent
                continue
            }
            let quotedKey = quotedKeyPrefix(in: body)
            // YAML block 映射的冒号后必须是分隔空白，URL 中的 :// 是内容。
            // 无键行接回父值，防止换行 anchor scalar 被拆成带凭据的假键。
            let colon = body.indices.first { index in
                guard body[index] == ":" else { return false }
                let next = body.index(after: index)
                return next == body.endIndex || body[next].isWhitespace
            }
            guard quotedKey != nil || colon != nil else {
                if let owner = stack.last, indent > owner.indent {
                    let path = stack.map(\.key).joined(separator: ".")
                    out[path, default: ""] += "\n" + body
                }
                continue
            }
            // 带引号的键（`"US-LH":`）剥掉首尾配对引号再入 path，与不带引号的
            // 同名键归一；取值起点相应后移（见 quotedKeyPrefix 的取舍说明）。
            let rawKey: String
            let rawValueStart: String.Index
            if let q = quotedKey {
                rawKey = q.key
                rawValueStart = q.afterColon
            } else if let colon {
                rawKey = String(body[body.startIndex..<colon])
                rawValueStart = body.index(after: colon)
            } else {
                continue
            }
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = YamlScalar.stripInlineComment(
                String(body[rawValueStart...]).trimmingCharacters(in: .whitespaces)
            ).trimmingCharacters(in: .whitespaces)
            while let top = stack.last, top.indent >= indent { stack.removeLast() }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            let nodeValue = yamlPayload(in: value)
            if nodeValue.hasPrefix("|") || nodeValue.hasPrefix(">") {
                blockScalar = (indent, path)
            }
            if nodeValue.isEmpty {
                // `defaults: &d` / `!!map &d` 仍是块头；不能让子字段掉到顶层。
                stack.append((indent, key))
                out[path] = value.isEmpty ? "(block)" : value
            } else {
                // 保留引号供 alias 词法分析；changes 已统一做引号归一，普通值
                // 比较不受影响，而 '*name' 不会被错认成真实引用。
                out[path] = value
            }
        }
        // Fold the counts in so growing or shrinking a list shows up as drift.
        for (path, count) in seqCounts {
            out[path] = "(seq: \(count))"
        }
        return out
    }

    /// 行首是带引号键（`"US-LH": …` / `'a:b': …`）时，返回剥引号后的键名与
    /// 值区起点（键分隔冒号之后）；否则返回 nil，调用方退回裸键路径。
    ///
    /// 为什么存在：profile 与运行配置对同一个键的引号写法可以不同
    /// （`proxy-providers."P".url` vs `proxy-providers.P.url`），不归一的话
    /// 同一 provider 的 URL 指纹对不上，凭据变化漏报、同值误报。
    ///
    /// 取舍：键内含冒号的 quoted key（`"a:b": v`）先找闭合引号、再从其后取
    /// 首个冒号，键内冒号得以保留。转义只做最常见的两式——单引号的 `''`、
    /// 双引号的 `\"` / `\\`——其余转义序列原样进键名：审计路径只要求
    /// 「同一键稳定归一」，不承诺完整 YAML 语义。找不到闭合引号（或闭合后
    /// 不是冒号）的畸形行返回 nil 退回旧行为：宁可脏键，也不把行丢掉。
    static func quotedKeyPrefix(in body: String) -> (key: String, afterColon: String.Index)? {
        guard let first = body.first, first == "\"" || first == "'" else { return nil }
        var idx = body.index(after: body.startIndex)
        var close: String.Index? = nil
        while idx < body.endIndex {
            let c = body[idx]
            if c == first {
                // 单引号转义 `''`：后一个还是引号则成对跳过。
                if first == "'",
                   let next = body.index(idx, offsetBy: 1, limitedBy: body.endIndex),
                   body[next] == "'" {
                    idx = body.index(after: next)
                    continue
                }
                // 双引号转义 `\"`：前置反斜杠则不是闭合。
                if first == "\"", body[body.index(before: idx)] == "\\" {
                    idx = body.index(after: idx)
                    continue
                }
                close = idx
                break
            }
            idx = body.index(after: idx)
        }
        guard let close else { return nil }
        // 闭合引号到冒号之间只允许空白，才是键分隔冒号。
        var cursor = body.index(after: close)
        while cursor < body.endIndex, body[cursor] == " " || body[cursor] == "\t" {
            cursor = body.index(after: cursor)
        }
        guard cursor < body.endIndex, body[cursor] == ":" else { return nil }
        let inner = String(body[body.index(after: body.startIndex)..<close])
        let key: String
        if first == "'" {
            key = inner.replacingOccurrences(of: "''", with: "'")
        } else {
            key = inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return (key, body.index(after: cursor))
    }

    /// Render one side of a change for the log.
    ///
    /// Credential-shaped keys (subscription URLs, paths, passwords) are reduced to
    /// a fingerprint instead of their value. The log's job is to say *whether* a
    /// value changed and *who* changed it; printing `proxy-providers.US-BWH.url`
    /// verbatim would put a live subscription token into a file that nobody treats
    /// as a secret, while the fingerprint still distinguishes "same URL, different
    /// provider" from "the URL itself was replaced".
    static func render(_ value: String?, forKey key: String, forceSummary: Bool = false) -> String {
        guard let value else { return display(value) }
        let node = yamlPayload(in: value)
        let payload = normalizedValue(node)
        let flow = node.hasPrefix("{") || node.hasPrefix("[")
        // 订阅 URL 可直接作为 bearer credential，不依赖字段名是否恰好叫 url。
        // 仅保守覆盖 HTTP(S) scalar，普通 mode/interval/非凭据模板不受影响。
        let url = payload.lowercased().hasPrefix("https://") || payload.lowercased().hasPrefix("http://")
        if forceSummary || isSummarized(key) || url || (flow && containsEmbeddedCredential(node)) {
            guard value != "(absent)", value != "(block)", !value.hasPrefix("(seq") else {
                return display(value)
            }
            // 装饰不是值：&source/!!str/引号不应改变相同 URL 的指纹。
            return fingerprint(payload.isEmpty ? value : payload)
        }
        return display(value)
    }

    /// 只拆 YAML node properties，不尝试执行 tag 或展开 alias。两种属性的
    /// 顺序可互换；!<tag:yaml.org,2002:map> 中的逗号不是 flow 分隔符。
    private static func yamlPayload(in raw: String) -> String {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = rest.first, first == "&" || first == "!" {
            let end: String.Index
            if rest.hasPrefix("!<"), let close = rest.firstIndex(of: ">") {
                end = rest.index(after: close)
            } else {
                end = rest.firstIndex { $0.isWhitespace || "{}[],".contains($0) } ?? rest.endIndex
            }
            guard end > rest.startIndex else { break }
            rest = String(rest[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest
    }

    /// 引用来自凭据字段时，反向保护 anchor 所在键。按两版键路径取并集，
    /// 不修改 flattenedScalars 的原值，也不把所有模板都变成同一常量。
    private static func credentialSourceKeys(in revisions: [[String: String]]) -> Set<String> {
        var definitions: [String: Set<String>] = [:]
        var valuesByKey: [String: [String]] = [:]
        var pending: [String] = []
        for revision in revisions {
            for (key, value) in revision {
                valuesByKey[key, default: []].append(value)
                for name in yamlReferenceNames(in: value, marker: "&") {
                    definitions[name, default: []].insert(key)
                }
                if isSummarized(key) {
                    pending += yamlReferenceNames(in: value, marker: "*")
                } else {
                    // 只沿 url/password 等字段追踪，不能把 flow 中无关的
                    // interval: *seconds 一起污染，破坏普通值的诊断可读性。
                    for credential in embeddedCredentialValues(value) {
                        pending += yamlReferenceNames(in: credential, marker: "*")
                    }
                }
            }
        }
        var visited: Set<String> = []
        var protected: Set<String> = []
        while let name = pending.popLast() {
            guard visited.insert(name).inserted else { continue } // 循环/重复引用有界
            for key in definitions[name] ?? [] {
                protected.insert(key)
                for value in valuesByKey[key] ?? [] {
                    pending += yamlReferenceNames(in: value, marker: "*")
                }
            }
        }
        return protected
    }

    /// 轻量词法扫描：引号里的 "*name" 是文本，URL query 的 & 也不是 anchor。
    private static func yamlReferenceNames(in value: String, marker: Character) -> [String] {
        let chars = Array(value)
        var names: [String] = []
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"" && c == "\\" { i += 2; continue }
                if c == q {
                    if q == "'", i + 1 < chars.count, chars[i + 1] == q { i += 2; continue }
                    quote = nil
                }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { quote = c; i += 1; continue }
            if c == marker, i == 0 || chars[i - 1].isWhitespace || "{[, :".contains(chars[i - 1]) {
                let start = i + 1
                var end = start
                while end < chars.count, !chars[end].isWhitespace, !"{}[],".contains(chars[end]) { end += 1 }
                if end > start { names.append(String(chars[start..<end])) }
                i = end
            } else {
                i += 1
            }
        }
        return names
    }

    /// 返回 flow 映射中凭据字段的值；字段名允许引号及冒号两侧空格。
    /// 不按子串找 url:，避免把非凭据的说明文本误当字段。
    private static func embeddedCredentialValues(_ raw: String) -> [String] {
        let value = yamlPayload(in: raw)
        guard value.hasPrefix("{") || value.hasPrefix("[") else { return [] }
        let chars = Array(value)
        var results: [String] = []
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"" && c == "\\" { i += 2; continue }
                if c == q {
                    if q == "'", i + 1 < chars.count, chars[i + 1] == q { i += 2; continue }
                    quote = nil
                }
                i += 1
                continue
            }
            if c == "{" || c == "," {
                var start = i + 1
                while start < chars.count, chars[start].isWhitespace { start += 1 }
                var end = start
                var key = ""
                if start < chars.count, chars[start] == "\"" || chars[start] == "'" {
                    let q = chars[start]
                    end = start + 1
                    while end < chars.count, chars[end] != q { end += 1 }
                    if end < chars.count { key = String(chars[(start + 1)..<end]); end += 1 }
                } else {
                    while end < chars.count, !chars[end].isWhitespace, !":={}[],".contains(chars[end]) { end += 1 }
                    key = String(chars[start..<end])
                }
                while end < chars.count, chars[end].isWhitespace { end += 1 }
                if end < chars.count, chars[end] == ":" || chars[end] == "=", isSummarized(key) {
                    let content = end + 1
                    let stop = flowValueEnd(in: chars, from: content)
                    results.append(String(chars[content..<stop]).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if c == "\"" || c == "'" { quote = c }
            i += 1
        }
        return results
    }

    private static func flowValueEnd(in chars: [Character], from start: Int) -> Int {
        var depth = 0
        var quote: Character?
        var i = start
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"" && c == "\\" { i += 2; continue }
                if c == q {
                    if q == "'", i + 1 < chars.count, chars[i + 1] == q { i += 2; continue }
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                if depth == 0 { return i }
                depth -= 1
            } else if c == "," && depth == 0 {
                return i
            }
            i += 1
        }
        return chars.count
    }

    static func containsEmbeddedCredential(_ value: String) -> Bool {
        !embeddedCredentialValues(value).isEmpty
    }

    /// Append one record. Never throws: an audit log that can break the config
    /// write it is observing would be worse than no audit log at all.
    ///
    /// - Parameters:
    ///   - writer: the call site that performed the write, for attribution.
    ///   - path: the file written (only `config.yaml` is interesting, but the
    ///     writer is generic so the field is recorded rather than assumed).
    ///   - changes: lines from `changes(from:to:)`; empty renders `(no changes)`.
    nonisolated static func record(writer: String, path: String, changes: [String]) {
        let dir = NSHomeDirectory() + "/Library/Logs/ClashHalo"
        let file = auditPath()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: file),
           let size = attrs[.size] as? NSNumber,
           size.intValue > maxBytes {
            try? fm.removeItem(atPath: file)
            append("[audit] rotated at \(size.intValue) bytes", to: file)
        }
        let file_ = (path as NSString).lastPathComponent
        if changes.isEmpty {
            append("\(writer) | \(file_) | (no changes)", to: file)
        } else {
            for change in changes {
                append("\(writer) | \(file_) | \(change)", to: file)
            }
        }
    }

    private nonisolated static func append(_ body: String, to file: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(body)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: file) {
            try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: file)) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
