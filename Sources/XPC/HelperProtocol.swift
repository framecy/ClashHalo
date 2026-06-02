import Foundation

@objc(HelperProtocol)
public protocol HelperProtocol {
    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void)
    func startEngine(homeDir: String, withReply reply: @escaping (Bool) -> Void)
    func stopEngine(withReply reply: @escaping () -> Void)
}
