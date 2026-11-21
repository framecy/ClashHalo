import Foundation
import Combine
import SwiftUI

// MARK: - Import-time YAML preview

/// Lightweight, line-based summary of a YAML config — produced without a
/// full YAML parser. Used to show the user what they're importing before
/// committing to a kernel reload. Mirrors the row-scanning strategy used
/// by `EngineControl.readConfigFile` / `EngineControl.proxyProviders` /
/// `YamlRuleASTEngine.extractRules` so the counts stay consistent.
struct YAMLPreview: Equatable {
    var nodeCount: Int = 0
    var groupCount: Int = 0
    var ruleCount: Int = 0
    var hasProxyProviders: Bool = false
    var bytes: Int = 0
    var nodeNames: [String] = []
}

// MARK: - ConfigStore

@MainActor final class ConfigStore: ObservableObject {
    @Published var profiles: [Profile] = []
    /// 订阅跨 await 操作期间，不允许配置页删/刷新/编辑 profile 绕过业务锁。
    var providerMutationInFlight = false
    @AppStorage("config.active") var activeID = ""

    /// Set by `removeAll()`, cleared by any import.
    ///
    /// Without it the wipe does not survive a relaunch: `load()` seeds a
    /// "默认配置" whenever the manifest is empty, and `EngineControl.
    /// ensureInstalled()` recreates a factory config.yaml whenever the file is
    /// missing — so the next launch would helpfully reconstruct a profile from
    /// the very file the user just deleted.
    @AppStorage("config.wiped") var wiped = false

    private let dir = NSHomeDirectory() + "/Library/Application Support/ClashHalo/profiles"
    private let configPath = NSHomeDirectory() + "/Library/Application Support/ClashHalo/config.yaml"
    private var manifestPath: String { dir + "/manifest.json" }
    private let fm = FileManager.default

    /// 订阅下载专用 session：**必须直连，禁止继承系统代理**。
    ///
    /// 原来用 `URLSessionConfiguration.default`，它会带上系统代理/PAC 设置。
    /// ClashHalo 开系统代理时，订阅请求会先打到 127.0.0.1:mixed-port，再由
    /// mihomo 转发。问题出在「切换内核」时序上：换内核要先 `stopKernel`，
    /// 那 30s 窗口里 mixed-port 无人监听，此时任何订阅刷新都会黑洞（表现为
    /// 订阅一直转圈或"网络错误"），而用户看到的却是"订阅突然坏了"。
    /// 直连之后，订阅可用性只取决于用户的物理网络，不受内核重启窗口影响。
    /// 写法对齐 `KernelManager.session`（同一理由：内核下载也必须直连）。
    /// 超时保持原值：慢服务器 30s 内必须给出响应，整体 60s 封顶。
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        // 空 proxy 字典 = 本 session 忽略系统代理与 PAC，强制直连出口。
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    func path(_ id: String) -> String { dir + "/\(id).yaml" }

    /// 用订阅专用（直连、不吃系统代理）会话取回一份远程内容。
    /// 返回值只看 HTTP 200 + UTF-8；内容格式由 `NodeSubscription` 判定。
    func download(_ url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, response) = try? await session.data(from: u),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    /// profiles/*.yaml 的唯一写盘入口：atomic write 默认落 0644，写完必须收回
    /// 0600——profile 与 config.yaml 含同样的订阅凭据，后者 0600 前者不能裸奔
    /// （CFG-20）。所有写 profile 的路径都走这里，不再各自 try? write。
    @discardableResult
    private func writeProfileFile(_ id: String, _ text: String) -> Bool {
        let p = path(id)
        do {
            try text.write(toFile: p, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
            return try String(contentsOfFile: p, encoding: .utf8) == text
        } catch { return false }
    }

    /// provider 事务只改 profile 内容，元数据等内核确认后再提交；失败由调用方回滚。
    func writeProviderProfile(_ id: String, text: String) throws {
        guard profiles.contains(where: { $0.id == id }), writeProfileFile(id, text) else {
            throw ProviderOperationError.message("无法写入订阅所属配置，未完成保存")
        }
    }

    func finishProviderProfile(_ id: String, text: String, applied: Bool) -> Bool {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[i].updatedAt = Date()
        profiles[i].isApplied = applied
        profiles[i].appliedHash = applied ? Sha1.hex(text) : nil
        return save()
    }

    /// 覆写前备份（CFG-18）：`<id>.yaml.bak-<时间戳>`，只保留最近 3 份。
    /// 校验再严也可能有盲区，备份让用户能回滚。备份同样 0600。
    private func backupProfileFile(_ id: String) {
        let src = path(id)
        guard fm.fileExists(atPath: src) else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let dst = src + ".bak-" + df.string(from: Date())
        try? fm.copyItem(atPath: src, toPath: dst)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst)
        pruneBackups(id, keeping: 3)
    }

