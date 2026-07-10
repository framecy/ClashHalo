import Foundation

/// Single source of truth for the privileged helper version.
/// Shared by both the Helper binary (compiled via make.sh) and the main app
/// (Xcode target) since both include this file — prevents the two-location
/// version drift that caused infinite upgrade loops.
public let kSharedHelperVersion = "1.0.13"

@objc(HelperProtocol)
public protocol HelperProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void)
    func startMihomo(binPath: String, homeDir: String, withReply reply: @escaping (Bool) -> Void)
    func stopMihomo(withReply reply: @escaping (Bool) -> Void)
    func setGatewayMode(enabled: Bool, withReply reply: @escaping (Bool) -> Void)
    func setupExcludeRoutes(_ routes: [String: String], withReply reply: @escaping (Bool) -> Void)
    func cleanupAllExcludeRoutes(withReply reply: @escaping (Bool) -> Void)
}
