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
    private var lastLoggedProgress = -1
    private var downloadContinuation: CheckedContinuation<URL?, Never>?

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

    /// Download the update package using custom delegate for dynamic progress reports
    func downloadUpdate() async -> URL? {
        guard let downloadURLString = downloadURL,
              let url = URL(string: downloadURLString) else {
            onLog?("下载失败：无效的下载链接")
            return nil
        }

        isDownloading = true
        downloadProgress = 0
        lastLoggedProgress = -1
        defer { isDownloading = false }

        onLog?("开始下载更新包...")

        return await withCheckedContinuation { cont in
            self.downloadContinuation = cont
            let delegate = DownloadDelegate(
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress
                        let pct = Int(progress * 100)
                        if pct % 10 == 0 && pct != self?.lastLoggedProgress {
                            self?.lastLoggedProgress = pct
                            self?.onLog?("下载进度：\(pct)%")
                        }
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor in
                        switch result {
                        case .success(let dest):
                            self?.downloadProgress = 1.0
                            self?.onLog?("下载完成：\(dest.path)")
                            cont.resume(returning: dest)
                        case .failure(let error):
                            self?.onLog?("下载失败：\(error.localizedDescription)")
                            cont.resume(returning: nil)
                        }
                        self?.downloadContinuation = nil
                    }
                }
            )

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 600

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue())
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()

            session.finishTasksAndInvalidate()
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
        downloadContinuation?.resume(returning: nil)
        downloadContinuation = nil
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

/// A private delegate helper that handles the downloading callbacks and updates progress dynamically
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var isCompleted = false

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()

        let tmpDir = FileManager.default.temporaryDirectory
        let fileName = downloadTask.originalRequest?.url?.lastPathComponent ?? "ClashHalo_Update.dmg"
        let destination = tmpDir.appendingPathComponent(fileName)

        try? FileManager.default.removeItem(at: destination)

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            onComplete(.success(destination))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()

        let err = error ?? NSError(domain: "AppUpdater", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载未完成"])
        onComplete(.failure(err))
    }
}
