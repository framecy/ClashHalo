import SwiftUI

// MARK: - DNS (resolver query + Fake-IP from live connections)

struct DnsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var query = ""
    @State private var result = ""
    @State private var resolving = false

    /// `dns` 配置子字典。
    private var dns: [String: Any] { M.configs["dns"] as? [String: Any] ?? [:] }

    /// 活跃连接里观察到的 Fake-IP 映射（唯一 host 计数）。
    private var fakeipConns: [Conn] {
        M.cachedConns.filter { $0.dstIP.hasPrefix("198.18.") || $0.dstIP.hasPrefix("198.19.") }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    // 概览 — 只展示 mihomo 真实可得的量；命中率/平均解析无对应端点，不编造。
                    HStack(spacing: DS.Spacing.m) {
                        DSStatCard(label: "Fake-IP 映射",
                                   value: "\(fakeipConns.count)",
                                   sub: "来自活跃连接",
                                   accent: true)
                        DSStatCard(label: "Fake-IP 池",
                                   value: (dns["fake-ip-range"] as? String) ?? "—",
                                   sub: "dns.fake-ip-range")
                        DSStatCard(label: "增强模式",
                                   value: ((dns["enhanced-mode"] as? String) ?? "—").uppercased(),
                                   sub: "dns.enhanced-mode")
                        DSStatCard(label: "上游解析器",
                                   value: "\((dns["nameserver"] as? [Any])?.count ?? 0)",
                                   sub: "dns.nameserver")
                    }

                    // Fake-IP mappings observed in live connections — reuse the
                    // shared AppModel cache populated by the connections / gateway
                    // pollers. Do NOT start a second ConnectionsViewModel here
                    // (that used to double /connections traffic every 1.5s).
                    let fakeip = fakeipConns

                    // 内容栅格：DNS 服务器跨 2 列（原型 `2fr 1fr` 宽卡位），
                    // 解析测试占 1 列；Fake-IP 映射表跨满 3 列。
                    Grid(alignment: .top,
                         horizontalSpacing: DS.Layout.gridGutter,
                         verticalSpacing: DS.Layout.gridGutter) {
                    GridRow {
                    Card(title: "DNS 服务器", icon: "server.rack", stretch: true) {
                        VStack(spacing: 0) {
                            NToggle("启用 DNS", "dns", "enable")
                            NToggle("IPv6 解析", "dns", "ipv6")
                            NPicker("增强模式", "dns", "enhanced-mode", [("fake-ip","Fake-IP"),("redir-host","Redir-Host")])
                            NText("Fake-IP 段", "dns", "fake-ip-range", placeholder: "198.18.0.1/16")
                            NText("监听地址", "dns", "listen", placeholder: "0.0.0.0:53")
                            NList("上游 (nameserver)", "dns", "nameserver", placeholder: "https://1.1.1.1/dns-query")
                            NList("Fake-IP 过滤", "dns", "fake-ip-filter", placeholder: "*.lan")
                        }
                        Text("Fake-IP 为代理域名返回保留段虚拟 IP，避免 DNS 泄漏；上游支持 DoH/DoT/DoQ/UDP。")
                            .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
                    }
                    .gridCellColumns(2)

                    Card(title: "DNS 解析测试", icon: "magnifyingglass", stretch: true) {
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            HStack(spacing: DS.Spacing.s) {
                                TextField("输入域名，如 google.com", text: $query)
                                    .inputStyle()
                                    .onSubmit { Task { await resolve() } }
                                Button { Task { await resolve() } } label: {
                                    if resolving { ProgressView().controlSize(.small) } else { Text("解析") }
                                }
                                .dsButton()
                                .disabled(query.isEmpty || resolving)
                            }
                            if !result.isEmpty {
                                Text(result).font(.dsMono).foregroundColor(.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                             }
                        }
                    }

                    }

                    GridRow {
                    Card(title: "Fake-IP 映射 · \(fakeip.count)", icon: "arrow.left.arrow.right", pad: false) {
                        if fakeip.isEmpty {
                            Text("当前无 Fake-IP 连接（需内核启用 dns.enhanced-mode: fake-ip 且有代理流量；打开「连接」页可刷新映射）")
                                .font(.dsCaption).foregroundColor(.secondary)
                                .padding(DS.Spacing.m)
                        } else {
                            VStack(spacing: 0) {
                                HStack(spacing: DS.Spacing.s) {
                                    DSTableHead(title: "域名")
                                    DSTableHead(title: "FAKE-IP", width: 130)
                                    DSTableHead(title: "真实 IP", width: 130)
                                }
                                .padding(.horizontal, DS.Spacing.s + 2)
                                .frame(height: 26)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(DS.Palette.border).frame(height: 0.5)
                                }

                                ForEach(fakeip.prefix(50)) { c in
                                    DSTableRow {
                                        HStack(spacing: DS.Spacing.s) {
                                            Text(c.host).font(.dsBody).lineLimit(1)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(c.dstIP).font(.dsMonoSmBold)
                                                .foregroundColor(DS.Palette.accent)
                                                .frame(width: 130, alignment: .leading)
                                            Text(c.host == c.dstIP ? "—" : c.host)
                                                .font(.dsMonoSm).foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .frame(width: 130, alignment: .leading)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .gridCellColumns(3)
                    }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Layout.pageContentInset).padding(.bottom, 26)
            }
        }
    }
    private func resolve() async {
        resolving = true; defer { resolving = false }
        guard let j = try? await M.api.dnsQuery(name: query) else { result = "解析失败"; return }
        if let answers = j["Answer"] as? [[String: Any]] {
            result = answers.compactMap { "\($0["data"] ?? "")" }.joined(separator: "\n")
        } else if let msg = j["message"] as? String {
            result = msg
        } else {
            result = "无结果"
        }
        if result.isEmpty { result = "无 A 记录" }
    }
}

