import Foundation

/// v1.6.0 移除了内置 Tailnet（mihomo `type: tailscale` 出站 + overlay 注入）。
/// 本清理器是升级路径上的一次性兜底：旧版本留在磁盘上的节点、规则、`ts://`
/// DNS 策略、Keychain 凭据、UserDefaults 开关与 tsnet 状态目录必须清掉，否则
/// mihomo 会继续为幽灵节点拨号、`ts://` 策略继续劫持 `ts.net`。
///
/// 设计约束（每一条都由回归套件或真机演练钉住）：
/// - **引用完整性优先**：删掉节点后，指向它的 rules 与 `ts://` DNS 值必须同时
///   删。实测 mihomo 对「规则引用不存在的节点」是 `level=fatal` 直接退出，
///   不是跳过——残留就等于升级后内核起不来、用户只看到「一直连不上」。
/// - **写完自证**：用 `mihomo -d <dir> -t` 校验；错误提到本次被删节点才回滚，
///   与本次无关的坏配置放行（否则永远清不掉）。
/// - **幂等**：可反复运行；只有零告警且零凭据残留才写完成标记（仅作观测，
///   不作为跳过条件——降级回 1.5.x 再升级上来仍需清理）。
/// - 纯同步、不碰 MainActor；磁盘写入由调用方注入（生产走
///   `EngineControl.writeConfigFile`，保住审计日志与 0600）。
enum TailnetRemnantCleaner {

    static let fenceBegin = "# >>> clashhalo:tailscale >>>"
    static let fenceEnd = "# <<< clashhalo:tailscale <<<"
    static let stateDirName = "tailscale"
    static let nodeNameKey = "tailscale.nodeName"
    static let defaultsPrefix = "tailscale."
    static let authKeyAccount = "tailscale.authkey"
    static let apiTokenAccount = "tailscale.api.token"
    static let doneKey = "tailnet.remnantCleaned"

    struct Report: Sendable {
        var ran = false
        var changedFiles: [String] = []
        var removedNodes: [String] = []
        var keychainResidue: [String] = []
        var stateDirRetired = false
        var warnings: [String] = []
        var configChanged: Bool {
            changedFiles.contains { ($0 as NSString).lastPathComponent == "config.yaml" }
        }
    }

    struct Scrub: Equatable {
        var yaml: String
        var nodes: [String] = []
        var lines = 0
        var changed: Bool { lines > 0 }
    }

    // MARK: - 纯逻辑

