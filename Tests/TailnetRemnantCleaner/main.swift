import Foundation

// Regression harness for TailnetRemnantCleaner（v1.6.0 删除内置 Tailnet 的存量清理）。
//
// 直接编译生产源码（cleaner + KeychainHelper + Hash），不重写规则。
// 这里只测纯逻辑（scrub / tsReferences）与 validate() 的判定，不调用 run()：
// run() 会读写真实的 Keychain 与 UserDefaults，必须在真实升级路径上验证。

var failures = 0, checks = 0
func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures += 1; print("  ✗ FAIL: \(what)") } else { print("  ✓ \(what)") }
}
func section(_ s: String) { print("\n── \(s) ──") }

let closed = """
mixed-port: 7890
proxies:
  # >>> clashhalo:tailscale >>>
  - {name: "TSNODE", type: tailscale, state-dir: "tailscale", auth-key: "tskey-auth-EXAMPLE"}
  # <<< clashhalo:tailscale <<<
  - {name: "SS1", type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: "x"}
rules:
  # >>> clashhalo:tailscale >>>
  - DOMAIN-SUFFIX,ts.net,TSNODE
  - IP-CIDR,100.64.0.0/10,TSNODE,no-resolve
  # <<< clashhalo:tailscale <<<
  - MATCH,DIRECT
dns:
  nameserver-policy:
    "+.ts.net": "ts://TSNODE"
"""

section("闭合 fence：节点/规则/DNS 全摘，其余保留")
do {
    let s = TailnetRemnantCleaner.scrub(closed, names: ["TSNODE"])
    expect(!s.yaml.contains("TSNODE"), "节点被摘")
    expect(!s.yaml.contains("clashhalo:tailscale"), "fence 两行被摘")
    expect(!s.yaml.contains("ts://"), "ts:// 策略被摘")
    expect(s.yaml.contains("name: \"SS1\""), "其它节点保留")
    expect(s.yaml.contains("  - MATCH,DIRECT"), "其它规则保留")
    expect(s.yaml.contains("proxies:"), "proxies 键保留")
    expect(s.nodes == ["TSNODE"], "报告被摘节点名")
    expect(s.changed, "changed=true")
}

section("未闭合 fence：仍摘注入项，但不删到文件尾")
do {
    let broken = """
proxies:
  # >>> clashhalo:tailscale >>>
  - {name: "TSNODE", type: tailscale, state-dir: "tailscale", auth-key: "tskey-auth-EXAMPLE"}
rules:
  - DOMAIN-SUFFIX,ts.net,TSNODE
  - MATCH,DIRECT
"""
    let s = TailnetRemnantCleaner.scrub(broken, names: ["TSNODE"])
    expect(!s.yaml.contains("TSNODE"), "节点与规则被摘")
    expect(s.yaml.contains("  - MATCH,DIRECT"), "不删到文件尾")
    expect(s.yaml.contains("rules:"), "后续键保留")
}

section("block 风格节点")
do {
    let block = """
proxies:
  - name: "TSNODE"
    type: tailscale
    state-dir: "tailscale"
    auth-key: "tskey-auth-EXAMPLE"
  - name: "SS1"
    type: ss
    server: 1.2.3.4
rules:
  - MATCH,DIRECT
"""
    let s = TailnetRemnantCleaner.scrub(block, names: [])
    expect(!s.yaml.contains("TSNODE"), "按 state-dir 命中")
    expect(s.yaml.contains("name: \"SS1\""), "其它 block 节点保留")
    expect(s.yaml.contains("server: 1.2.3.4"), "节点子行完整保留")
}

section("订阅自带的 tailscale 节点（state-dir 不同、名字未知）必须保留")
do {
    let sub = """
proxies:
  - name: "SUB-TS"
    type: tailscale
    state-dir: "sub-ts"
  - name: "SS1"
    type: ss
    server: 1.2.3.4
rules:
  - MATCH,DIRECT
"""
    let s = TailnetRemnantCleaner.scrub(sub, names: [])
    expect(!s.changed, "零改动")
    expect(s.yaml == sub, "文本逐字节相同")
}

