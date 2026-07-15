import SwiftUI

struct RuleFormView: View {
    @Environment(\.dismiss) var dismiss
    
    let existingNode: RuleNode?
    let proxyGroups: [String]
    let contextConn: Conn?
    let onSave: (RuleNode) -> Void
    
    @State private var type: MihomoRuleType = .domain
    @State private var match: String = ""
    @State private var action: RuleAction = .proxy
    @State private var proxyGroup: String = ""
    @State private var note: String = ""
    
    @State private var errorMessage: String? = nil
    
    init(existingNode: RuleNode? = nil, proxyGroups: [String], contextConn: Conn? = nil, onSave: @escaping (RuleNode) -> Void) {
        self.existingNode = existingNode
        self.proxyGroups = proxyGroups
        self.contextConn = contextConn
        self.onSave = onSave
        
        if let node = existingNode {
            _type = State(initialValue: node.type)
            _match = State(initialValue: node.match)
            _action = State(initialValue: node.action)
            _proxyGroup = State(initialValue: node.proxyGroup ?? "")
            _note = State(initialValue: node.note ?? "")
        } else {
            if let first = proxyGroups.first {
                _proxyGroup = State(initialValue: first)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text(existingNode == nil ? "添加规则" : "编辑规则")
                .font(.dsSection)
                .padding(.top, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.m)

            Form {
                Picker("规则类型", selection: $type) {
                    ForEach(MihomoRuleType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .dsMenuControl()

                if type != .match {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("匹配内容").font(.dsBody).foregroundColor(.secondary)
                        TextField("", text: $match)
                            .inputStyle()
                    }
                }

                Picker("处理策略", selection: $action) {
                    Text("PROXY (代理)").tag(RuleAction.proxy)
                    Text("DIRECT (直连)").tag(RuleAction.direct)
                    Text("REJECT (拦截)").tag(RuleAction.reject)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)

                if action == .proxy {
                    Picker("目标代理组", selection: $proxyGroup) {
                        ForEach(proxyGroups, id: \.self) { g in
                            Text(g).tag(g)
                        }
                    }
                    .pickerStyle(.menu)
                    .dsMenuControl()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("备注 (可选, 例如 no-resolve)").font(.dsBody).foregroundColor(.secondary)
                    TextField("", text: $note)
                        .inputStyle()
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.m)

            if let err = errorMessage {
                Text(err)
                    .foregroundColor(DS.Palette.error)
                    .font(.dsBody)
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.xs)
            }

            HStack(spacing: DS.Spacing.m) {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.l)
        }
        .frame(width: 480, height: 420)
        .onChange(of: type) { _, newType in 
            if let c = contextConn {
                let newMatch: String
                switch newType {
                case .domain:
                    newMatch = c.host != c.dstIP ? c.host : c.dstIP
                case .domainSuffix:
                    newMatch = c.host != c.dstIP ? getDomainSuffix(c.host) : c.dstIP
                case .domainKeyword:
                    newMatch = c.host != c.dstIP ? getDomainKeyword(c.host) : c.dstIP
                case .domainWildcard:
                    newMatch = c.host != c.dstIP ? "*.\(getDomainSuffix(c.host))" : c.dstIP
                case .domainRegex:
                    newMatch = c.host != c.dstIP ? "^" + c.host.replacingOccurrences(of: ".", with: "\\.") + "$" : c.dstIP
                case .ipCidr, .ipCidr6, .srcIpCidr:
                    newMatch = newType == .srcIpCidr ? "\(c.srcIP)/32" : "\(c.dstIP)/32"
                case .ipSuffix:
                    newMatch = c.dstIP
                case .port, .dstPort:
                    newMatch = c.port
                case .srcPort, .inPort:
                    newMatch = ""
                case .processPath:
                    let rawPath = c.processPath != "—" && !c.processPath.isEmpty ? c.processPath : c.process
                    newMatch = rawPath != "—" ? rawPath : ""
                case .processName, .processNameWildcard, .processNameRegex:
                    let raw = c.process != "—" ? c.process : ""
                    newMatch = (raw as NSString).lastPathComponent
                case .network:
                    newMatch = c.network.uppercased()
                case .geosite, .ipAsn, .geoip, .srcGeoip, .dscp, .ruleSet, .subRule, .match:
                    newMatch = ""
                }
                
                self.match = newMatch
            }
            validateLive() 
        }
        .onChange(of: match) { _, _ in validateLive() }
        .onChange(of: action) { _, _ in validateLive() }
    }
    
    private func validateLive() {
        // live validation clears error if it's becoming valid
        let node = RuleNode(
            type: type,
            match: match,
            action: action,
            sort: 0,
            proxyGroup: action == .proxy ? proxyGroup : nil,
            note: note.isEmpty ? nil : note
        )
        let res = ValidationService.shared.validate(node: node)
        if res.isValid {
            errorMessage = nil
        }
    }
    
    private func save() {
        let node = RuleNode(
            id: existingNode?.id ?? UUID(),
            type: type,
            match: match,
            action: action,
            sort: existingNode?.sort ?? 0,
            proxyGroup: action == .proxy ? proxyGroup : nil,
            note: note.isEmpty ? nil : note
        )
        
        let res = ValidationService.shared.validate(node: node)
        if res.isValid {
            onSave(node)
            dismiss()
        } else {
            errorMessage = res.errorMsg ?? "校验失败"
        }
    }
    
    private func getDomainSuffix(_ host: String) -> String {
        let parts = host.components(separatedBy: ".")
        if parts.count <= 2 { return host }
        let tld = parts.last!
        if tld.count == 2 {
            let sld = parts[parts.count - 2]
            if ["com", "co", "net", "org", "gov", "edu"].contains(sld) && parts.count > 2 {
                return parts.suffix(3).joined(separator: ".")
            }
        }
        return parts.suffix(2).joined(separator: ".")
    }
    
    private func getDomainKeyword(_ host: String) -> String {
        let suffix = getDomainSuffix(host)
        return suffix.components(separatedBy: ".").first ?? suffix
    }
}
