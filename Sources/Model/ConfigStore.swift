import Foundation
import Combine
import SwiftUI

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
    func saveContent(_ id: String, _ text: String) { try? text.write(toFile: path(id), atomically: true, encoding: .utf8); touch(id) }
    private func touch(_ id: String) { if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].updatedAt = Date(); save() } }

    func addLocal(name: String, content: String) -> String {
        let id = UUID().uuidString
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
        profiles.append(Profile(id: id, name: name, source: "local", url: nil, importedAt: Date(), updatedAt: Date()))
        save(); return id
    }

    func importRemote(name: String, url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: u),
              let content = String(data: data, encoding: .utf8), content.contains(":") else { return nil }
        let id = UUID().uuidString
        try? content.write(toFile: path(id), atomically: true, encoding: .utf8)
        profiles.append(Profile(id: id, name: name, source: "remote", url: url, importedAt: Date(), updatedAt: Date()))
        save(); return id
    }

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

    /// Persist the selected profile as the engine's config.yaml (engine reloads it).
    func makeActiveContent(_ id: String) -> String? {
        let c = content(id); guard !c.isEmpty else { return nil }
        try? c.write(toFile: configPath, atomically: true, encoding: .utf8)
        activeID = id; return c
    }
}
