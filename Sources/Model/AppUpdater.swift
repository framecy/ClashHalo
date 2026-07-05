import Foundation
import AppKit

/// Manages application updates from GitHub Releases.
/// Checks for new versions, downloads updates, and handles installation.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var releaseNotes: String?
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false

    let repoOwner = "framecy"
    let repoName = "ClashHalo"
    private var downloadTask: URLSessionDownloadTask?

    var onLog: ((String) -> Void)?

    private init() {}

    /// Current app version from Info.plist
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check GitHub Releases for updates
    func checkForUpdates() async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }

        onLog?("检查更新：当前版本 \(currentVersion)")

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            onLog?("更新检查失败：无效的 URL")
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                onLog?("更新检查失败：服务器响应异常")
                return false
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                onLog?("更新检查失败：解析响应失败")
                return false
            }

            guard let tagName = json["tag_name"] as? String else {
                onLog?("更新检查失败：未找到版本标签")
                return false
            }

            // Remove 'v' prefix if present
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            latestVersion = version
            releaseNotes = json["body"] as? String

            // Compare versions
            if isNewerVersion(version, than: currentVersion) {
                onLog?("发现新版本：\(version)")

                // Find the .dmg or .zip asset
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String,
                           let downloadURLStr = asset["browser_download_url"] as? String,
                           (name.hasSuffix(".dmg") || name.hasSuffix(".zip")) {
                            downloadURL = downloadURLStr
                            updateAvailable = true
                            onLog?("找到更新包：\(name)")
                            return true
                        }
                    }
                }

                onLog?("未找到可下载的更新包")
                return false
            } else {
                onLog?("当前已是最新版本")
                updateAvailable = false
                return false
            }
        } catch {
            onLog?("更新检查失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Compare two semantic versions (e.g., "1.2.3" vs "1.2.4")
    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(newParts.count, currentParts.count) {
            let newVal = i < newParts.count ? newParts[i] : 0
            let currentVal = i < currentParts.count ? currentParts[i] : 0

            if newVal > currentVal { return true }
            if newVal < currentVal { return false }
        }

        return false
    }

    /// Download the update package
    func downloadUpdate() async -> URL? {
        guard let downloadURLString = downloadURL,
              let url = URL(string: downloadURLString) else {
            onLog?("下载失败：无效的下载链接")
            return nil
        }

        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        onLog?("开始下载更新包...")

        let tmpDir = FileManager.default.temporaryDirectory
        let fileName = url.lastPathComponent
        let destination = tmpDir.appendingPathComponent(fileName)

        // Remove existing file if any
        try? FileManager.default.removeItem(at: destination)

        do {
            // Use a simple synchronous download for now
            let (tempURL, response) = try await URLSession.shared.download(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                onLog?("下载失败：服务器响应异常")
                return nil
            }

            try FileManager.default.moveItem(at: tempURL, to: destination)
            downloadProgress = 1.0
            onLog?("下载完成：\(destination.path)")

            return destination
        } catch {
            onLog?("下载失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// Verify downloaded file integrity (basic size check)
    func verifyDownload(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            onLog?("文件验证失败：文件不存在")
            return false
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? UInt64, size > 1_000_000 { // At least 1MB
                onLog?("文件验证通过：大小 \(size / 1_000_000) MB")
                return true
            } else {
                onLog?("文件验证失败：文件过小")
                return false
            }
        } catch {
            onLog?("文件验证失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Open the downloaded file for user to install
    func installUpdate(from url: URL) {
        onLog?("打开更新包：\(url.path)")
        NSWorkspace.shared.open(url)
    }

    /// Full update flow: check → download → verify → prompt install
    func performUpdate() async -> Bool {
        guard await checkForUpdates() else {
            return false
        }

        guard updateAvailable else {
            return false
        }

        guard let downloadedURL = await downloadUpdate() else {
            return false
        }

        guard verifyDownload(at: downloadedURL) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            return false
        }

        // Install (open the dmg/zip)
        installUpdate(from: downloadedURL)

        return true
    }

    /// Cancel ongoing download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        onLog?("下载已取消")
    }

    /// Reset update state
    func reset() {
        updateAvailable = false
        latestVersion = nil
        downloadURL = nil
        releaseNotes = nil
        downloadProgress = 0
    }
}