section("规则引用完整性：只摘指向被删节点的规则")
do {
    let y = """
rules:
  - DOMAIN-SUFFIX,ts.net,TSNODE
  - DOMAIN-SUFFIX,ts.net,OTHER
  - MATCH,DIRECT
"""
    let s = TailnetRemnantCleaner.scrub(y, names: ["TSNODE"])
    expect(!s.yaml.contains("TSNODE"), "指向被删节点的规则被摘")
    expect(s.yaml.contains("ts.net,OTHER"), "指向其它节点的规则保留")
}

section("DNS：只摘 ts:// 且名字命中")
do {
    let y = """
dns:
  nameserver-policy:
    "+.ts.net": "ts://TSNODE"
    "+.corp.example": "1.1.1.1"
"""
    let s = TailnetRemnantCleaner.scrub(y, names: ["TSNODE"])
    expect(!s.yaml.contains("ts://"), "ts:// 被摘")
    expect(s.yaml.contains("1.1.1.1"), "普通 nameserver-policy 保留")
}

section("nameserver-policy 列表写法：条目值被清空时连键一起删")
do {
    let y = """
dns:
  nameserver-policy:
    "+.ts.net":
      - "ts://TSNODE"
    "+.corp.example": "9.9.9.9"
"""
    let s = TailnetRemnantCleaner.scrub(y, names: ["TSNODE"])
    expect(!s.yaml.contains("+.ts.net"), "空条目键被删（null 值会让 mihomo panic）")
    expect(s.yaml.contains("+.corp.example"), "其它条目保留")
}

section("干净配置零改动 / 幂等")
do {
    let clean = "mixed-port: 7890\nproxies:\n  - {name: SS1, type: ss}\nrules:\n  - MATCH,DIRECT\n"
    let s = TailnetRemnantCleaner.scrub(clean, names: [])
    expect(!s.changed && s.yaml == clean, "干净配置逐字节不变")
    let once = TailnetRemnantCleaner.scrub(closed, names: ["TSNODE"]).yaml
    let twice = TailnetRemnantCleaner.scrub(once, names: ["TSNODE"])
    expect(!twice.changed && twice.yaml == once, "二次清理零改动")
}

section("ts:// 两种写法 / hostname 不得被当成 name")
do {
    let r = TailnetRemnantCleaner.tsReferences(in: "a: \"ts://A\"\nb: ts://B\nc: \"1.1.1.1\"\n")
    expect(r == ["A", "B"], "tsReferences 取到两种写法")
    let y = """
proxies:
  - hostname: "NODEHOST"
    name: "TSNODE"
    type: tailscale
    state-dir: "tailscale"
"""
    let s = TailnetRemnantCleaner.scrub(y, names: ["TSNODE"])
    expect(!s.yaml.contains("TSNODE"), "名字命中仍能摘")
    expect(s.nodes == ["TSNODE"], "proxyName 未误取 hostname")
}

section("validate() 判定：本次清理的错才回滚")
do {
    let tmp = NSTemporaryDirectory() + "clashhalo-cleaner-tests-\(getpid())"
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let kernel = ProcessInfo.processInfo.environment["MIHOMO_BIN"]

    // 无内核：必须降级为 unavailable，绝不误判 ok
    let v = TailnetRemnantCleaner.validate(root: tmp, kernel: nil, removed: ["TSNODE"])
    if case .unavailable = v { expect(true, "无内核 → unavailable") } else { expect(false, "无内核 → unavailable") }

    // 规则残留引用被删节点 → failed（实测 mihomo 报 proxy [TSNODE] not found）
    if let kernel, FileManager.default.fileExists(atPath: kernel) {
        let p = tmp + "/config.yaml"
        try? """
        mixed-port: 17895
        proxies: []
        rules:
          - DOMAIN-SUFFIX,ts.net,TSNODE
          - MATCH,DIRECT
        """.write(toFile: p, atomically: true, encoding: .utf8)
        if case .failed = TailnetRemnantCleaner.validate(root: tmp, kernel: kernel, removed: ["TSNODE"]) {
            expect(true, "残留引用 → failed")
        } else { expect(false, "残留引用 → failed") }

        // 与本次清理无关的错 → ok（否则永远清不掉）
        try? """
        mixed-port: 17896
        proxies: []
        rules:
          - BOGUS-RULE,foo,DIRECT
          - MATCH,DIRECT
        """.write(toFile: p, atomically: true, encoding: .utf8)
        if case .ok = TailnetRemnantCleaner.validate(root: tmp, kernel: kernel, removed: ["TSNODE"]) {
            expect(true, "无关错误 → ok")
        } else { expect(false, "无关错误 → ok") }
    } else {
        print("  · 跳过 mihomo 相关断言（未设置 MIHOMO_BIN）")
    }
}

