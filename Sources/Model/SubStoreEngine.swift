import Foundation
import Combine

class SubStoreEngine: ObservableObject {
    static let shared = SubStoreEngine()
    
    private var process: Process?
    @Published var isRunning = false
    let port = 3001
    
    private let dataDir: String = {
        let p = NSHomeDirectory() + "/Library/Application Support/ClashPow/sub-store-data"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }()
    
    func start() {
        guard !isRunning else { return }
        
        let bundle = Bundle.main
        guard let binURL = bundle.url(forResource: "sub-store-backend", withExtension: nil) else {
            print("Sub-Store binary not found")
            return
        }
        guard let frontEndURL = bundle.url(forResource: "sub-store", withExtension: nil) else {
            print("Sub-Store frontend not found")
            return
        }
        
        let p = Process()
        p.executableURL = binURL
        
        var env = ProcessInfo.processInfo.environment
        env["SUB_STORE_DATA_BASE_PATH"] = dataDir
        env["SUB_STORE_FRONTEND_PATH"] = frontEndURL.path
        env["SUB_STORE_BACKEND_API_PORT"] = "3000"
        env["SUB_STORE_FRONTEND_BACKEND_PATH"] = "/"
        
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                print("[SubStore] \(str)", terminator: "")
                if let logData = ("[SubStore] " + str).data(using: .utf8) {
                    if let fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/sub-store.log")) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(logData)
                        fileHandle.closeFile()
                    } else {
                        try? logData.write(to: URL(fileURLWithPath: "/tmp/sub-store.log"))
                    }
                }
            }
        }
        
        p.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            print("[SubStore] Process terminated with status \(status)")
            DispatchQueue.main.async { self?.isRunning = false }
        }
        
        env["SUB_STORE_FRONTEND_PORT"] = "\(port)"
        p.environment = env
        
        do {
            try p.run()
            self.process = p
            self.isRunning = true
            print("Sub-Store Engine started on port \(port)")
        } catch {
            print("Failed to start Sub-Store: \(error)")
        }
    }
    
    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }
}