    /// 备份清理：时间戳定宽，字典序即时间序。keeping=0 用于删除 profile 时
    /// 连备份一起清——备份含同样凭据，「删除配置」不能把它们留在盘上。
    private func pruneBackups(_ id: String, keeping: Int) {
        let prefix = (path(id) as NSString).lastPathComponent + ".bak-"
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let baks = items.filter { $0.hasPrefix(prefix) }.sorted()
        for name in baks.dropLast(keeping) {
            try? fm.removeItem(atPath: dir + "/" + name)
        }
    }

    func load() {
        // profiles 目录与 config.yaml 一样装着订阅凭据：0700（CFG-20）。
        // createDirectory 的 attributes 只对新建生效，旧版留下的 0755 目录
        // 需要显式修复一次。
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        if let data = fm.contents(atPath: manifestPath),
           var list = try? JSONDecoder().decode([Profile].self, from: data) {
            for i in list.indices {
                if list[i].source == "remote" {
                    list[i].url = KeychainHelper.read(key: list[i].id)
                }
            }
            profiles = list
        }
        loadProviderSources()
        // Seed from the existing config.yaml on first run — but not after an
        // explicit wipe, where an empty list is the state the user asked for.
        if profiles.isEmpty && !wiped {
            let id = UUID().uuidString
            let defaultContent = """
            mixed-port: 7890
            mode: rule
            log-level: info
            geox-url:
              mmdb: https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb
              asn: https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb
              geosite: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat
              geoip: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat
            """
            var content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? defaultContent
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content = defaultContent
            }
            writeProfileFile(id, content)
            let p = Profile(id: id, name: "默认配置", source: "local", url: nil, importedAt: Date(), updatedAt: Date())
            profiles = [p]; activeID = id; save()
        }
        if activeID.isEmpty { activeID = profiles.first?.id ?? "" }
        // Legacy manifests (no `isApplied`) are reconciled once and persisted:
        // every pre-existing profile is marked Applied so the user does not
        // see spurious "待应用" badges after upgrade. The currently active
        // one additionally gets its `appliedHash` stamped so future
        // re-activations can detect no-op reloads.
        var reconciled = false
        for i in profiles.indices where profiles[i].isApplied == nil {
            profiles[i].isApplied = true
            reconciled = true
            if profiles[i].id == activeID,
               let text = try? String(contentsOfFile: path(profiles[i].id), encoding: .utf8) {
                profiles[i].appliedHash = Sha1.hex(text)
            }
        }
        if reconciled { save() }
        // 修复存量 profile 权限：旧版写盘是 0644，而它们与 config.yaml 含同样的
        // 订阅凭据（CFG-20）。文件不存在时 setAttributes 静默失败，无副作用。
        for p in profiles {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path(p.id))
        }
    }

    /// 保存清单与所有订阅 URL（URL 本体进 Keychain，manifest 里清空）。
    ///
    /// 返回 false 表示这次持久化没完全成功（Keychain 写入失败或 manifest 落盘失败），
    /// 失败细节写入 app.log。调用方多数不需要处理返回值（`@discardableResult`），
    /// 但订阅导入/应用这类用户可见路径可以据此提示。
    ///
    /// 隐私不变量（不可破坏）：manifest.json **绝不能**含真实订阅 URL——
    /// 它会被 `ConfigWriteAudit`、备份、用户手动拷贝带出去。URL 只存 Keychain
    /// + 0600 镜像文件，manifest 里一律 `url = nil`。
    @discardableResult
    func save() -> Bool {
        var failedIDs: [String] = []
        let sanitized = profiles.map { p -> Profile in
            if let u = p.url {
                if !KeychainHelper.save(key: p.id, value: u) {
                    failedIDs.append(p.id)
                }
            }
            var copy = p
            copy.url = nil          // 隐私不变量：manifest 不留 URL
            return copy
        }
        var ok = true
        if !failedIDs.isEmpty {
            // OSStatus 码没有从 KeychainHelper.save 暴露出来（签名只返回 Bool，
            // 且内部已按「Keychain 失败但镜像存在就算成功」聚合），所以这里
            // 只能记到 key 名粒度。要更细的 errSec* 诊断需要改 KeychainHelper 的
            // 返回值类型——超出本次改动范围。
            let list = failedIDs.map { String($0.prefix(8)) }.joined(separator: ", ")
            AppModel.appendAppLog("配置保存：订阅 URL 写入 Keychain 失败 [id=\(list)]（镜像文件可能仍可用）")
            ok = false
        }
        do {
            let data = try JSONEncoder().encode(sanitized)
            // Atomic — this is the only non-YAML state file in the app, and a
            // torn manifest makes load() silently rebuild a single "默认配置"
            // profile from config.yaml, orphaning every profiles/<id>.yaml.
            try data.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
        } catch {
            AppModel.appendAppLog("配置保存：manifest.json 写入失败 \(error.localizedDescription)")
            return false
        }
        return ok
    }

    func content(_ id: String) -> String { (try? String(contentsOfFile: path(id), encoding: .utf8)) ?? "" }
    @discardableResult
    func saveContent(_ id: String, _ text: String) -> Bool {
        guard !providerMutationInFlight, writeProfileFile(id, text) else { return false }
        touch(id)
        if let i = profiles.firstIndex(where: { $0.id == id }) {
            profiles[i].appliedHash = nil
            profiles[i].isApplied = false
            return save()
        }
        return false
    }
    private func touch(_ id: String) { if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].updatedAt = Date(); save() } }

    /// Persist a brand-new local YAML onto disk and into the manifest as a
    /// draft (`isApplied = false`). Does **not** write `config.yaml`, does
    /// **not** reload the kernel. The returned id is meant to be passed to
    /// `commit(_:)` once the user explicitly confirms the apply.
    @discardableResult
    func importLocalDraft(name: String, content: String) -> String {
        let id = UUID().uuidString
        writeProfileFile(id, Self.normalizeForWrite(content, context: "导入本地配置「\(name)」"))
        let p = Profile(id: id, name: name, source: "local", url: nil,
                        importedAt: Date(), updatedAt: Date(), isApplied: false, appliedHash: nil)
        profiles.append(p); wiped = false; save(); return id
    }

    /// Import a remote subscription from pre-downloaded content, persist it as a draft, return its id.
    @discardableResult
    func importRemoteDraft(name: String, url: String, content: String) -> String {
        let id = UUID().uuidString
        writeProfileFile(id, Self.normalizeForWrite(content, context: "导入订阅「\(name)」"))
        let p = Profile(id: id, name: name, source: "remote", url: url,
                        importedAt: Date(), updatedAt: Date(), isApplied: false, appliedHash: nil)
        profiles.append(p); wiped = false; save(); return id
    }

    /// Download a remote subscription, persist it as a draft, return its id.
    /// Differentiates two degenerate responses: zero bytes, or a body that
    /// does not look like YAML at all (no `:` separator). Mirrors the
    /// pre-existing `importRemote` rule so a broken URL fails the same way
    /// regardless of which method you call from.
    @discardableResult
    func importRemoteDraft(name: String, url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, response) = try? await session.data(from: u),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let content = String(data: data, encoding: .utf8), !content.isEmpty else { return nil }
        // 旧实现要求 `content.contains(":")`：base64 字母表不含冒号，于是所有
        // `.txt` + base64 分享链接订阅在导入这一步就被判成「下载失败」。
        // 归一化在 importRemoteDraft(content:) 里统一做。
        return importRemoteDraft(name: name, url: url, content: content)
    }

    /// Restore the legacy "import-and-apply in one shot" path for any
    /// existing call sites. Internally funnels through the new draft/commit
    /// split so the lifecycle stays consistent. Returns the profile id.
    @discardableResult
    func addLocal(name: String, content: String) -> String {
        importLocalDraft(name: name, content: content)
    }

    /// Legacy auto-apply remote import — keeps the same external semantics
    /// but routes through the draft path. Callers still call `activateProfile`
    /// afterwards to push it to the kernel.
    @discardableResult
    func importRemote(name: String, url: String) async -> String? {
        await importRemoteDraft(name: name, url: url)
    }

    /// Refresh a remote subscription's file contents, keeping the existing
    /// `isApplied` flag intact. A profile that was already applied stays
    /// applied; a draft stays a draft (the caller decides when to promote).
    /// Does not overwrite the local file if download fails or returns invalid content.
    func updateRemote(_ id: String) async -> Bool {
        guard !providerMutationInFlight else { return false }
        let before = content(id)
        guard let p = profiles.first(where: { $0.id == id }),
              let url = p.url,
              let u = URL(string: url) else { return false }
        
        do {
            let (data, response) = try await session.data(from: u)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                return false
            }
            
            // 先归一化：base64 分享链接订阅的 profile 内容是**转换后**的 YAML，
            // 刷新时若把原始 base64 直接覆盖回去，下一次 reload 必然失败。
            let normalized = Self.normalizeForWrite(content, context: "刷新订阅「\(p.name)」")

            // 内容必须带 mihomo 配置特征（CFG-18）：旧版只查 contains(":")，
            // 200 的 HTML 错误页（<title>Error: …</title> 也含冒号）拦不住，
            // 一次覆写就毁掉订阅文件。
            guard Self.looksLikeMihomoConfig(normalized) else {
                return false
            }

            guard !providerMutationInFlight, self.content(id) == before,
                  profiles.contains(where: { $0.id == id }) else { return false }
            backupProfileFile(id)
            guard writeProfileFile(id, normalized) else { return false }
            touch(id)
            return true
        } catch {
            return false
        }
    }

    /// 订阅内容是否像 mihomo 配置：先拒 HTML/XML（配置不会以 `<` 开头），
    /// 再要求至少一个顶层配置键。纯节点订阅至少有 proxies:，混合配置会有
    /// proxy-groups:/rules:/mixed-port: 等。
    private static func looksLikeMihomoConfig(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { return false }
        for raw in content.components(separatedBy: "\n") {
            guard !raw.hasPrefix(" "), !raw.hasPrefix("\t") else { continue }
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("proxies:") || t.hasPrefix("proxy-groups:") || t.hasPrefix("rules:")
                || t.hasPrefix("mixed-port:") || t.hasPrefix("port:") || t.hasPrefix("socks-port:") {
                return true
            }
        }
        return false
    }

    // MARK: - 转换后的本地 provider（base64 节点订阅）

    /// 所有源记录由 profileID + providerName 隔离；UI 只看当前配置的能力。
    let providerSourceStore = ProviderSourceStore(baseDirectory: URL(fileURLWithPath:
        NSHomeDirectory() + "/Library/Application Support/ClashHalo"))
    @Published private(set) var providerSourceRevision: UInt64 = 0

    var providerSources: [String: String] {
        Dictionary(uniqueKeysWithValues: providerSourceStore.records
            .filter { $0.profileID == activeID }.map { ($0.name, $0.url) })
    }
    var hasLegacyProviderSources: Bool { !providerSourceStore.legacySources.isEmpty }
    func noteProviderSourcesChanged() { providerSourceRevision &+= 1 }

    private func loadProviderSources() {
        do { try providerSourceStore.load(); noteProviderSourcesChanged() }
        catch { AppModel.appendAppLog("[Subscriptions] 本地订阅索引读取失败，未自动恢复源地址") }
    }

    // MARK: - Base64 分享链接订阅

    struct NormalizedContent {
        var yaml: String
        /// 是否发生了「分享链接列表 → mihomo YAML」的转换
        var converted: Bool
        /// 转换时被跳过的条目及原因
        var skipped: [String]
    }

    /// 把订阅/导入的原始响应体归一化成可以直接写盘的 mihomo YAML。
    ///
    /// 为什么收敛在存储层：写盘入口有四个（本地导入、远程导入同步版、远程导入
    /// 异步版、订阅刷新），任何一个漏掉都会把 base64 文本存成 profile —— 内核
    /// reload 失败，用户只看到「应用订阅失败」，完全看不出是格式问题。这正
    /// 是 `.txt` + base64 订阅「始终无法使用」的现场。
    ///
    /// 已经是 YAML 或无法识别时**原样返回**：拒绝坏内容的判定仍归
    /// `looksLikeMihomoConfig`（以及调用方），这里不做第二套准入规则。
    static func normalizedForProfile(_ raw: String) -> NormalizedContent {
        guard NodeSubscription.detect(raw) == .shareLinks else {
            return NormalizedContent(yaml: raw, converted: false, skipped: [])
        }
        let rendered = NodeSubscription.render(raw)
        guard let yaml = rendered.yaml else {
            return NormalizedContent(yaml: raw, converted: false, skipped: rendered.skipped)
        }
        return NormalizedContent(yaml: yaml, converted: true, skipped: rendered.skipped)
    }

    /// 转换并写 app.log。订阅刷新是静默路径，节点数比订阅页少时只有日志能
    /// 解释是哪几条被跳过了。
    private static func normalizeForWrite(_ raw: String, context: String) -> String {
        let n = normalizedForProfile(raw)
        if n.converted {
            let detail = n.skipped.isEmpty
                ? "全部成功"
                : "跳过 \(n.skipped.count) 条：\(n.skipped.joined(separator: "；"))"
            AppModel.appendAppLog("[Subscriptions] \(context)：base64 分享链接订阅已转换为 mihomo 配置（\(detail)）")
        }
        return n.yaml
    }


    @discardableResult
    func remove(_ id: String) -> Bool {
        guard !providerMutationInFlight, id != activeID,
              let oldText = try? String(contentsOfFile: path(id), encoding: .utf8) else { return false }
        let oldProfiles = profiles
        let oldID = activeID
        do {
            // profile 与清单成功移除后，才允许清源；源服务失败自带回滚。
            let target = URL(fileURLWithPath: path(id)).standardizedFileURL
            let root = URL(fileURLWithPath: dir).standardizedFileURL
            guard target.deletingLastPathComponent() == root,
                  target.resolvingSymlinksInPath() == target else { return false }
            try fm.removeItem(at: target)
            profiles.removeAll { $0.id == id }
            if activeID == id { activeID = profiles.first?.id ?? "" }
            guard save() else { throw ProviderOperationError.message("删除配置索引失败") }
            try providerSourceStore.removeProfile(id)
            noteProviderSourcesChanged()
            pruneBackups(id, keeping: 0)
            KeychainHelper.delete(key: id)
            return true
        } catch {
            profiles = oldProfiles
            activeID = oldID
            let restored = writeProfileFile(id, oldText)
            let saved = save()
            AppModel.appendAppLog(restored && saved ? "删除配置失败，已回滚" : "删除配置失败，回滚未完整完成")
            return false
        }
    }

    /// Kernel-side caches that belong to the profiles being deleted: proxy- and
    /// rule-provider downloads, and the store for fake-ip mappings / selected
    /// group members. All are rebuilt from whatever config comes next; keeping
    /// them would leave a deleted subscription's nodes and rulesets on disk.
    ///
    /// Deliberately excludes everything that is *not* configuration and would be
    /// expensive or breaking to lose: `bin/` and `kernels/` (the mihomo binary),
    /// `ui/` (bundled dashboards), the geo databases, and
    /// `traffic-history.json` (usage stats the user did not ask to erase).
    private var cachePaths: [String] {
        let base = (configPath as NSString).deletingLastPathComponent
        return ["providers", "ruleset", "proxies", "cache.db"].map { base + "/" + $0 }
    }

    /// Delete every profile — YAML files, manifest, Keychain-held subscription
    /// URLs — plus the active `config.yaml` and the kernel caches derived from
    /// them. Returns the names of items that could not be removed.
    ///
    /// Storage only. The caller must first bring the running state down
    /// (`AppModel.deleteAllProfiles`): a system proxy or a TUN left pointing at
    /// a kernel whose config just vanished takes the whole machine offline, and
    /// `forceTUNDisabled()` edits config.yaml, so it has to run while the file
    /// still exists.
    ///
    /// The failure list is not decoration. A kernel that ran as root leaves
    /// `proxies/` (and sometimes `ruleset/`) owned by root, and a user-mode app
    /// cannot unlink files inside a root-owned directory — the delete genuinely
    /// fails. Reporting it beats both silence and escalating this into a
    /// privileged "delete any path as root" XPC call.
    @discardableResult
    func removeAll() -> [String] {
        guard !providerMutationInFlight else { return ["订阅操作尚未结束"] }
        var failed: [String] = []
        for p in profiles {
            do { try fm.removeItem(atPath: path(p.id)) }
            catch { failed.append("配置文件") }
            pruneBackups(p.id, keeping: 0)
            KeychainHelper.delete(key: p.id)
        }
        profiles.removeAll()
        activeID = ""
        for path in [manifestPath, configPath] where fm.fileExists(atPath: path) {
            do { try fm.removeItem(atPath: path) }
            catch { failed.append((path as NSString).lastPathComponent) }
        }

        do { try providerSourceStore.removeAll(); noteProviderSourcesChanged() }
        catch { failed.append("本地订阅源与节点缓存") }
        for p in cachePaths where fm.fileExists(atPath: p) {
            do { try fm.removeItem(atPath: p) }
            catch { failed.append((p as NSString).lastPathComponent) }
        }
        wiped = true
        return failed
    }

    // MARK: Apply pipeline (Phase 1: import isolation)

    /// Stage the profile for hot-apply: write `config.yaml`, update
    /// `activeID`, mark the profile as Pending-Apply. **Does not reload the
    /// kernel** — that's `engine.setConfig`'s job, driven by the caller.
    /// Returns the YAML content the caller should hand to `setConfig`.
    func commit(_ id: String) -> String? {
        guard !providerMutationInFlight else { return nil }
        let text = content(id); guard !text.isEmpty else { return nil }
        // This is the writer that actually repairs drift, so it must appear in
        // the audit trail. It runs *before* `engine.setConfig` → `writeConfig`,
        // which therefore sees the profile already on disk and honestly logs
        // "(no changes)" for its own no-op rewrite — leaving the single write
        // that mattered unattributed. Measured: a switch that repaired
        // `sniffer.enable: false → true` produced no record naming this call.
        let before = (try? String(contentsOfFile: configPath, encoding: .utf8))
            .map(ConfigWriteAudit.flattenedScalars(in:))
        try? text.write(toFile: configPath, atomically: true, encoding: .utf8)
        // config.yaml may carry the tailnet auth-key in plain text — keep the
        // 0600 promise on this writer too (EngineControl covers its own).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        if let before {
            ConfigWriteAudit.record(
                writer: "ConfigStore.commit(\(id.prefix(8)))",
                path: configPath,
                changes: ConfigWriteAudit.changes(
                    from: before,
                    to: ConfigWriteAudit.flattenedScalars(in: text)
                )
            )
        }
        activeID = id
        if let i = profiles.firstIndex(where: { $0.id == id }) {
            // Mark Pending until `markApplied` confirms the kernel reload
            // succeeded; this is what the UI uses to show the spinner/badge.
            profiles[i].isApplied = false
            profiles[i].updatedAt = Date()
        }
        save()
        return text
    }

    /// Finalize a successful apply: the kernel accepted the YAML. Records
    /// the content hash so a future re-activation of identical content can
    /// skip the reload. Pass the same string already written in `commit`.
    func markApplied(_ id: String, hash: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].isApplied = true
        profiles[i].appliedHash = hash
        save()
    }

    /// Delete a profile that was imported as a draft but never applied.
    /// Applied profiles keep their file (the user can still deactivate via
    /// the legacy remove path; we just don't auto-clean them here).
    func discardDraft(_ id: String) {
        guard !providerMutationInFlight else { return }
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[i].isApplied == false else { return }
        _ = remove(id) // 与删除配置共用源/节点清理及回滚，不留下第三个写点。
    }

    /// 结构预览仍以行扫描为主；provider 的块/flow/模板检测复用
    /// ProviderConfiguration，与订阅页及源地址读取保持一致。
    func previewOfContent(_ text: String) -> YAMLPreview {
        var preview = YAMLPreview(); preview.bytes = text.utf8.count
        preview.hasProxyProviders = !ProviderConfiguration.entries(in: text).isEmpty
        // 组计数走唯一权威解析（与规则目标校验同口径）：标准组行是
        // `  - name: X`，行尾没有冒号——旧版要求 hasSuffix(":")，groupCount
        // 恒 0（CFG-11）。
        let groups = ProviderUsage.groupNames(in: text)
        preview.groupCount = groups.count
        for name in groups where preview.nodeNames.count < 20 {
            preview.nodeNames.append(name)
        }
        var inProxies = false, inRules = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Top-level key detection: zero-indent, ends with `:`.
            // 序列项（`- name:`）不算顶层键，与 ProviderUsage 口径一致；
            // 先剥行尾注释，`proxies: # 节点` 也是块键（与 insertRuleLine 同口径）。
            let bare = YamlScalar.stripInlineComment(trimmed)
            let isTopKey: Bool
            if let first = line.first, first == " " || first == "\t" {
                isTopKey = false
            } else if bare.hasSuffix(":") && !trimmed.hasPrefix("-") {
                isTopKey = true
            } else { isTopKey = false }
            if isTopKey {
                let key = String(bare.dropLast())
                inProxies = (key == "proxies")
                inRules = (key == "rules")
                if key == "proxy-providers" { preview.hasProxyProviders = true }
                continue
            }
            if inRules && trimmed.hasPrefix("- ") {
                preview.ruleCount += 1
                continue
            }
            // proxies: 的节点行。2 空格缩进与 0 缩进序列都是合法 YAML，
            // 旧版只认前者，0 缩进整段漏计（CFG-11）。
            let isItem = (line.hasPrefix("  ") && !line.hasPrefix("   "))
                || (!line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasPrefix("- "))
            if inProxies && isItem {
                preview.nodeCount += 1
                if preview.nodeNames.count < 20, trimmed.hasPrefix("- name:") {
                    if let name = ProviderUsage.scalar(String(trimmed.dropFirst("- name:".count))) {
                        preview.nodeNames.append(name)
                    }
                }
            }
        }
        return preview
    }

    /// Persist the selected profile as the engine's config.yaml (engine reloads it).
    /// Kept on the legacy name because `EngineControl.setConfig` reads the file
    /// directly — but the active marker (`isApplied/appliedHash`) is now Lazily
    /// updated by `commit` + `markApplied`, not here.
    func makeActiveContent(_ id: String) -> String? {
        commit(id)
    }
}
