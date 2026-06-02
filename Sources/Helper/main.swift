import Foundation


class Helper: NSObject, HelperProtocol {
    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void) {
        let ok = ProxyManager.setSystemProxy(enabled: enabled, port: port)
        reply(ok)
    }
    
    func startEngine(homeDir: String, withReply reply: @escaping (Bool) -> Void) {
        let cHomeDir = strdup(homeDir)
        defer { free(cHomeDir) }
        let ret = StartEngine(cHomeDir)
        reply(ret == 0)
    }
    
    func stopEngine(withReply reply: @escaping () -> Void) {
        StopEngine()
        reply()
    }
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = Helper()
        newConnection.resume()
        return true
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "dev.clashpow.helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
