import Foundation
import Network

/// 验证结果契约
public struct ValidationResult {
    public let isValid: Bool
    public let errorMsg: String?
    
    public static var valid: ValidationResult { ValidationResult(isValid: true, errorMsg: nil) }
    public static func invalid(_ msg: String) -> ValidationResult { ValidationResult(isValid: false, errorMsg: msg) }
}

/// 验证策略抽象接口
protocol RuleValidationStrategy {
    func validate(match: String) -> ValidationResult
}

// MARK: - 具体策略实现

struct DomainValidator: RuleValidationStrategy {
    func validate(match: String) -> ValidationResult {
        if match.isEmpty { return .invalid("域名不能为空") }
        if match.contains("*") || match.contains("?") {
            return .invalid("标准域名不支持通配符 (*, ?)")
        }
        let pattern = "^[a-zA-Z0-9\\-]+(\\.[a-zA-Z0-9\\-]+)*$"
        if match.range(of: pattern, options: .regularExpression) == nil {
            return .invalid("域名格式不合法")
        }
        return .valid
    }
}

struct DomainWildcardValidator: RuleValidationStrategy {
    func validate(match: String) -> ValidationResult {
        if match.isEmpty { return .invalid("通配符域名不能为空") }
        let pattern = "^[a-zA-Z0-9\\-\\.\\*\\?]+$"
        if match.range(of: pattern, options: .regularExpression) == nil {
            return .invalid("包含非法字符。仅允许字母、数字、连字符、点号和通配符")
        }
        return .valid
    }
}

struct RegexValidator: RuleValidationStrategy {
    func validate(match: String) -> ValidationResult {
        if match.isEmpty { return .invalid("正则表达式不能为空") }
        do {
            _ = try NSRegularExpression(pattern: match)
            return .valid
        } catch {
            return .invalid("无效的正则表达式: \\(error.localizedDescription)")
        }
    }
}

struct IPCidrValidator: RuleValidationStrategy {
    let isV6: Bool
    func validate(match: String) -> ValidationResult {
        let parts = match.split(separator: "/")
        guard parts.count == 2,
              let ipString = parts.first,
              let prefixStr = parts.last,
              let prefix = Int(prefixStr) else {
            return .invalid("必须是有效的 CIDR 格式，例如 192.168.1.0/24 或 ::1/128")
        }
        
        let ip = String(ipString)
        if isV6 {
            guard IPv6Address(ip) != nil else { return .invalid("无效的 IPv6 地址") }
            guard prefix >= 0 && prefix <= 128 else { return .invalid("IPv6 掩码范围应在 0-128 之间") }
        } else {
            guard IPv4Address(ip) != nil else { return .invalid("无效的 IPv4 地址") }
            guard prefix >= 0 && prefix <= 32 else { return .invalid("IPv4 掩码范围应在 0-32 之间") }
        }
        return .valid
    }
}

struct NetworkValidator: RuleValidationStrategy {
    func validate(match: String) -> ValidationResult {
        let val = match.uppercased().trimmingCharacters(in: .whitespaces)
        if val == "TCP" || val == "UDP" || val == "TCP,UDP" || val == "UDP,TCP" {
            return .valid
        }
        return .invalid("网络协议必须为 TCP、UDP 或 TCP,UDP")
    }
}

struct RuleSetValidator: RuleValidationStrategy {
    func validate(match: String) -> ValidationResult {
        if match.isEmpty { return .invalid("Rule-Set 标识不能为空") }
        var balance = 0
        for char in match {
            if char == "(" { balance += 1 }
            else if char == ")" {
                balance -= 1
                if balance < 0 { return .invalid("括号不匹配：多余的 ')'") }
            }
        }
        if balance > 0 { return .invalid("括号不匹配：缺少 ')'") }
        return .valid
    }
}

struct DefaultValidator: RuleValidationStrategy {
    func validate(match: String) -> ValidationResult {
        if match.trimmingCharacters(in: .whitespaces).isEmpty {
            return .invalid("匹配内容不能为空")
        }
        return .valid
    }
}

// MARK: - 服务引擎

public final class ValidationService {
    public static let shared = ValidationService()
    private init() {}
    
    private func strategy(for type: MihomoRuleType) -> RuleValidationStrategy {
        switch type {
        case .domain, .domainSuffix, .domainKeyword:
            return DomainValidator()
        case .domainWildcard:
            return DomainWildcardValidator()
        case .domainRegex, .processNameRegex:
            return RegexValidator()
        case .ipCidr, .srcIpCidr:
            return IPCidrValidator(isV6: false)
        case .ipCidr6:
            return IPCidrValidator(isV6: true)
        case .network:
            return NetworkValidator()
        case .ruleSet:
            return RuleSetValidator()
        case .match:
            return DefaultValidator()
        default:
            return DefaultValidator()
        }
    }
    
    public func validate(node: RuleNode) -> ValidationResult {
        if node.type == .match { return .valid } // MATCH 兜底规则无需 match 参数
        
        let strat = strategy(for: node.type)
        let res = strat.validate(match: node.match)
        if !res.isValid { return res }
        
        if node.action == .proxy {
            if (node.proxyGroup ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return .invalid("策略为 PROXY 时，必须关联目标代理组")
            }
        }
        return .valid
    }
}
