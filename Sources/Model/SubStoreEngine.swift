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
        guard let binURL = bundle.url(forResource: "sub-store-backend", withExtension: nil, subdirectory: "bin") else {
            print("Sub-Store binary not found")
            return
        }
        guard let frontEndURL = bundle.url(forResource: "sub-store", withExtension: nil, subdirectory: "Panels") else {
            print("Sub-Store frontend not found")
            return
        }
        
        let p = Process()
        p.executableURL = binURL
        
        var env = ProcessInfo.processInfo.environment
        env["SUB_STORE_DATA_BASE_PATH"] = dataDir
        env["SUB_STORE_FRONT_END_PATH"] = frontEndURL.path
        env["PORT"] = "\(port)"
        p.environment = env
        
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.isRunning = false }
        }
        
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
