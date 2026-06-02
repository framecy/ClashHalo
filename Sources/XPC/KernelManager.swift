import Foundation
import Combine
import SwiftUI

final class KernelManager: ObservableObject {
    static let shared = KernelManager()
    @AppStorage("kernel.channel") var channel = "stable"   // stable | alpha
    @Published var latestTag = ""
    @Published var assetURL = ""
    @Published var checking = false
    @Published var downloading = false
    @Published var progress = 0.0
    @Published var installedTags: [String] = []
    @Published var note = ""

    private let dir = NSHomeDirectory() + "/Library/Application Support/ClashPow/kernels"
    private var kernelJSONPath: String { NSHomeDirectory() + "/Library/Application Support/ClashPow/kernel.json" }
    @AppStorage("kernel.active") var activeTag = ""   // "" = embedded

    /// Switch to a downloaded kernel: write kernel.json + restart the engine,
    /// which respawns in supervisor mode running the external binary.
    func activate(_ tag: String) async {
        let bin = dir + "/\(tag)/mihomo"
        guard FileManager.default.fileExists(atPath: bin) else { note = "内核文件缺失"; return }
        let obj: [String: String] = ["external": bin, "tag": tag]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: URL(fileURLWithPath: kernelJSONPath))
        }
        activeTag = tag
        note = "正在切换到 \(tag)…"
        await EngineControl.shared.restart()
    }

    /// Revert to the embedded kernel: remove kernel.json + restart the engine.
    func useEmbedded() async {
        try? FileManager.default.removeItem(atPath: kernelJSONPath)
        activeTag = ""
        note = "正在切回内嵌内核…"
        await EngineControl.shared.restart()
    }

    func scanInstalled() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        installedTags = (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? []
    }

    func check() async {
        checking = true; note = ""; defer { checking = false }
        let api = channel == "alpha"
            ? "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
            : "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        guard let url = URL(string: api) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClashPow", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { note = "网络错误"; return }
        if let h = resp as? HTTPURLResponse, h.statusCode == 403 { note = "GitHub API 限流，请稍后再试"; return }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable { let tag_name: String; let assets: [Asset] }
        guard let r = try? JSONDecoder().decode(Release.self, from: data) else { note = "解析失败"; return }
        latestTag = r.tag_name
        // darwin-arm64, prefer non-"compatible"/non-go120 variant, .gz
        if let a = r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") && !$0.name.contains("compatible") && !$0.name.contains("go1") })
            ?? r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") }) {
            assetURL = a.browser_download_url
        } else { note = "未找到 darwin-arm64 资源" }
    }

    func download() async {
        guard let url = URL(string: assetURL), !latestTag.isEmpty else { return }
        downloading = true; progress = 0; note = ""; defer { downloading = false }
        guard let (tmp, _) = try? await URLSession.shared.download(from: url) else { note = "下载失败"; return }
        let fm = FileManager.default
        let tagDir = dir + "/\(latestTag)"
        try? fm.createDirectory(atPath: tagDir, withIntermediateDirectories: true)
        // decompress .gz → mihomo
        let out = tagDir + "/mihomo"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", tmp.path]
        let outFile = FileManager.default.createFile(atPath: out, contents: nil)
        guard outFile, let fh = FileHandle(forWritingAtPath: out) else { note = "写入失败"; return }
        p.standardOutput = fh
        do { try p.run(); p.waitUntilExit(); try? fh.close() } catch { note = "解压失败"; return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out)
        progress = 1; scanInstalled()
        note = "已下载 \(latestTag)（\(channel == "alpha" ? "Alpha" : "正式版")）"
    }
}
