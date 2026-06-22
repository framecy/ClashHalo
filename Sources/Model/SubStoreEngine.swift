import Foundation
import Combine

class SubStoreEngine: ObservableObject {
    static let shared = SubStoreEngine()

    private var process: Process?
    @Published var isRunning = false
    @Published var backendURL: String = "http://127.0.0.1:3000"
    let port = 3000

    private let dataDir: String = {
        let p = NSHomeDirectory() + "/Library/Application Support/ClashPow/sub-store-data"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }()

    private init() {}

    func start() {
        NSLog("[SubStore] start() called, isRunning: \(isRunning)")
        guard !isRunning else {
            NSLog("[SubStore] Already running, skipping")
            return
        }

        // 查找 Node.js
        guard let nodePath = findNode() else {
            NSLog("[SubStore] Node.js not found")
            return
        }

        // 查找 bundle.js
        guard let bundlePath = Bundle.main.path(forResource: "sub-store.bundle", ofType: "js", inDirectory: "SubStoreBackend") else {
            NSLog("[SubStore] sub-store.bundle.js not found")
            return
        }

        NSLog("[SubStore] Node: \(nodePath)")
        NSLog("[SubStore] Bundle: \(bundlePath)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: nodePath)
        p.arguments = [bundlePath]

        var env = ProcessInfo.processInfo.environment
        env["SUB_STORE_DATA_BASE_PATH"] = dataDir
        env["SUB_STORE_BACKEND_API_PORT"] = "\(port)"
        env["SUB_STORE_CORS_ALLOWED_ORIGINS"] = "*"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                NSLog("[SubStore] \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        p.terminationHandler = { process in
            NSLog("[SubStore] Process terminated with status \(process.terminationStatus)")
            DispatchQueue.main.async {
                self.isRunning = false
                self.process = nil
            }
        }

        do {
            try p.run()
            self.process = p

            // 等待后端启动
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRunning = true
                NSLog("[SubStore] Engine started on port \(self.port)")
            }
        } catch {
            NSLog("[SubStore] Failed to start: \(error)")
        }
    }

    func stop() {
        NSLog("[SubStore] stop() called")
        process?.terminate()
        isRunning = false
        process = nil
    }

    private func findNode() -> String? {
        let paths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
            NSHomeDirectory() + "/.nvm/versions/node/*/bin/node",
            NSHomeDirectory() + "/.local/share/fnm/node-versions/*/installation/bin/node"
        ]

        for path in paths {
            if path.contains("*") {
                // 使用通配符查找
                let dir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
                if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.lastPathComponent == "node" && FileManager.default.isExecutableFile(atPath: fileURL.path) {
                            return fileURL.path
                        }
                    }
                }
            } else if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 使用 which 命令查找
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["node"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()

        if let data = try? pipe.fileHandleForReading.readToEnd(),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }

        return nil
    }
}
