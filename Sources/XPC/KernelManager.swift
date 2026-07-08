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
    @Published var builtinVersion = ""   // version of the bundled kernel, if any

    @AppStorage("kernel.stable.tag") var installedStableTag = ""
    @AppStorage("kernel.alpha.date") var installedAlphaDate = ""
    private var tempPublishDate = ""
    private var tempTagName = ""

    private let dir = NSHomeDirectory() + "/Library/Application Support/ClashHalo/kernels"
    private var binPath: String { NSHomeDirectory() + "/Library/Application Support/ClashHalo/bin/mihomo" }
    @AppStorage("kernel.active") var activeTag = "内置"

    /// URLSession with timeout for kernel downloads (2min resource timeout for large binaries)
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// Whether a kernel is bundled inside the app.
    var hasBuiltin: Bool { Bundle.main.url(forResource: "mihomo", withExtension: nil) != nil }

    /// Read the bundled kernel version (mihomo -v) for display, off the main thread.
    func detectBuiltin() {
        guard let bundled = Bundle.main.url(forResource: "mihomo", withExtension: nil) else {
            DispatchQueue.main.async { self.builtinVersion = "" }; return
        }
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = bundled; p.arguments = ["-v"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return }
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let r = out.range(of: "v[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) {
                let v = String(out[r])
                DispatchQueue.main.async { self.builtinVersion = v }
            }
        }
    }

    /// Switch the active kernel to the bundled one (copy from app → bin) + restart.
    func activateBuiltin() async {
        let fm = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "mihomo", withExtension: nil) else {
            await MainActor.run { self.note = "内置内核缺失（打包未含 mihomo）" }; return
        }
        
        await EngineControl.shared.stopKernel()   // release bin/mihomo before overwrite
        
        let ok = await Task.detached(priority: .userInitiated) {
            do {
                if fm.fileExists(atPath: self.binPath) { try fm.removeItem(atPath: self.binPath) }
                try fm.copyItem(at: bundled, to: URL(fileURLWithPath: self.binPath))
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.binPath)
                return true
            } catch {
                return false
            }
        }.value

        if ok {
            activeTag = "内置"
            await MainActor.run { self.note = "已切换至内置内核，正在启动…" }
        } else {
            await MainActor.run { self.note = "切换失败：文件操作错误" }
        }
        await EngineControl.shared.launch()
    }

    /// Switch to a downloaded kernel: copy binary to unified bin path + restart.
    func activate(_ tag: String) async {
        if tag == "内置" { await activateBuiltin(); return }
        let slotName = tag == "正式版" ? "stable" : "alpha"
        let src = dir + "/\(slotName)/mihomo"
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { await MainActor.run { self.note = "内核文件缺失" }; return }

        await EngineControl.shared.stopKernel()   // release bin/mihomo before overwrite
        
        let ok = await Task.detached(priority: .userInitiated) {
            do {
                if fm.fileExists(atPath: self.binPath) { try fm.removeItem(atPath: self.binPath) }
                try fm.copyItem(atPath: src, toPath: self.binPath)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.binPath)
                return true
            } catch {
                return false
            }
        }.value

        if ok {
            activeTag = tag
            await MainActor.run { self.note = "已启用 \(tag) 内核，正在启动…" }
        } else {
            await MainActor.run { self.note = "启用失败：文件操作错误" }
        }
        await EngineControl.shared.launch()
    }

    func scanInstalled() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var tags: [String] = []
        if fm.fileExists(atPath: dir + "/stable/mihomo") {
            tags.append("正式版")
        }
        if fm.fileExists(atPath: dir + "/alpha/mihomo") {
            tags.append("Alpha")
        }
        installedTags = tags
    }

    func check() async {
        checking = true; note = ""; defer { checking = false }
        let api = channel == "alpha"
            ? "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
            : "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        guard let url = URL(string: api) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClashHalo", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req) else { note = "网络错误"; return }
        if let h = resp as? HTTPURLResponse, h.statusCode == 403 { note = "GitHub API 限流，请稍后再试"; return }
        
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable { 
            let tag_name: String
            let published_at: String
            let assets: [Asset]
        }
        guard let r = try? JSONDecoder().decode(Release.self, from: data) else { note = "解析失败"; return }
        latestTag = r.tag_name
        
        // Check if already latest version
        if channel == "stable" {
            let pureTag = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
            if installedStableTag == pureTag {
                note = "当前内核已是最新版本，无需更新"
                assetURL = ""
                return
            }
        } else if channel == "alpha" {
            if installedAlphaDate == r.published_at {
                note = "当前内核已是最新版本，无需更新"
                assetURL = ""
                return
            }
        }
        
        // darwin-arm64, prefer non-"compatible"/non-go120 variant, .gz
        if let a = r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") && !$0.name.contains("compatible") && !$0.name.contains("go1") })
            ?? r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") }) {
            assetURL = a.browser_download_url
            tempPublishDate = r.published_at
            tempTagName = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        } else { note = "未找到 darwin-arm64 资源" }
    }

    func download() async {
        guard let url = URL(string: assetURL), !latestTag.isEmpty else { return }
        downloading = true; progress = 0; note = ""; defer { downloading = false }
        guard let (tmp, _) = try? await session.download(from: url) else { note = "下载失败"; return }
        let fm = FileManager.default
        let slotName = channel == "alpha" ? "alpha" : "stable"
        let tagDir = dir + "/\(slotName)"
        try? fm.createDirectory(atPath: tagDir, withIntermediateDirectories: true)
        
        // decompress .gz → mihomo on background thread
        let out = tagDir + "/mihomo"
        try? fm.removeItem(atPath: out)
        
        let ok = await Task.detached(priority: .userInitiated) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            p.arguments = ["-c", tmp.path]
            guard FileManager.default.createFile(atPath: out, contents: nil),
                  let fh = FileHandle(forWritingAtPath: out) else { return false }
            p.standardOutput = fh
            do {
                try p.run()
                p.waitUntilExit()
                try? fh.close()
                return p.terminationStatus == 0
            } catch {
                return false
            }
        }.value

        if ok {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out)
            progress = 1
            if channel == "stable" {
                installedStableTag = tempTagName
            } else {
                installedAlphaDate = tempPublishDate
            }
            scanInstalled()
            let tag = channel == "alpha" ? "Alpha" : "正式版"
            note = "已成功下载并自动切换至 \(tag) 内核"
            await activate(tag)
        } else {
            note = "解压失败"
        }
    }
}
