import Foundation

/// Single source of truth for the privileged helper version.
/// Shared by both the Helper binary (compiled via make.sh) and the main app
/// (Xcode target) since both include this file — prevents the two-location
/// version drift that caused infinite upgrade loops.
public let kSharedHelperVersion = "1.0.20"

/// System-proxy bypass domains — single source of truth shared by the Helper
/// binary, the local shell fallback, and the GUI-side self-healing reconcile.
///
/// Includes localhost + loopback + mDNS + RFC1918 private ranges + link-local +
/// CGNAT, so LAN/intranet hosts and SD-WAN peers are never tunneled through the
/// proxy (which would fail or be rejected by the kernel, surfacing as HTTP 502
/// to LAN devices such as a NAS at 10.1.1.1). macOS bypass matching uses
/// shell-style wildcards per host/IP, so each private octet-prefix gets an
/// explicit entry. The CGNAT block (100.64.0.0/10) spans 64 octets (64..127).
public let kProxyBypassDomains: [String] = {
    var list = ["localhost", "127.0.0.1", "*.local", "10.*", "192.168.*", "169.254.*"]
    list += (16...31).map { "172.\($0).*" }
    list += (64...127).map { "100.\($0).*" }
    return list
}()

@objc(HelperProtocol)
public protocol HelperProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    func setSystemProxy(enabled: Bool, port: Int, withReply reply: @escaping (Bool) -> Void)
    func startMihomo(binPath: String, homeDir: String, withReply reply: @escaping (Bool) -> Void)
    func stopMihomo(withReply reply: @escaping (Bool) -> Void)
    func setGatewayMode(enabled: Bool, withReply reply: @escaping (Bool) -> Void)
    func setupExcludeRoutes(_ routes: [String: String], withReply reply: @escaping (Bool) -> Void)
    func cleanupAllExcludeRoutes(withReply reply: @escaping (Bool) -> Void)
    /// Physically neutralize lingering mihomo utun residue (down + delete IP +
    /// route flush) after a TUN teardown the kernel did not reclaim. Brought
    /// online as the privilege-side fallback for the GUI's zombie-utun probe.
    func cleanupTUNResidual(withReply reply: @escaping (Bool) -> Void)
}
