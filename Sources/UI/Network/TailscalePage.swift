import SwiftUI
import AppKit

// Built-in tailnet node.
//
// The page is deliberately plain: this is a capability switch plus a small
// form, not a dashboard. What it *must* do well is tell the truth about the
// three things the kernel keeps quiet about — an unsupported kernel build, a
// system Tailscale client that already owns 100.64/10, and an exit node that
// failed to apply.

struct TailscalePage: View {
    @EnvironmentObject var M: AppModel

    @State private var authKeyDraft = ""
    @State private var showAuthKeyField = false
    @State private var apiTokenDraft = ""
    @State private var showAPITokenField = false
    @State private var extraCIDRDraft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.l) {
                switchCard
                if M.tsEnabled {
                    if !M.tsWarnings.isEmpty { warningCard }
                    identityCard
                    routingCard
                    devicesCard
                }
                explainer
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.xl)
        }
        .onAppear {
            M.probeTailscaleSupport()
            if M.tsEnabled {
                M.refreshTailscaleEnvironmentWarnings()
                M.refreshTailscaleDevices()
            }
        }
    }

    // MARK: Switch

    private var switchCard: some View {
        Card(title: "内置 Tailnet 节点", icon: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 2) {
                HStack {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("加入 Tailnet").font(.dsBody)
                        Text(stateText).font(.dsCaption).foregroundColor(stateColor)
                    }
                    Spacer()
                    if M.engine.isBusy {
                        ProgressView().controlSize(.mini).scaleEffect(DS.Progress.miniScale)
                    }
                    Toggle("", isOn: Binding(get: { M.tsEnabled },
                                             set: { M.setTailscaleEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(M.engine.isBusy || M.tsSupported == false)
                        .opacity(M.engine.isBusy ? 0.55 : 1)
                }
                .padding(.vertical, DS.Spacing.s)

                if M.tsSupported == false {
                    Text("当前内核不含 Tailscale 出站。需要 mihomo v1.19.25 及以上、且构建带 with_gvisor。")
                        .font(.dsCaption).foregroundColor(DS.Palette.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, DS.Spacing.s)
                }
            }
        }
    }

    private var stateText: String {
        if M.tsSupported == false { return "内核不支持" }
        switch M.tsState {
        case .disabled: return "未启用——流量不经过 tailnet"
        case .idle: return M.hasTailscaleAuthKey
            ? "已就绪（首次连接时才会真正启动会话）"
            : "已注入，等待登录"
        case .starting: return "正在启动会话并等待登录地址…"
        case .needsLogin(let url): return "等待浏览器授权：\(url)"
        case .running: return "会话已连通"
        case .failed(let reason): return "失败：\(reason)"
        }
    }

    private var stateColor: Color {
        if M.tsSupported == false { return DS.Palette.error }
        switch M.tsState {
        case .running: return DS.Palette.ok
        case .failed: return DS.Palette.error
        case .needsLogin, .starting: return DS.Palette.warn
        default: return .secondary
        }
    }

    // MARK: Warnings

    private var warningCard: some View {
        Card(title: "需要注意", icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ForEach(M.tsWarnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: DS.Spacing.s) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.dsBody).foregroundColor(DS.Palette.warn)
                        Text(w).font(.dsCaption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Spacing.s)
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        Card(title: "身份与登录", icon: "person.badge.key") {
            VStack(spacing: 2) {
                // Raw binding on purpose: sanitizing per keystroke makes names
                // like "my-net" untypeable (the trailing dash is stripped the
                // moment it is typed). Repair happens once, on apply.
                tsTextRow("节点名称", value: Binding(
                    get: { M.tsSettings.nodeName },
                    set: { M.tsSettings.nodeName = $0 }
                ), placeholder: "Tailnet",
                   help: "同时作为分流规则的目标与 MagicDNS 解析目标，改名会重写这三处")

                tsTextRow("设备名 hostname", value: Binding(
                    get: { M.tsSettings.hostname },
                    set: { M.tsSettings.hostname = $0 }
                ), placeholder: "clashhalo-mac",
                   help: "显示在 Tailscale 管理后台；会被规范化为小写")

                tsTextRow("控制服务器", value: Binding(
                    get: { M.tsSettings.controlURL },
                    set: { M.tsSettings.controlURL = $0 }
                ), placeholder: "留空即官方控制面（Headscale 填自建地址）")

                Divider().padding(.vertical, DS.Spacing.s)

                // Two mutually exclusive login methods, same as Surge.
                HStack {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("登录方式").font(.dsBody)
                        Text(M.hasTailscaleAuthKey
                             ? "Auth Key：\(maskTailscaleKey(M.tailscaleAuthKey))"
                             : "浏览器登录（无 auth-key）")
                            .font(.dsCaption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if M.hasTailscaleAuthKey {
                        Button("清除 Key") {
                            M.setTailscaleAuthKey("")
                            authKeyDraft = ""
                        }.dsButton()
                    } else {
                        Button("浏览器登录") { M.startTailscaleLogin() }
                            .dsButton(.prominent)
                            .disabled(M.engine.isBusy)
                        Button(showAuthKeyField ? "取消" : "用 Auth Key") {
                            showAuthKeyField.toggle()
                        }.dsButton()
                    }
                }
                .padding(.vertical, DS.Spacing.s)

                if showAuthKeyField && !M.hasTailscaleAuthKey {
                    HStack(spacing: DS.Spacing.s) {
                        SecureField("tskey-auth-…", text: $authKeyDraft)
                            .inputStyle().font(.dsMono)
                        Button("保存") {
                            M.setTailscaleAuthKey(authKeyDraft)
                            authKeyDraft = ""
                            showAuthKeyField = false
                            M.applyTailscaleSettings()
                        }
                        .dsButton(.prominent)
                        .disabled(authKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.bottom, DS.Spacing.s)
                    Text("Key 存入钥匙串，只在生成配置时写入 config.yaml。建议使用短期、可预授权的 key。")
                        .font(.dsCaption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, DS.Spacing.s)
                }

                if case .needsLogin(let url) = M.tsState {
                    HStack {
                        Text(url).font(.dsMono).foregroundColor(DS.Palette.info)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }.dsButton()
                    }.padding(.vertical, DS.Spacing.s)
                }

                Divider().padding(.vertical, DS.Spacing.s)

                HStack {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("本机身份").font(.dsBody)
                        Text("清除后下次启用会重新注册为新节点，旧节点需要在后台自行移除")
                            .font(.dsCaption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("测试连通") { M.kickTailscale() }.dsButton()
                    Button("清除身份") { M.resetTailscaleIdentity() }.dsButton()
                }.padding(.vertical, DS.Spacing.s)
            }
        }
    }

    // MARK: Routing

    private var routingCard: some View {
        Card(title: "路由与出口", icon: "arrow.triangle.branch") {
            VStack(spacing: 2) {
                tsToggleRow("自动生成分流规则",
                            help: "把 MagicDNS 后缀与选中的 IP 规则指向本节点，插在规则表最前",
                            value: Binding(get: { M.tsSettings.autoRules },
                                           set: { M.tsSettings.autoRules = $0 }))

                tsTextRow("MagicDNS 后缀", value: Binding(
                    get: { M.tsSettings.magicDNSSuffix },
                    set: { M.tsSettings.magicDNSSuffix = $0 }
                ), placeholder: "留空按 ts.net 通配",
                   help: "官方 tailnet 填 tailXXXX.ts.net；Headscale 自定义域同样适用")

                tsToggleRow("包含 100.64.0.0/10",
                            help: "官方 tailnet 的 CGNAT 聚合。Headscale 若没用这段可关掉，只留 peer /32 与手工子网",
                            value: Binding(get: { M.tsSettings.includeCGNATRule },
                                           set: { M.tsSettings.includeCGNATRule = $0 }))

                tsToggleRow("按设备生成 /32 规则",
                            help: "把在线设备的 IPv4 写成精确规则（需 API Token）。大 tailnet 会封顶 \(TailscaleSettings.maxPeerRules) 条",
                            value: Binding(get: { M.tsAutoPeerRules },
                                           set: { M.tsAutoPeerRules = $0 }))

                extraCIDREditor

                tsToggleRow("接受子网路由",
                            help: "内核侧 accept-routes：接受 tailnet 发布的路由。流量是否进来仍由上方规则决定",
                            value: Binding(get: { M.tsSettings.acceptRoutes },
                                           set: { M.tsSettings.acceptRoutes = $0 }))

                tsToggleRow("启用 UDP",
                            help: "内核默认关闭；关掉后 tailnet 内的 UDP 全部不通",
                            value: Binding(get: { M.tsSettings.udp },
                                           set: { M.tsSettings.udp = $0 }))

                tsTextRow("出口节点", value: Binding(
                    get: { M.tsSettings.exitNode },
                    set: { M.tsSettings.exitNode = $0 }
                ), placeholder: "留空不使用；可填节点 IP 或 auto:any",
                   help: "不配置出口节点时，只有 tailnet 内目标可达，且失败不会回退直连。也可在下方设备列表点选。")

                if !M.tsSettings.exitNode.isEmpty {
                    tsToggleRow("出口节点允许访问局域网",
                                help: "exit-node-allow-lan-access。网关模式下建议开启，否则 LAN 客户端经出口出网后回不了内网",
                                value: Binding(get: { M.tsSettings.exitNodeAllowLANAccess },
                                               set: { M.tsSettings.exitNodeAllowLANAccess = $0 }))
                }

                if !M.tsDevices.isEmpty {
                    exitNodePicker
                }

                if M.tsPeerRulesStale {
                    Text("在线设备已变化，peer /32 规则尚未写入内核——点「应用配置」同步")
                        .font(.dsCaption).foregroundColor(DS.Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.s)
                }

                HStack {
                    Spacer()
                    Button("应用配置") { M.applyTailscaleSettings() }
                        .dsButton(.prominent)
                        .disabled(M.engine.isBusy)
                }.padding(.top, DS.Spacing.s)
            }
        }
    }

    /// Free-form subnet list. One CIDR per entry; bare IPs become /32.
    private var extraCIDREditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("额外子网路由").font(.dsBody)
            Text("accept-routes 只让内核收下路由；这里的 CIDR 才会真正把流量交给本节点。不要填 0.0.0.0/0。")
                .font(.dsCaption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !M.tsSettings.extraCIDRs.isEmpty {
                VStack(spacing: 2) {
                    ForEach(M.tsSettings.extraCIDRs, id: \.self) { cidr in
                        HStack {
                            Text(cidr).font(.dsMono)
                            Spacer()
                            Button {
                                M.tsSettings.extraCIDRs.removeAll { $0 == cidr }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, DS.Spacing.xs)
                    }
                }
            }

            let suggested = TailscaleAPI.suggestedSubnetRoutes(from: M.tsDevices)
                .filter { !M.tsSettings.extraCIDRs.contains($0) }
            if !suggested.isEmpty {
                HStack {
                    Text("设备通告了 \(suggested.count) 条尚未导入的子网")
                        .font(.dsCaption).foregroundColor(.secondary)
                    Spacer()
                    Button("导入通告子网") { _ = M.importAdvertisedSubnetRoutes() }
                        .dsButton()
                }
            }

            HStack(spacing: DS.Spacing.s) {
                TextField("10.20.0.0/16", text: $extraCIDRDraft)
                    .inputStyle().font(.dsMono)
                Button("添加") {
                    let added = TailscaleOverlay.normalizeCIDRs([extraCIDRDraft])
                    guard let cidr = added.first else {
                        M.showToast("不是有效的 IPv4 CIDR", kind: .warn)
                        return
                    }
                    if cidr == "0.0.0.0/0" || cidr == "::/0" {
                        M.showToast("默认路由请用出口节点，不要写成子网规则", kind: .warn)
                        return
                    }
                    if !M.tsSettings.extraCIDRs.contains(cidr) {
                        M.tsSettings.extraCIDRs.append(cidr)
                    }
                    extraCIDRDraft = ""
                }
                .dsButton()
                .disabled(extraCIDRDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, DS.Spacing.s)
    }

    /// Compact picker over the already-fetched device list. Selecting only
    /// fills the text field; the user still has to hit 应用配置.
    private var exitNodePicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("从设备列表选择出口").font(.dsCaption).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.s) {
                    exitChip(title: "不使用", selected: M.tsSettings.exitNode.isEmpty) {
                        M.selectTailscaleExitNode(nil)
                    }
                    exitChip(title: "auto:any", selected: M.tsSettings.exitNode == "auto:any") {
                        M.tsSettings.exitNode = "auto:any"
                    }
                    ForEach(M.tsDevices.filter(\.online)) { d in
                        let label = d.ips.first ?? d.hostname
                        let selected = M.tsSettings.exitNode == label
                            || M.tsSettings.exitNode == d.hostname
                            || d.ips.contains(M.tsSettings.exitNode)
                        exitChip(title: d.hostname, selected: selected) {
                            M.selectTailscaleExitNode(d)
                        }
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.s)
    }

    private func exitChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(selected ? .dsBodySemibold : .dsBody)
                .foregroundColor(selected ? DS.Palette.accent : .primary)
                .padding(.horizontal, DS.Spacing.s)
                .padding(.vertical, DS.Spacing.xs)
                .background(
                    Capsule().fill(selected ? DS.Palette.accent.opacity(0.12) : DS.Palette.hairline)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Devices

    private var devicesCard: some View {
        Card(title: "Tailnet 设备", icon: "laptopcomputer.and.iphone") {
            VStack(spacing: 2) {
                HStack {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("API Token").font(.dsBody)
                        Text(M.hasTailscaleAPIToken
                             ? "已配置：\(maskTailscaleKey(M.tailscaleAPIToken))"
                             : "可选。填入后可列出 tailnet 设备并点选出口节点")
                            .font(.dsCaption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if M.tsDevicesLoading {
                        ProgressView().controlSize(.mini).scaleEffect(DS.Progress.miniScale)
                    }
                    if M.hasTailscaleAPIToken {
                        Button("刷新") { M.refreshTailscaleDevices(force: true) }.dsButton()
                        Button("清除") {
                            M.setTailscaleAPIToken("")
                            apiTokenDraft = ""
                        }.dsButton()
                    } else {
                        Button(showAPITokenField ? "取消" : "配置 Token") {
                            showAPITokenField.toggle()
                        }.dsButton()
                    }
                }
                .padding(.vertical, DS.Spacing.s)

                if showAPITokenField && !M.hasTailscaleAPIToken {
                    HStack(spacing: DS.Spacing.s) {
                        SecureField("tskey-api-…", text: $apiTokenDraft)
                            .inputStyle().font(.dsMono)
                        Button("保存") {
                            M.setTailscaleAPIToken(apiTokenDraft)
                            apiTokenDraft = ""
                            showAPITokenField = false
                            M.refreshTailscaleDevices(force: true)
                        }
                        .dsButton(.prominent)
                        .disabled(apiTokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.bottom, DS.Spacing.s)
                    Text("在 Tailscale 管理后台 → Settings → Keys 生成 API access token（devices 读取权限）。与 auth-key 不同，不会写入 config.yaml。")
                        .font(.dsCaption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, DS.Spacing.s)
                }

                if let err = M.tsDevicesError {
                    Text(err).font(.dsCaption).foregroundColor(DS.Palette.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, DS.Spacing.s)
                }

                if M.tsDevices.isEmpty && M.hasTailscaleAPIToken && !M.tsDevicesLoading && M.tsDevicesError == nil {
                    Text("暂无设备").font(.dsCaption).foregroundColor(.secondary)
                        .padding(.vertical, DS.Spacing.s)
                }

                ForEach(M.tsDevices) { d in
                    deviceRow(d)
                }
            }
        }
    }

    private func deviceRow(_ d: TailscaleDevice) -> some View {
        let isExit = !M.tsSettings.exitNode.isEmpty
            && (M.tsSettings.exitNode == d.hostname
                || d.ips.contains(M.tsSettings.exitNode)
                || M.tsSettings.exitNode == d.ips.first)
        return HStack(spacing: DS.Spacing.s) {
            Circle()
                .fill(d.online ? DS.Palette.ok : DS.Palette.hairline)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    Text(d.hostname).font(.dsBodySemibold).lineLimit(1)
                    if d.ephemeral {
                        Text("临时").font(.dsCaption).foregroundColor(.secondary)
                            .padding(.horizontal, DS.Spacing.xs)
                            .background(Capsule().fill(DS.Palette.hairline))
                    }
                    if isExit {
                        Text("出口").font(.dsCaption).foregroundColor(DS.Palette.accent)
                            .padding(.horizontal, DS.Spacing.xs)
                            .background(Capsule().fill(DS.Palette.accent.opacity(0.12)))
                    }
                }
                HStack(spacing: DS.Spacing.s) {
                    if !d.os.isEmpty {
                        Text(d.os).font(.dsCaption).foregroundColor(.secondary)
                    }
                    if let ip = d.ips.first {
                        Text(ip).font(.dsMono).foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if d.online {
                Button(isExit ? "取消出口" : "设为出口") {
                    M.selectTailscaleExitNode(isExit ? nil : d)
                }
                .dsButton(isExit ? .secondary : .prominent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, DS.Spacing.s)
    }

    // MARK: Explainer

    private var explainer: some View {
        Card(title: "工作方式", icon: "info.circle") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                bullet("内核以用户态节点身份加入 tailnet，不需要安装 Tailscale 客户端，也不占用系统 VPN 插槽。")
                bullet("只有被规则选中的流量才走 tailnet；本机不会被宣告为子网路由器或出口节点。")
                bullet("裸 TCP（如 ssh 100.x.y.z）需要开启 TUN 才会进入分流，否则只有走代理端口的流量能命中规则。")
                bullet("会话是懒启动的：没有流量选中它时不会连控制面，也就不会消耗资源。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Spacing.s)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Text("·").font(.dsBody).foregroundColor(.secondary)
            Text(s).font(.dsCaption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rows
    //
    // Local rows rather than the shared `TextRow`/`NToggle`: those bind to
    // `M.configs` (live kernel config) and commit with a PATCH. These fields are
    // user intent stored in UserDefaults and only reach the kernel through a
    // full reload, so they must not pretend to be live config keys.

    private func tsTextRow(_ label: String,
                           value: Binding<String>,
                           placeholder: String,
                           help: String? = nil) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(label).font(.dsBody)
                if let help {
                    Text(help).font(.dsCaption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            TextField(placeholder, text: value)
                .inputStyle().font(.dsMono)
                .multilineTextAlignment(.trailing)
                .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }
        .padding(.vertical, DS.Spacing.s)
    }

    private func tsToggleRow(_ label: String,
                             help: String,
                             value: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(label).font(.dsBody)
                Text(help).font(.dsCaption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, DS.Spacing.s)
    }
}