    static func scrub(_ yaml: String, names: Set<String>) -> Scrub {
        let src = yaml.components(separatedBy: "\n")
        var kept: [String] = []
        var removed = Set<String>()
        var dropped = 0
        var inProxies = false
        var i = 0

        while i < src.count {
            let raw = src[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t == fenceBegin || t == fenceEnd { dropped += 1; i += 1; continue }
            if isTopLevelKey(raw) {
                inProxies = t == "proxies:" || t.hasPrefix("proxies:")
                kept.append(raw); i += 1; continue
            }
            if inProxies, t.hasPrefix("- ") {
                let (item, next) = proxyItem(in: src, at: i)
                let text = item.joined(separator: "\n")
                if isOurs(text, names: names) {
                    if let n = proxyName(text) { removed.insert(n) }
                    dropped += item.count
                    i = next
                    continue
                }
                kept.append(contentsOf: item); i = next; continue
            }
            kept.append(raw); i += 1
        }

        let targets = names.union(removed)
        var out: [String] = []
        for line in kept {
            if !targets.isEmpty,
               isRuleTargeting(line, targets: targets) || isTsNameserver(line, targets: targets) {
                dropped += 1; continue
            }
            out.append(line)
        }
        // 摘掉 ts:// 后若某个 policy 条目的值全没了，必须连条目键一起删：
        // mihomo 对 `"+.ts.net":`（null 值）是 panic（nil pointer），不是校验失败，
        // 会直接把内核打死——正是本清理器要防的「升级后连不上」。
        let pruned = pruneDanglingPolicyEntries(out)
        dropped += pruned.removed
        return Scrub(yaml: pruned.lines.joined(separator: "\n"), nodes: removed.sorted(), lines: dropped)
    }

    /// 删除 `nameserver-policy:` 块内「值已被清空」的条目键（null 值会让 mihomo panic）。
    private static func pruneDanglingPolicyEntries(_ lines: [String]) -> (lines: [String], removed: Int) {
        guard let hdr = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "nameserver-policy:"
        }) else { return (lines, 0) }
        let hdrIndent = lines[hdr].prefix { $0 == " " }.count
        var out: [String] = []
        var removed = 0
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent > hdrIndent, trimmed.hasSuffix(":") {
                var j = i + 1
                var hasValue = false
                while j < lines.count {
                    let lj = lines[j]
                    let tj = lj.trimmingCharacters(in: .whitespaces)
                    if tj.isEmpty { j += 1; continue }
                    hasValue = lj.prefix { $0 == " " }.count > indent
                    break
                }
                if !hasValue { removed += 1; i += 1; continue }
            }
            out.append(line)
            i += 1
        }
        return (out, removed)
    }

    static func tsReferences(in text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.components(separatedBy: "\n") {
            guard let r = line.range(of: "ts://") else { continue }
            var rest = line[r.upperBound...]
            while let first = rest.first, first == "\"" || first == " " { rest = rest.dropFirst() }
            let name = rest.prefix { $0 != "\"" && $0 != "," && $0 != " " && $0 != "}" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    // MARK: - 有副作用的入口

    @discardableResult
    static func run(configPath: String,
                    profilesDir: String?,
                    kernelPath: String?,
                    writeConfig: (String) -> Bool,
                    defaults: UserDefaults = .standard,
                    deleteKeychain: (String) -> Bool = { KeychainHelper.delete(key: $0) },
                    readKeychain: (String) -> String? = { KeychainHelper.read(key: $0) }) -> Report {
        var report = Report()
        report.ran = true
        let d = defaults

        let root = (configPath as NSString).deletingLastPathComponent
        var names = Set<String>()
        if let n = d.string(forKey: nodeNameKey), !n.isEmpty { names.insert(n) }

        let original = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        names.formUnion(tsReferences(in: original))

        if !original.isEmpty {
            let s = scrub(original, names: names)
            if s.changed, s.yaml != original {
                if writeConfig(s.yaml) {
                    // 报告先记被摘节点：校验降级（内核不可用）时它仍然是用户
                    // 需要知道的事实；只有回滚才清空——盘上的节点又回来了。
                    report.removedNodes = s.nodes
                    switch validate(root: root, kernel: kernelPath,
                                    removed: names.union(s.nodes)) {
                    case .ok:
                        report.changedFiles.append(configPath)
                    case .failed(let msg):
                        _ = writeConfig(original)
                        report.removedNodes = []
                        report.warnings.append("config.yaml 清理未通过校验，已回滚：\(msg)")
                    case .unavailable:
                        report.changedFiles.append(configPath)
                        report.warnings.append("内核不可用，config.yaml 清理未做 mihomo -t 自证")
                    }
                } else {
                    report.warnings.append("config.yaml 不可写，清理未执行")
                }
            }
        }

        if let dir = profilesDir,
           let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for name in items where name.hasSuffix(".yaml") || name.contains(".yaml.bak-") {
                let p = dir + "/" + name
                guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
                let s = scrub(text, names: names)
                if s.changed, write(s.yaml, to: p) {
                    report.changedFiles.append(p)
                }
            }
        }

        for acct in [authKeyAccount, apiTokenAccount] {
            _ = deleteKeychain(acct)
            if readKeychain(acct) != nil { report.keychainResidue.append(acct) }
        }

        for k in d.dictionaryRepresentation().keys where k.hasPrefix(defaultsPrefix) {
            d.removeObject(forKey: k)
        }

        let retired = retireStateDir(root: root, report: &report)
        report.stateDirRetired = retired

        if report.warnings.isEmpty && report.keychainResidue.isEmpty {
            d.set(true, forKey: doneKey)
        }
        return report
    }

    // MARK: - 内部实现

    enum Validation { case ok, failed(String), unavailable }

    static func validate(root: String, kernel: String?, removed: Set<String>) -> Validation {
        guard let kernel, FileManager.default.fileExists(atPath: kernel) else { return .unavailable }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: kernel)
        p.arguments = ["-d", root, "-t"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return .unavailable }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .ok }
        let out = String(data: data, encoding: .utf8) ?? ""
        // panic（例如 nameserver-policy 出现 null 值）不是「与本次无关的坏配置」，
        // 它会把内核直接打死；必须算失败并回滚。
        if out.contains("panic:") { return .failed("配置校验 panic（内核崩溃）") }
        let err = out.split(separator: "\n")
            .last { $0.contains("level=error") || $0.contains("level=fatal") }
            .map(String.init) ?? "配置校验失败"
        let ours = removed.contains { err.contains("[\($0)]") || err.contains("\($0)") }
        return ours ? .failed(err) : .ok
    }

    private static func retireStateDir(root: String, report: inout Report) -> Bool {
        let fm = FileManager.default
        let dir = root + "/" + stateDirName
        guard fm.fileExists(atPath: dir) else { return false }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let dst = dir + ".retired-" + df.string(from: Date())
        do { try fm.moveItem(atPath: dir, toPath: dst) }
        catch {
            report.warnings.append("tailscale 状态目录改名失败，已保留：\(error.localizedDescription)")
            return false
        }
        if let items = try? fm.contentsOfDirectory(atPath: root) {
            let stale = items.filter { $0.hasPrefix(stateDirName + ".retired-") }
                .sorted().dropLast()
            for n in stale { try? fm.removeItem(atPath: root + "/" + n) }
        }
        return true
    }

    private static func write(_ text: String, to path: String) -> Bool {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return (try? String(contentsOfFile: path, encoding: .utf8)) == text
        } catch { return false }
    }

    private static func isTopLevelKey(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !line.hasPrefix(" ") && !line.hasPrefix("\t")
            && !t.isEmpty && !t.hasPrefix("-") && !t.hasPrefix("#") && t.contains(":")
    }

    private static func proxyItem(in lines: [String], at start: Int) -> ([String], Int) {
        let indent = lines[start].prefix { $0 == " " }.count
        if lines[start].contains("{") { return ([lines[start]], start + 1) }
        var end = start + 1
        while end < lines.count {
            let l = lines[end]
            let t = l.trimmingCharacters(in: .whitespaces)
            let ind = l.prefix { $0 == " " }.count
            if t.isEmpty || ind <= indent { break }
            end += 1
        }
        return (Array(lines[start..<end]), end)
    }

    private static func isOurs(_ item: String, names: Set<String>) -> Bool {
        let isTS = item.contains("type: tailscale") || item.contains("type: \"tailscale\"")
        guard isTS else { return false }
        if item.contains("state-dir: \(stateDirName)")
            || item.contains("state-dir: \"\(stateDirName)\"")
            || item.contains("auth-key:") { return true }
        if let n = proxyName(item), names.contains(n) { return true }
        return false
    }

    private static func proxyName(_ item: String) -> String? {
        for line in item.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("name:") || t.hasPrefix("- name:")
                    || t.hasPrefix("{name:") || t.contains(", name:")
                    || t.contains("- {name:") else { continue }
            guard let r = line.range(of: "name:") else { continue }
            var rest = line[r.upperBound...].drop { $0 == " " || $0 == "\t" }
            var v: String
            if rest.first == "\"" {
                // flow-map / 带引号：取到下一个引号为止
                let inner = rest.dropFirst()
                v = String(inner.prefix { $0 != "\"" })
            } else {
                // 无引号：取到 , 或 } 或行尾，再 rtrim
                let end = rest.firstIndex { $0 == "," || $0 == "}" } ?? rest.endIndex
                v = rest[..<end].trimmingCharacters(in: .whitespaces)
            }
            if !v.isEmpty { return v }
        }
        return nil
    }

    private static func isRuleTargeting(_ line: String, targets: Set<String>) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- "), !t.contains("{") else { return false }
        let parts = t.dropFirst(2).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 2 else { return false }
        return targets.contains(parts.count >= 3 ? parts[2] : parts[1])
    }

    private static func isTsNameserver(_ line: String, targets: Set<String>) -> Bool {
        guard let r = line.range(of: "ts://") else { return false }
        var rest = line[r.upperBound...]
        while let f = rest.first, f == "\"" || f == " " { rest = rest.dropFirst() }
        let name = String(rest.prefix { $0 != "\"" && $0 != "," && $0 != " " && $0 != "}" })
        return targets.contains(name)
    }
}
