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
        return summarizedKeySuffixes.contains { lower.hasSuffix($0) }
    }

    /// Stable, non-reversible short fingerprint of a value. Derived from the
    /// value's bytes via `Hasher` with a process-stable seed is not available in
    /// this context, so a simple deterministic fold is used: the requirement is
    /// only that equal values fingerprint equally and different values do not.
    static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a offset basis
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3               // FNV prime
        }
        return String(format: "<#%04x>", hash & 0xffff)
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
        for key in Set(old.keys).union(new.keys).sorted() {
            let before = old[key]
            let after = new[key]
            // Compare normalized so quote-style differences are not changes.
            let normBefore = before.map(normalizedValue)
            let normAfter = after.map(normalizedValue)
            guard normBefore != normAfter else { continue }
            // secret 轮换必须留痕（CFG-16）：值本体永不进日志，但指纹对能看出
            // 「换过了」。旧版在这里 continue 整条丢弃，轮换控制面密钥后
            // config-writes.log 里一条记录都没有，排查 401 时无据可查。
            if sensitiveKeys.contains(key.lowercased()) {
                let b = before.map { redactedValue(for: key, $0) }
                let a = after.map { redactedValue(for: key, $0) }
                out.append("\(key): \(display(b)) → \(display(a))")
                continue
            }
            out.append("\(key): \(render(before, forKey: key)) → \(render(after, forKey: key))")
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

        for raw in text.components(separatedBy: "\n") {
            guard !raw.isEmpty else { continue }
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            let body = raw.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, !body.hasPrefix("#") else { continue }

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
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = YamlScalar.stripInlineComment(
                String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            ).trimmingCharacters(in: .whitespaces)
            while let top = stack.last, top.indent >= indent { stack.removeLast() }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            if value.isEmpty {
                stack.append((indent, key))
                out[path] = "(block)"
            } else {
                out[path] = normalizedValue(value)
            }
        }
        // Fold the counts in so growing or shrinking a list shows up as drift.
        for (path, count) in seqCounts {
            out[path] = "(seq: \(count))"
        }
        return out
    }

    /// Render one side of a change for the log.
    ///
    /// Credential-shaped keys (subscription URLs, paths, passwords) are reduced to
    /// a fingerprint instead of their value. The log's job is to say *whether* a
    /// value changed and *who* changed it; printing `proxy-providers.US-BWH.url`
    /// verbatim would put a live subscription token into a file that nobody treats
    /// as a secret, while the fingerprint still distinguishes "same URL, different
    /// provider" from "the URL itself was replaced".
    static func render(_ value: String?, forKey key: String) -> String {
        guard let value else { return display(value) }
        if isSummarized(key) {
            guard value != "(absent)", value != "(block)", !value.hasPrefix("(seq") else {
                return display(value)
            }
            return fingerprint(value)
        }
        // 内联 flow 映射把凭据藏在一个非凭据形状的键里（CFG-16）：
        // `proxy-providers: {US: {type: http, url: https://…token…}}` 被行扫描
        // 拍平成键为 "proxy-providers" 的单个标量，isSummarized 不命中，旧版
        // 就把订阅 URL 明文写进了日志。检测到内嵌 url:/url=/"url": 等字段时
        // 整个值指纹化。
        if (value.hasPrefix("{") || value.hasPrefix("[")), containsEmbeddedCredential(value) {
            return fingerprint(value)
        }
        return display(value)
    }

    /// flow 标量里是否内嵌凭据字段（`url:` / `url=` / `"url":`， likewise
    /// password/uuid/auth-key/secret/token）。与 summarizedKeySuffixes 同一族。
    static func containsEmbeddedCredential(_ value: String) -> Bool {
        let lower = value.lowercased()
        for field in ["url", "password", "uuid", "auth-key", "secret", "token"] {
            if lower.contains("\(field):") || lower.contains("\(field)=")
                || lower.contains("\"\(field)\":") || lower.contains("'\(field)':") {
                return true
            }
        }
        return false
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
