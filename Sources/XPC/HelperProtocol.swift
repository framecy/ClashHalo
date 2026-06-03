import Foundation

@objc(HelperProtocol)
public protocol HelperProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void)
    func startMihomo(binPath: String, homeDir: String, withReply reply: @escaping (Bool) -> Void)
    func stopMihomo(withReply reply: @escaping (Bool) -> Void)
}
