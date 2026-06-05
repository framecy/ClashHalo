import SwiftUI

// MARK: - DNS (resolver query + Fake-IP from live connections)

struct DnsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var query = ""
    @State private var result = ""
    @State private var resolving = false

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "DNS 缓存", desc: "内置 DNS 服务器 · Fake‑IP 映射与条目缓存分析") {
                Button { M.flushDnsCache() } label: { Label("刷新缓存", systemImage: "arrow.clockwise") }.controlSize(.small)
                Button { M.clearAllCache() } label: { Label("清空", systemImage: "trash") }.controlSize(.small)
            }

            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    // DNS settings (editable) — 顶部曾有硬编码的假统计(平均解析/池/缓存),
                    // mihomo 无对应统计端点, 已移除以免误导; 真实信息见下方 Fake-IP 映射。
                    Card(title: "DNS 服务器", icon: "server.rack") {
                        VStack(spacing: 2) {
                            NToggle("启用 DNS", "dns", "enable")
                            NToggle("IPv6 解析", "dns", "ipv6")
                            NPicker("增强模式", "dns", "enhanced-mode", [("fake-ip","Fake-IP"),("redir-host","Redir-Host")])
                            NText("Fake-IP 段", "dns", "fake-ip-range", placeholder: "198.18.0.1/16")
                            NText("监听地址", "dns", "listen", placeholder: "0.0.0.0:53")
                            NList("上游 (nameserver)", "dns", "nameserver", placeholder: "https://1.1.1.1/dns-query")
                            NList("Fake-IP 过滤", "dns", "fake-ip-filter", placeholder: "*.lan")
                        }
                        Text("Fake-IP 为代理域名返回保留段虚拟 IP，避免 DNS 泄漏；上游支持 DoH/DoT/DoQ/UDP。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                    }

                    Card(title: "DNS 解析测试", icon: "magnifyingglass") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("输入域名，如 google.com", text: $query)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { Task { await resolve() } }
                                Button { Task { await resolve() } } label: {
                                    if resolving { ProgressView().controlSize(.small) } else { Text("解析") }
                                }.disabled(query.isEmpty || resolving)
                            }
                            if !result.isEmpty {
                                Text(result).font(.dsMono).foregroundColor(.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    // Fake-IP mappings observed in live connections
                    let fakeip = M.conns.filter { $0.dstIP.hasPrefix("198.18.") || $0.dstIP.hasPrefix("198.19.") }
                    Card(title: "Fake-IP 映射 · \(fakeip.count)（来自活跃连接）") {
                        if fakeip.isEmpty {
                            Text("当前无 Fake-IP 连接（需内核启用 dns.enhanced-mode: fake-ip 且有代理流量）")
                                .font(.dsBody).foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(fakeip.prefix(50)) { c in
                                    HStack {
                                        Text(c.host).font(.dsBody).lineLimit(1)
                                        Spacer()
                                        Text(c.dstIP).font(.dsMono).foregroundColor(M.accent)
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.xl).padding(.bottom, DS.Spacing.xxl)
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

