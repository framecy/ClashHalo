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

    /// URLSession for GitHub check/download.
    /// CRITICAL: do NOT use `.default` (inherits system HTTP proxy). When ClashHalo
    /// system proxy is ON, that would send GitHub traffic to 127.0.0.1:mixed-port
    /// through the same mihomo we may be about to replace — hangs, "网络错误", or
    /// multi‑minute stalls that look like the App froze. Force direct egress.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": "ClashHalo",
            "Accept": "application/vnd.github+json"
        ]
        // Empty proxy dictionary = ignore system proxy / PAC for this session.
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    /// Whether a kernel is bundled inside the app.
    var hasBuiltin: Bool {
        Bundle.main.url(forResource: "mihomo", withExtension: nil) != nil
            || FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/MacOS/mihomo")
    }

    private var bundledMihomoURL: URL? {
        if let u = Bundle.main.url(forResource: "mihomo", withExtension: nil) { return u }
        let macOS = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mihomo")
        return FileManager.default.fileExists(atPath: macOS.path) ? macOS : nil
    }

    /// Read the bundled kernel version (mihomo -v) for display, off the main thread.
    func detectBuiltin() {
        guard let bundled = bundledMihomoURL else {
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
    /// Returns true if the new kernel is reachable after the swap.
    @discardableResult
    func activateBuiltin() async -> Bool {
        let fm = FileManager.default
        guard let bundled = bundledMihomoURL else {
            await MainActor.run { self.note = "内置内核缺失（打包未含 mihomo）" }
            return false
        }

        await MainActor.run { self.note = "正在准备内置内核…" }

        // Stage the binary first so a failed copy never leaves us without a kernel.
        let staged = await Task.detached(priority: .userInitiated) { () -> String? in
            let tmp = NSTemporaryDirectory() + "mihomo.builtin.\(UUID().uuidString)"
            do {
                if fm.fileExists(atPath: tmp) { try fm.removeItem(atPath: tmp) }
                try fm.copyItem(at: bundled, to: URL(fileURLWithPath: tmp))
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
                return tmp
            } catch {
                return nil
            }
        }.value

        guard let staged else {
            await MainActor.run { self.note = "切换失败：无法复制内置内核" }
            return false
        }

        await MainActor.run { self.note = "正在切换至内置内核…" }
        let ok = await swapAndLaunch(stagedPath: staged, displayTag: "内置")
        if !ok {
            await MainActor.run { self.note = "内置内核切换失败，请重试" }
        }
        return ok
    }

    /// Switch to a downloaded kernel: copy binary to unified bin path + restart.
    /// Returns true if the new kernel is reachable after the swap.
    @discardableResult
    func activate(_ tag: String) async -> Bool {
        if tag == "内置" { return await activateBuiltin() }
        let slotName = tag == "正式版" ? "stable" : "alpha"
        let src = dir + "/\(slotName)/mihomo"
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else {
            await MainActor.run { self.note = "内核文件缺失" }
            return false
        }

        await MainActor.run { self.note = "正在准备 \(tag) 内核…" }

        let staged = await Task.detached(priority: .userInitiated) { () -> String? in
            let tmp = NSTemporaryDirectory() + "mihomo.\(slotName).\(UUID().uuidString)"
            do {
                if fm.fileExists(atPath: tmp) { try fm.removeItem(atPath: tmp) }
                try fm.copyItem(atPath: src, toPath: tmp)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
                return tmp
            } catch {
                return nil
            }
        }.value

        guard let staged else {
            await MainActor.run { self.note = "启用失败：无法复制内核文件" }
            return false
        }

        await MainActor.run { self.note = "正在切换至 \(tag) 内核…" }
        let ok = await swapAndLaunch(stagedPath: staged, displayTag: tag)
        if !ok {
            await MainActor.run { self.note = "启用 \(tag) 失败，请重试" }
        }
        return ok
    }

    /// Atomic-ish kernel swap:
    /// 1. Stage already prepared at `stagedPath` (download/copy done BEFORE stop)
    /// 2. Temporarily clear system proxy so a dead 127.0.0.1 proxy can't black-hole the Mac
    /// 3. Stop kernel (bounded XPC + killall)
    /// 4. Replace bin/mihomo
    /// 5. Launch + wait for readiness
    /// 6. Restore system proxy if it was on
    ///
    /// This ordering is the fix for "更新内核版本时卡住 / 全局断网": the old path
    /// stopped the kernel first, then did long work, while system proxy still
    /// pointed at 127.0.0.1:7890.
    private func swapAndLaunch(stagedPath: String, displayTag: String) async -> Bool {
        let fm = FileManager.default
        let port = await MainActor.run { AppModel.shared.proxyPort }
        let wasProxyOn = await MainActor.run { AppModel.shared.systemProxyOn }

        // Drop system proxy BEFORE killing the kernel so traffic can fall back
        // to direct while the swap is in flight.
        if wasProxyOn {
            await MainActor.run { AppModel.shared.logKernel("内核切换：临时关闭系统代理以防断网") }
            _ = await EngineControl.shared.setSystemProxy(enabled: false, port: port)
            await MainActor.run { AppModel.shared.systemProxyOn = false }
        }

        await EngineControl.shared.stopKernel()

        let installed = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                if fm.fileExists(atPath: self.binPath) {
                    try fm.removeItem(atPath: self.binPath)
                }
                // Ensure bin dir exists
                try fm.createDirectory(
                    atPath: (self.binPath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try fm.moveItem(atPath: stagedPath, toPath: self.binPath)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.binPath)
                return true
            } catch {
                // Clean staged temp on failure
                try? fm.removeItem(atPath: stagedPath)
                return false
            }
        }.value

        guard installed else {
            // Best-effort relaunch of whatever is still in bin/ (may be missing).
            await EngineControl.shared.launch()
            if wasProxyOn {
                _ = await EngineControl.shared.setSystemProxy(enabled: true, port: port)
                await MainActor.run { AppModel.shared.systemProxyOn = true }
            }
            return false
        }

        await MainActor.run {
            self.activeTag = displayTag
            self.note = "已切换至 \(displayTag)，正在启动…"
        }

        await EngineControl.shared.launch()

        // Wait for the new kernel instead of a fixed multi-second sleep.
        let ready = await AppModel.shared.waitForKernelReady(maxAttempts: 10)
        if ready {
            await MainActor.run {
                self.note = "已启用 \(displayTag) 内核"
                AppModel.shared.logKernel("内核已切换至 \(displayTag)")
            }
        } else {
            await MainActor.run {
                self.note = "\(displayTag) 已安装但启动超时"
                AppModel.shared.logKernel("内核切换后启动超时（\(displayTag)）")
            }
        }

        // Restore system proxy only if the kernel is actually listening again.
        if wasProxyOn {
            if ready {
                _ = await EngineControl.shared.setSystemProxy(enabled: true, port: port)
                await MainActor.run {
                    AppModel.shared.systemProxyOn = true
                    AppModel.shared.logKernel("内核切换：已恢复系统代理")
                }
            } else {
                await MainActor.run {
                    AppModel.shared.showToast("内核启动超时，系统代理未恢复（避免断网）", kind: .warn)
                }
            }
        }

        return ready
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
        await MainActor.run {
            checking = true
            note = "正在检查更新…"
        }
        defer { Task { @MainActor in self.checking = false } }

        let api = channel == "alpha"
            ? "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
            : "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        guard let url = URL(string: api) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            await MainActor.run {
                self.note = "检查失败：\(Self.shortError(error))（已直连，不经系统代理）"
            }
            return
        }
        if let h = resp as? HTTPURLResponse {
            if h.statusCode == 403 {
                await MainActor.run { self.note = "GitHub API 限流，请稍后再试" }
                return
            }
            if h.statusCode != 200 {
                await MainActor.run { self.note = "检查失败：HTTP \(h.statusCode)" }
                return
            }
        }

        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable {
            let tag_name: String
            let published_at: String
            let assets: [Asset]
        }
        guard let r = try? JSONDecoder().decode(Release.self, from: data) else {
            await MainActor.run { self.note = "解析失败" }
            return
        }

        await MainActor.run { self.latestTag = r.tag_name }

        // Check if already latest version
        if channel == "stable" {
            let pureTag = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
            if installedStableTag == pureTag {
                await MainActor.run {
                    self.note = "当前内核已是最新版本，无需更新"
                    self.assetURL = ""
                }
                return
            }
        } else if channel == "alpha" {
            if installedAlphaDate == r.published_at {
                await MainActor.run {
                    self.note = "当前内核已是最新版本，无需更新"
                    self.assetURL = ""
                }
                return
            }
        }

        // darwin-arm64, prefer non-"compatible"/non-go120 variant, .gz
        if let a = r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") && !$0.name.contains("compatible") && !$0.name.contains("go1") })
            ?? r.assets.first(where: { $0.name.contains("darwin-arm64") && $0.name.hasSuffix(".gz") }) {
            await MainActor.run {
                self.assetURL = a.browser_download_url
                self.tempPublishDate = r.published_at
                self.tempTagName = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
                self.note = "发现新版本 \(r.tag_name)，可下载切换"
            }
        } else {
            await MainActor.run { self.note = "未找到 darwin-arm64 资源" }
        }
    }

    /// Download + decompress into the channel slot, THEN swap the running kernel.
    /// Download happens while the current kernel is still serving traffic — the
    /// stop/swap window is only the final install step.
    ///
    /// Returns whether the new kernel is reachable after the full flow.
    @discardableResult
    func download() async -> Bool {
        guard let url = URL(string: assetURL), !latestTag.isEmpty else {
            await MainActor.run { self.note = "请先检查更新" }
            return false
        }
        await MainActor.run {
            self.downloading = true
            self.progress = 0.05
            self.note = "正在下载 \(self.latestTag)…（直连，不经系统代理）"
        }
        defer { Task { @MainActor in self.downloading = false } }

        let tmp: URL
        do {
            let (file, resp) = try await session.download(from: url)
            if let h = resp as? HTTPURLResponse, !(200...399).contains(h.statusCode) {
                await MainActor.run {
                    self.note = "下载失败：HTTP \(h.statusCode)"
                    self.progress = 0
                }
                try? FileManager.default.removeItem(at: file)
                return false
            }
            tmp = file
        } catch {
            await MainActor.run {
                self.note = "下载失败：\(Self.shortError(error))"
                self.progress = 0
            }
            return false
        }

        await MainActor.run {
            self.progress = 0.7
            self.note = "正在解压…"
        }

        let fm = FileManager.default
        let slotName = channel == "alpha" ? "alpha" : "stable"
        let tagDir = dir + "/\(slotName)"
        try? fm.createDirectory(atPath: tagDir, withIntermediateDirectories: true)

        // decompress .gz → mihomo on background thread (current kernel still running)
        let out = tagDir + "/mihomo"
        try? fm.removeItem(atPath: out)
        let tmpPath = tmp.path

        let ok = await Task.detached(priority: .userInitiated) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            p.arguments = ["-c", tmpPath]
            guard FileManager.default.createFile(atPath: out, contents: nil),
                  let fh = FileHandle(forWritingAtPath: out) else { return false }
            p.standardOutput = fh
            do {
                try p.run()
                p.waitUntilExit()
                try? fh.close()
                // Reject empty/corrupt outputs (e.g. HTML error page gunzipped badly).
                let attrs = try? FileManager.default.attributesOfItem(atPath: out)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                return p.terminationStatus == 0 && size > 1_000_000
            } catch {
                return false
            }
        }.value

        // Clean URLSession temp regardless
        try? fm.removeItem(at: tmp)

        guard ok else {
            await MainActor.run {
                self.note = "解压失败（文件不完整或非 gzip）"
                self.progress = 0
            }
            return false
        }

        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out)
        await MainActor.run {
            self.progress = 0.9
            if self.channel == "stable" {
                self.installedStableTag = self.tempTagName
            } else {
                self.installedAlphaDate = self.tempPublishDate
            }
            self.scanInstalled()
        }
        let tag = channel == "alpha" ? "Alpha" : "正式版"
        await MainActor.run { self.note = "下载完成，正在切换至 \(tag)…" }

        // Only NOW stop the running kernel and swap — short outage window.
        let switched = await activate(tag)
        await MainActor.run {
            self.progress = 1
            if !switched {
                self.note = "已下载 \(tag)，但切换/启动失败（系统代理已保护）"
            }
        }
        return switched
    }

    /// Compact, user-facing error text (no huge URLSession dump).
    private static func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "连接超时"
            case NSURLErrorNotConnectedToInternet: return "无网络"
            case NSURLErrorNetworkConnectionLost: return "连接中断"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "无法解析主机"
            case NSURLErrorCannotConnectToHost: return "无法连接主机"
            case NSURLErrorSecureConnectionFailed: return "TLS 失败"
            default: break
            }
        }
        let s = error.localizedDescription
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