section("run() 端到端（注入临时目录 / fake Keychain / 独立 UserDefaults）")
do {
    let root = NSTemporaryDirectory() + "clashhalo-run-tests-\(getpid())"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let cfg = root + "/config.yaml"
    let yaml = """
    proxies:
      - {name: "TSNODE", type: tailscale, state-dir: "tailscale", auth-key: "tskey-auth-EXAMPLE"}
      - {name: "SS1", type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: "x"}
    rules:
      - DOMAIN-SUFFIX,ts.net,TSNODE
      - MATCH,DIRECT
    dns:
      nameserver-policy:
        "+.ts.net": "ts://TSNODE"
    """
    try? yaml.write(toFile: cfg, atomically: true, encoding: .utf8)
    let profiles = root + "/profiles"
    try? fm.createDirectory(atPath: profiles, withIntermediateDirectories: true)
    try? "proxies:\n  - {name: \"TSNODE\", type: tailscale, state-dir: \"tailscale\", auth-key: \"k\"}\nrules:\n  - MATCH,DIRECT\n"
        .write(toFile: profiles + "/p.yaml", atomically: true, encoding: .utf8)
    try? fm.createDirectory(atPath: root + "/tailscale", withIntermediateDirectories: true)

    let suiteName = "clashhalo-cleaner-tests-\(getpid())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("TSNODE", forKey: "tailscale.nodeName")
    defaults.set(true, forKey: "tailscale.enabled")
    var keychain = ["tailscale.authkey": "tskey-auth-EXAMPLE"]

    let r = TailnetRemnantCleaner.run(
        configPath: cfg, profilesDir: profiles, kernelPath: nil,
        writeConfig: { text in (try? text.write(toFile: cfg, atomically: true, encoding: .utf8)) != nil },
        defaults: defaults,
        deleteKeychain: { keychain.removeValue(forKey: $0) != nil },
        readKeychain: { keychain[$0] }
    )
    expect(r.ran, "run() 执行")
    expect(r.changedFiles.count == 2, "config.yaml 与 profile 都被清理")
    expect(r.removedNodes == ["TSNODE"], "报告被摘节点")
    expect(!((try? String(contentsOfFile: cfg, encoding: .utf8)) ?? "").contains("TSNODE"), "盘上节点已消失")
    expect(!((try? String(contentsOfFile: profiles + "/p.yaml", encoding: .utf8)) ?? "").contains("TSNODE"), "profile 也被清理")
    expect(keychain.isEmpty, "凭据被删")
    expect(r.keychainResidue.isEmpty, "无凭据残留")
    expect(defaults.string(forKey: "tailscale.nodeName") == nil, "UserDefaults 键被清")
    expect(r.stateDirRetired, "状态目录已改名让位")
    expect(!r.warnings.isEmpty, "内核不可用时如实告警（不写完成标记）")
    expect(defaults.bool(forKey: "tailnet.remnantCleaned") == false, "有告警时不置完成标记")

    // 幂等：再来一次，干净配置零改动
    let again = TailnetRemnantCleaner.run(
        configPath: cfg, profilesDir: profiles, kernelPath: nil,
        writeConfig: { text in (try? text.write(toFile: cfg, atomically: true, encoding: .utf8)) != nil },
        defaults: defaults, deleteKeychain: { _ in true }, readKeychain: { _ in nil }
    )
    expect(again.changedFiles.isEmpty, "二次运行零改动（幂等）")
    defaults.removePersistentDomain(forName: suiteName)
}

print("\n\(checks - failures)/\(checks) 通过")
if failures > 0 { print("\(failures) 处失败"); exit(1) }
