import SwiftUI

struct RuleFormView: View {
    @Environment(\.dismiss) var dismiss

    let existingNode: RuleNode?
    let proxyGroups: [String]
    /// 配置里真实可用的目标名（策略组 + 节点 + 内置策略 + config.yaml 里的组），
    /// 来自 `AppModel.ruleTargetNames`（打开弹窗时取一次快照，它会读盘）。
    /// 空集合 = 拿不到配置（内核未运行且配置文件读不到），此时跳过存在性校验。
    let knownTargets: Set<String>
    let contextConn: Conn?
    let onSave: (RuleNode) -> Void

    @State private var type: MihomoRuleType = .domain
    @State private var match: String = ""
    @State private var action: RuleAction = .proxy
    @State private var proxyGroup: String = ""
    @State private var note: String = ""

    @State private var errorMessage: String? = nil

    init(existingNode: RuleNode? = nil,
         proxyGroups: [String],
         knownTargets: Set<String> = [],
         contextConn: Conn? = nil,
         onSave: @escaping (RuleNode) -> Void) {
        self.existingNode = existingNode
        self.proxyGroups = proxyGroups
        self.knownTargets = knownTargets
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
        // 布局按 Docs/design.md：
        //   §5  间距 8pt 网格，表单行标签与控件之间 s(8)，组与组之间 l(16)
        //   §6.4 表单行：标签在上、控件整行宽（与订阅/端口转发弹窗同一套；settings 页
        //        才用「标签左 + fieldTrailing 右列」）
        //   §6.5 控件高度 32：DSMenuPicker / DSSegmentedControl / inputStyle() 全同源，
        //        按钮一律 dsButton(...)
        //   §6.6 不用原生 Form —— 它会带入自己的行距与行内边距，令牌无法覆盖
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text(existingNode == nil ? "添加规则" : "编辑规则")
                .font(.dsCardLabel)

            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                fieldBlock("规则类型") {
                    DSMenuPicker(selection: $type, choices: MihomoRuleType.allCases.map {
                        DSChoice($0.rawValue, $0)
                    })
                }

                if type != .match {
                    fieldBlock("匹配内容") {
                        TextField(matchPlaceholder, text: $match)
                            .inputStyle()
                            .font(.dsMono)
                    }
                }

                fieldBlock("动作") {
                    DSSegmentedControl(selection: $action, choices: [
                        DSChoice("代理", RuleAction.proxy),
                        DSChoice("直连", RuleAction.direct),
                        DSChoice("拦截", RuleAction.reject)
                    ])
                }

                if action == .proxy {
                    fieldBlock("目标代理组") {
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            DSMenuPicker(selection: $proxyGroup, choices: targetChoices)
                            // 目标已失效时的内联提示。选中项本身也会出现在下拉里（标「已失效」），
                            // 否则 `DSMenuPicker` 找不到匹配项只会显示「—」，用户看不出原值是什么。
                            if let stale = staleTarget {
                                Text("该目标在当前配置里已不存在，请重新选择")
                                    .font(.dsCaption)
                                    .foregroundColor(DS.Palette.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                fieldBlock(noteLabel) {
                    TextField("", text: $note)
                        .inputStyle()
                        .font(.dsMono)
                }
            }

            // 错误区固定占位：出现/消失不能让整张表跳动（§10.1 反馈要稳定）。
            Text(errorMessage ?? " ")
                .font(.dsBody)
                .foregroundColor(errorMessage == nil ? .clear : DS.Palette.error)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: DS.Spacing.m) {
                Button("取消") { dismiss() }
                    .dsButton()

                Spacer()

                Button("保存") { save() }
                    .dsButton(.prominent)
            }
        }
        .padding(DS.Spacing.xl)
        // 500 而不是 420：动作选「代理」时会多出「目标代理组」一行（约 66pt），
        // 420 会把底部按钮挤出去。固定高度 + 中间 Spacer，行数变化时按钮位置不动。
        .frame(width: 480, height: 500)
        // 兜底：SwiftUI 的 `@State` 初值只在视图身份首次出现时生效，若调用方用
        // `.sheet(isPresented:)` 复用身份，弹窗会沿用上一次的字段值（表现就是
        // 「编辑时没带入原匹配内容」）。这里在每次出现时把状态对齐到传入节点，
        // 只在值不同时写入，不会覆盖用户刚输入的内容。
        .onAppear(perform: syncFieldsFromExistingNode)
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

    /// 表单行：标签在上、控件占满整行宽（§6.4）。
    /// 标签用 `dsCaption` + `secondary`，与订阅/端口转发弹窗保持同一种层级。
    @ViewBuilder
    private func fieldBlock<Content: View>(_ label: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(label)
                .font(.dsCaption)
                .foregroundColor(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 备注字段的说明文案：`no-resolve` 只对 IP 类规则有意义，写清楚免得用户
    /// 给 DOMAIN 规则加一个无效参数。
    private var noteLabel: String {
        switch type {
        case .ipCidr, .ipCidr6, .ipSuffix, .geoip, .srcGeoip:
            return "备注（IP 类规则填 no-resolve 会作为规则参数，其余写成注释）"
        default:
            return "备注（可选，写成 YAML 注释）"
        }
    }

    /// 按规则类型给一个真实可用的示例值——空占位框比任何说明都省事。
    private var matchPlaceholder: String {
        switch type {
        case .domain:            return "如 api.example.com"
        case .domainSuffix:      return "如 example.com"
        case .domainKeyword:     return "如 example"
        case .domainWildcard:    return "如 *.example.com"
        case .domainRegex:       return "如 ^api\\.example\\.com$"
        case .ipCidr:            return "如 1.2.3.0/24"
        case .ipCidr6:           return "如 2001:db8::/32"
        case .srcIpCidr:         return "如 192.168.1.0/24"
        case .ipSuffix:          return "如 1.2.3.4"
        case .port, .dstPort:    return "如 443"
        case .srcPort, .inPort:  return "如 7890"
        case .processName, .processNameWildcard, .processNameRegex:
            return "如 WeChat"
        case .processPath:       return "如 /Applications/X.app/Contents/MacOS/X"
        case .network:           return "tcp 或 udp"
        case .geosite:           return "如 cn"
        case .geoip:             return "如 CN"
        case .srcGeoip:          return "如 CN"
        case .ipAsn:             return "如 13335"
        case .dscp:              return "如 46"
        case .ruleSet:           return "规则集名称"
        case .subRule:           return "子规则名称"
        case .match:             return ""
        }
    }

    /// 把表单字段对齐到 `existingNode`（幂等；只在值不同时写）。
    private func syncFieldsFromExistingNode() {
        guard let node = existingNode else { return }
        if type != node.type { type = node.type }
        if match != node.match { match = node.match }
        if action != node.action { action = node.action }
        let group = node.proxyGroup ?? ""
        if proxyGroup != group { proxyGroup = group }
        let noteText = node.note ?? ""
        if note != noteText { note = noteText }
    }

    /// 当前选中的目标是否已不在配置里（`nil` = 没失效，或拿不到配置而无从判断）。
    private var staleTarget: String? {
        guard action == .proxy,
              !knownTargets.isEmpty,
              !proxyGroup.isEmpty,
              !knownTargets.contains(proxyGroup) else { return nil }
        return proxyGroup
    }

    /// 下拉选项：正常就是现有策略组；目标失效时把原值也列进去并标「已失效」，
    /// 让用户看见「原来指向的是谁」而不是一个空白的「—」。
    private var targetChoices: [DSChoice<String>] {
        var choices = proxyGroups.map { DSChoice($0, $0) }
        if let stale = staleTarget, !proxyGroups.contains(stale) {
            choices.insert(DSChoice("\(stale)（已失效）", stale), at: 0)
        }
        return choices
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
        let res = ValidationService.shared.validate(node: node, knownTargets: knownTargets)
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

        let res = ValidationService.shared.validate(node: node, knownTargets: knownTargets)
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
