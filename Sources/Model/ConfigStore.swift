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
    @AppStorage("config.active") var activeID = ""

    private let dir = NSHomeDirectory() + "/Library/Application Support/ClashPow/profiles"
    private let configPath = NSHomeDirectory() + "/Library/Application Support/ClashPow/config.yaml"
    private var manifestPath: String { dir + "/manifest.json" }
    private let fm = FileManager.default

    func path(_ id: String) -> String { dir + "/\(id).yaml" }

    func load() {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = fm.contents(atPath: manifestPath),
           var list = try? JSONDecoder().decode([Profile].self, from: data) {
            for i in list.indices {
                if list[i].source == "remote" {
                    list[i].url = KeychainHelper.read(key: list[i].id)
                }
            }
            profiles = list
        }
        // Seed from the existing config.yaml on first run.
        if profiles.isEmpty {
            let id = UUID().uuidString
            let defaultContent = """
            mixed-port: 7890
            mode: rule
            log-level: info
            geox-url:
              mmdb: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/country.mmdb
              asn: https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb
              geosite: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat
              geoip: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat
            """
            let content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? defaultContent
            try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
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
    }

    private func save() {
        let sanitized = profiles.map { p -> Profile in
            if let u = p.url {
                KeychainHelper.save(key: p.id, value: u)
            }
            var copy = p
            copy.url = nil
            return copy
        }
        if let data = try? JSONEncoder().encode(sanitized) {
            try? data.write(to: URL(fileURLWithPath: manifestPath))
        }
    }

    func content(_ id: String) -> String { (try? String(contentsOfFile: path(id), encoding: .utf8)) ?? "" }
    func saveContent(_ id: String, _ text: String) {
        try? text.write(toFile: path(id), atomically: true, encoding: .utf8); touch(id)
        // Editing a profile bumps it to "stale Applied" (same content hash as
        // before markApplied re-stamps it) so the next activation will reload.
        if let i = profiles.firstIndex(where: { $0.id == id }) {
            profiles[i].appliedHash = nil
            save()
        }
    }
    private func touch(_ id: String) { if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].updatedAt = Date(); save() } }

    /// Persist a brand-new local YAML onto disk and into the manifest as a
    /// draft (`isApplied = false`). Does **not** write `config.yaml`, does
    /// **not** reload the kernel. The returned id is meant to be passed to
    /// `commit(_:)` once the user explicitly confirms the apply.
    @discardableResult
    func importLocalDraft(name: String, content: String) -> String {
        let id = UUID().uuidString
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
        let p = Profile(id: id, name: name, source: "local", url: nil,
                        importedAt: Date(), updatedAt: Date(), isApplied: false, appliedHash: nil)
        profiles.append(p); save(); return id
    }

    /// Download a remote subscription, persist it as a draft, return its id.
    /// Differentiates two degenerate responses: zero bytes, or a body that
    /// does not look like YAML at all (no `:` separator). Mirrors the
    /// pre-existing `importRemote` rule so a broken URL fails the same way
    /// regardless of which method you call from.
    @discardableResult
    func importRemoteDraft(name: String, url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: u),
              let content = String(data: data, encoding: .utf8), content.contains(":") else { return nil }
        let id = UUID().uuidString
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
        let p = Profile(id: id, name: name, source: "remote", url: url,
                        importedAt: Date(), updatedAt: Date(), isApplied: false, appliedHash: nil)
        profiles.append(p); save(); return id
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
    func updateRemote(_ id: String) async -> Bool {
        guard let p = profiles.first(where: { $0.id == id }), let url = p.url, let u = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let content = String(data: data, encoding: .utf8) else { return false }
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8); touch(id); return true
    }

    func remove(_ id: String) {
        try? fm.removeItem(atPath: path(id))
        KeychainHelper.delete(key: id)
        profiles.removeAll { $0.id == id }; save()
        if activeID == id { activeID = profiles.first?.id ?? "" }
    }

    // MARK: Apply pipeline (Phase 1: import isolation)

    /// Stage the profile for hot-apply: write `config.yaml`, update
    /// `activeID`, mark the profile as Pending-Apply. **Does not reload the
    /// kernel** — that's `engine.setConfig`'s job, driven by the caller.
    /// Returns the YAML content the caller should hand to `setConfig`.
    func commit(_ id: String) -> String? {
        let text = content(id); guard !text.isEmpty else { return nil }
        try? text.write(toFile: configPath, atomically: true, encoding: .utf8)
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
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[i].isApplied == false else { return }
        try? fm.removeItem(atPath: path(id))
        KeychainHelper.delete(key: id)
        profiles.removeAll { $0.id == id }; save()
    }

    /// Row-scan approximation of the YAML structure — no real parser. Stays
    /// in lockstep with `EngineControl.readConfigFile` / `proxyProviders`
    /// (same "top-level key + 2-space indent" rule) so what the user sees
    /// matches what the kernel will eventually count.
    func previewOfContent(_ text: String) -> YAMLPreview {
        var preview = YAMLPreview(); preview.bytes = text.utf8.count
        var inProxies = false, inGroups = false, inRules = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Top-level key detection: zero-indent, ends with `:`.
            let isTopKey: Bool
            if let first = line.first, first == " " || first == "\t" {
                isTopKey = false
            } else if trimmed.hasSuffix(":") {
                isTopKey = true
            } else { isTopKey = false }
            if isTopKey {
                let key = String(trimmed.dropLast())
                inProxies = (key == "proxies")
                inGroups = (key == "proxy-groups")
                inRules = (key == "rules")
                if key == "proxy-providers" { preview.hasProxyProviders = true }
                continue
            }
            if inRules && trimmed.hasPrefix("- ") {
                preview.ruleCount += 1
                continue
            }
            // 2-space-indented children of `proxies:` / `proxy-groups:`.
            if line.hasPrefix("  ") && !line.hasPrefix("   ") {
                if inGroups && trimmed.hasSuffix(":") {
                    preview.groupCount += 1
                    if preview.nodeNames.count < 20 {
                        preview.nodeNames.append(String(trimmed.dropLast()))
                    }
                } else if inProxies {
                    preview.nodeCount += 1
                    if trimmed.hasSuffix(":") && preview.nodeNames.count < 20 {
                        preview.nodeNames.append(String(trimmed.dropLast()))
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
