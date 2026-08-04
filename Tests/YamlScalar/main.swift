import Foundation

// Test harness over the real shipping source
// (Sources/Core/YamlEditor/YamlScalar.swift), compiled in, not re-implemented.
//
// The regression: every value the line-scanning config reader produced used to
// carry its trailing YAML comment. On a real, heavily-commented mihomo config
// that meant `route-exclude-address` entries came back as
// "127.0.0.0/8            # 回环" (so nothing could match or restate them) and
// `mixed-port` failed `Int(_:)`, silently falling back to a hardcoded default.
//
// The opposite failure is just as damaging and is why this cannot simply split
// on "#": mihomo pins nameservers with `#`, e.g. `100.100.100.100#utun8`
// (egress interface) and `https://dns.google/dns-query#默认代理` (policy group).
// Truncating those breaks MagicDNS resolution and DNS policy routing.

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

func str(_ raw: String) -> String { YamlScalar.parse(raw) as? String ?? "<not-a-string>" }

// MARK: - Comments are stripped

section("行尾注释剥离")
expect(YamlScalar.stripInlineComment("127.0.0.0/8            # 回环") == "127.0.0.0/8",
       "route-exclude-address 条目去掉注释")
expect(YamlScalar.stripInlineComment("fd7a:115c:a1e0::/48    # Tailscale IPv6 ULA（新增）")
       == "fd7a:115c:a1e0::/48", "IPv6 前缀去掉中文注释")
expect(YamlScalar.parse("7890   # 混合端口") as? Int == 7890,
       "带注释的端口仍解析为 Int（此前退化为字符串并回落默认值）")
expect(YamlScalar.parse("true    # 启用") as? Bool == true, "带注释的布尔值")
expect(YamlScalar.stripInlineComment("strict\t# tab 分隔的注释") == "strict",
       "制表符分隔的注释")
expect(YamlScalar.stripInlineComment("value") == "value", "没有注释时原样返回")

// MARK: - `#` that is NOT a comment must survive

section("mihomo 的 # 语义不得被破坏")
expect(str("100.100.100.100#utun8") == "100.100.100.100#utun8",
       "nameserver 绑定出口接口 #utun8 保留")
expect(str("https://dns.google/dns-query#默认代理") == "https://dns.google/dns-query#默认代理",
       "nameserver 绑定策略组 #默认代理 保留")
expect(str("223.5.5.5#en0   # 走物理网卡") == "223.5.5.5#en0",
       "同时含绑定与注释：只去掉注释")
expect(str("rcode://name_error") == "rcode://name_error", "rcode 伪 URL 不受影响")

// MARK: - Quoted scalars are data

section("引号内的 # 是数据")
expect(str("'abc # def'") == "abc # def", "单引号内的 # 保留，且去掉引号")
expect(str("\"a # b\"") == "a # b", "双引号内的 # 保留")
expect(str("'127.0.0.1:9090'") == "127.0.0.1:9090", "带引号的 external-controller")

// MARK: - Flow arrays

section("流式数组")
expect((YamlScalar.parse("[443, 8443]") as? [String]) == ["443", "8443"], "端口流式数组")
expect((YamlScalar.parse("[443, 8443]  # TLS") as? [String]) == ["443", "8443"],
       "带注释的流式数组")
expect((YamlScalar.parse("[]") as? [String])?.isEmpty == true, "空流式数组")

// MARK: - Degenerate input

section("边界输入")
expect(YamlScalar.stripInlineComment("") == "", "空串")
expect(YamlScalar.stripInlineComment("# 整行注释") == "# 整行注释",
       "开头即 # 不视为行尾注释（整行注释由上层跳过）")
expect(str("'") == "'", "单个引号字符不被当成空引号对")

print("\n\(checks - failures)/\(checks) 通过")
if failures > 0 {
    print("\(failures) 项失败")
    exit(1)
}
