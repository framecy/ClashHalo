import Foundation

/// 生产适配器 `EngineControlDNSDriver` 的测试替身。
///
/// `TunnelDNSLedger.driver` 的默认值是 `EngineControlDNSDriver()`，真实实现位于
/// `Sources/XPC/EngineControl.swift` 末尾。回归套件单独编译 `TunnelDNSLedger.swift`
/// 时提供同名 stub 满足符号解析，测试主体再将 `TunnelDNSLedger.driver` 替换为
/// 可控的 `MockDNSDriver`。协议 `SystemDNSDriving` 一旦变更，此处立即编译失败。
struct EngineControlDNSDriver: SystemDNSDriving {
    func currentDNS(service: String?) async -> [String]? { nil }
    @discardableResult
    func applyDNS(_ servers: [String], service: String?) async -> Bool { false }
    func defaultService() async -> String? { nil }
}
