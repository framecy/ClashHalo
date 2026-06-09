import Foundation

/// Mihomo 官方支持的 17 种核心规则类型 (严格枚举)
public enum MihomoRuleType: String, CaseIterable, Codable, Equatable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case domainWildcard = "DOMAIN-WILDCARD"
    case domainRegex = "DOMAIN-REGEX"
    case geosite = "GEOSITE"
    case ipCidr = "IP-CIDR"
    case ipCidr6 = "IP-CIDR6"
    case ipSuffix = "IP-SUFFIX"
    case ipAsn = "IP-ASN"
    case geoip = "GEOIP"
    case srcGeoip = "SRC-GEOIP"
    case srcIpCidr = "SRC-IP-CIDR"
    case port = "PORT"
    case dstPort = "DST-PORT"
    case srcPort = "SRC-PORT"
    case inPort = "IN-PORT"
    case processPath = "PROCESS-PATH"
    case processName = "PROCESS-NAME"
    case processNameWildcard = "PROCESS-NAME-WILDCARD"
    case processNameRegex = "PROCESS-NAME-REGEX"
    case network = "NETWORK"
    case dscp = "DSCP"
    case ruleSet = "RULE-SET"
    case subRule = "SUB-RULE"
    case match = "MATCH"
}

/// 流量处理策略
public enum RuleAction: String, CaseIterable, Codable, Equatable {
    case direct = "DIRECT"
    case reject = "REJECT"
    case proxy = "PROXY"
}

/// 单条规则的原子数据结构
public struct RuleNode: Identifiable, Codable, Equatable {
    public let id: UUID
    public var type: MihomoRuleType
    public var match: String
    public var action: RuleAction
    public var sort: Int
    public var isEnabled: Bool
    public var proxyGroup: String?
    public var note: String?
    
    public init(id: UUID = UUID(), type: MihomoRuleType, match: String, action: RuleAction, sort: Int, isEnabled: Bool = true, proxyGroup: String? = nil, note: String? = nil) {
        self.id = id
        self.type = type
        self.match = match
        self.action = action
        self.sort = sort
        self.isEnabled = isEnabled
        self.proxyGroup = proxyGroup
        self.note = note
    }
}
