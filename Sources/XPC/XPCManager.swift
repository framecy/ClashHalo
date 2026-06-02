import Foundation
import ServiceManagement

public class XPCManager {
    public static let shared = XPCManager()
    
    private var connection: NSXPCConnection?
    
    private init() {}
    
    public func helper() -> HelperProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: "dev.clashpow.helper", options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            conn.interruptionHandler = { [weak self] in
                self?.connection = nil
            }
            conn.invalidationHandler = { [weak self] in
                self?.connection = nil
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler({ error in
            print("XPC Error: \(error)")
        }) as? HelperProtocol
    }
    
    public func installDaemon() async -> Bool {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: "dev.clashpow.helper.plist")
            do {
                if service.status == .enabled { return true }
                try service.register()
                return true
            } catch {
                print("SMAppService register failed: \(error)")
                return false
            }
        } else {
            return false
        }
    }
    
    public func uninstallDaemon() async -> Bool {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: "dev.clashpow.helper.plist")
            do {
                try await service.unregister()
                return true
            } catch {
                print("SMAppService unregister failed: \(error)")
                return false
            }
        } else {
            return false
        }
    }
}
