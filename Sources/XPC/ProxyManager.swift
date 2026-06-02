import Foundation
import SystemConfiguration

public class ProxyManager {
    public static func setSystemProxy(enabled: Bool, port: Int) -> Bool {
        let prefRef = SCPreferencesCreateWithAuthorization(kCFAllocatorDefault, "ClashPow" as CFString, nil, nil)!
        guard let currentSet = SCNetworkSetCopyCurrent(prefRef) else { return false }
        guard let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else { return false }
        
        var success = false
        for service in services {
            // Only apply to IPv4/IPv6 capable interfaces (exclude virtual or irrelevant ones)
            guard let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as? String else { continue }
            
            // Skip bridge/awdl/llw
            if bsdName.hasPrefix("bridge") || bsdName.hasPrefix("awdl") || bsdName.hasPrefix("llw") { continue }
            
            guard let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            
            let proxyDict = (SCNetworkProtocolGetConfiguration(proxyProtocol) as? [String: Any]) ?? [:]
            var newProxies = proxyDict
            
            if enabled {
                newProxies[kCFNetworkProxiesHTTPEnable as String] = 1
                newProxies[kCFNetworkProxiesHTTPProxy as String] = "127.0.0.1"
                newProxies[kCFNetworkProxiesHTTPPort as String] = port
                
                newProxies[kCFNetworkProxiesHTTPSEnable as String] = 1
                newProxies[kCFNetworkProxiesHTTPSProxy as String] = "127.0.0.1"
                newProxies[kCFNetworkProxiesHTTPSPort as String] = port
                
                newProxies[kCFNetworkProxiesSOCKSEnable as String] = 1
                newProxies[kCFNetworkProxiesSOCKSProxy as String] = "127.0.0.1"
                newProxies[kCFNetworkProxiesSOCKSPort as String] = port
                
                newProxies[kCFNetworkProxiesExcludeSimpleHostnames as String] = 1
            } else {
                newProxies[kCFNetworkProxiesHTTPEnable as String] = 0
                newProxies[kCFNetworkProxiesHTTPSEnable as String] = 0
                newProxies[kCFNetworkProxiesSOCKSEnable as String] = 0
            }
            
            if SCNetworkProtocolSetConfiguration(proxyProtocol, newProxies as CFDictionary) {
                success = true
            }
        }
        
        if success {
            SCPreferencesCommitChanges(prefRef)
            SCPreferencesApplyChanges(prefRef)
        }
        return success
    }
}
