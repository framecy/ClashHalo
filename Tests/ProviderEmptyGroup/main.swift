// 空组预检回归：钉住 ProviderUsage.groupsMissingMembers 的扫描口径。
// 与生产一致的原则：直接编译 Sources/Model/ProviderUsage.swift，不复制逻辑。

import Foundation

var failures: [String] = []
func check(_ cond: Bool, _ name: String) {
    if cond { print("✓ \(name)") } else { failures.append(name); print("✗ \(name)") }
}

// 1. 只靠 use: 供血的组，删掉 provider 后（use: 块连同条目被移除）→ 空组
let deleteLast = """
proxy-groups:
  - name: 默认代理
    type: select
rules:
  - MATCH,DIRECT
"""
check(ProviderUsage.groupsMissingMembers(in: deleteLast) == ["默认代理"], "删除唯一来源后组为空")

// 2. 还有 proxies: 条目的组不算空
let hasProxies = """
proxy-groups:
  - name: 默认代理
    type: select
    proxies:
      - 节点1
      - 节点2
    use:
      - "US-A"
"""
check(ProviderUsage.groupsMissingMembers(in: hasProxies).isEmpty, "proxies 有条目不算空")

// 3. 内联写法两种都认
let inlineUse = """
proxy-groups:
  - name: G1
    type: select
    use: ["US-A"]
  - name: G2
    type: select
    proxies: [节点1]
  - name: G3
    type: select
"""
check(ProviderUsage.groupsMissingMembers(in: inlineUse) == ["G3"], "内联 use/proxies 认得，真空组报出来")

// 4. 多组，第二个空 → 顺序保留
let twoGroups = """
proxy-groups:
  - name: 首组
    type: select
    use:
      - "US-A"
  - name: 次组
    type: select
"""
check(ProviderUsage.groupsMissingMembers(in: twoGroups) == ["次组"], "多组只报空的那个")

// 5. proxy-groups 之外的同名文本不算；空 use: [] 不算有来源
let outside = """
rules:
  - MATCH,默认代理
proxy-groups:
  - name: 默认代理
    type: select
    use: []
"""
check(ProviderUsage.groupsMissingMembers(in: outside) == ["默认代理"], "use: [] 不算有来源，rules 块不干扰")

// 6. 组名带引号与行尾注释
let quoted = """
proxy-groups:
  - name: "US 组"  # 备注
    type: select
"""
check(ProviderUsage.groupsMissingMembers(in: quoted) == ["US 组"], "组名剥引号与行尾注释")

// 7. include-all 家族：成员来自全部节点/provider，不算空
let includeAll = """
proxy-groups:
  - name: 自动选择
    type: url-test
    include-all: true
"""
check(ProviderUsage.groupsMissingMembers(in: includeAll).isEmpty, "include-all 组不算空")

let includeAllProviders = """
proxy-groups:
  - name: 全部节点
    type: select
    include-all-providers: true
"""
check(ProviderUsage.groupsMissingMembers(in: includeAllProviders).isEmpty, "include-all-providers 组不算空")

let includeAllProxies = """
proxy-groups:
  - name: 直连兜底
    type: select
    include-all-proxies: true
"""
check(ProviderUsage.groupsMissingMembers(in: includeAllProxies).isEmpty, "include-all-proxies 组不算空")

if failures.isEmpty {
    print("ALL PASS")
} else {
    print("FAILED: \(failures.count)")
    exit(1)
}
