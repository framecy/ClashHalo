// Tests/InboundListener —— 直接编译生产源码 Sources/Model/InboundListener.swift。
//
// 这一套钉的是「别把端口开到局域网上」：
//   1. 序列化必须**永远显式写 `listen:`**——2026-10-20 实测：不写 listen 时内核绑 `*`，
//      `bind-address` 对 listener 完全无效（写了也绑 `*`）；
//   2. `network` 必须是数组 `[tcp,udp]`（写成 `network: tcp` 内核直接报
//      `'network' is not a slice`）；
//   3. 禁用条目整条注释（`enabled:` 这类未知字段内核不报错也不生效）；
//   4. 替换块只动 `listeners:`，文件其余字节逐字节不变；内联写法交调用方报错；
//   5. 校验必须挡下重名/端口冲突/缺目标/非法监听地址。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

let sample = """
mixed-port: 7890
mode: rule
listeners:
  - name: fwd-nas
    type: tunnel
    port: 18080
    listen: 127.0.0.1
    target: 192.168.1.233:8080
    network: [tcp, udp]
  # - name: old-disabled
  #   type: tunnel
  #   port: 18081
  #   listen: 0.0.0.0
  #   target: 10.0.0.2:22
  #   network: [tcp]
proxy-groups: []
"""

// ── 1. 解析 ───────────────────────────────────────────────────────────
print("== 解析 ==")
let parsed = InboundListenerStore.parse(from: sample)
check(parsed.count == 2, "读到 2 条（含禁用条目）")
check(parsed[0].name == "fwd-nas" && parsed[0].port == 18080, "名称与端口")
check(parsed[0].network == [.tcp, .udp], "network 解析为集合")
check(parsed[0].listen == "127.0.0.1" && !parsed[0].allowsLAN, "仅本机监听")
check(parsed[0].target == "192.168.1.233:8080", "目标地址")
check(parsed[0].isEnabled, "启用状态")
check(!parsed[1].isEnabled, "被注释的条目解析为禁用")
check(parsed[1].allowsLAN, "0.0.0.0 视为允许局域网")
check(InboundListenerStore.parse(from: "listeners: []\n").isEmpty, "空数组 → 无条目")
check(InboundListenerStore.parse(from: "mixed-port: 1\n").isEmpty, "没有块 → 无条目")
check(InboundListenerStore.parse(from: "listeners:\nmixed-port: 1\n").isEmpty, "块后立刻是顶层键 → 无条目")

// ── 2. 序列化：安全不变量 ─────────────────────────────────────────────
print("== 序列化 ==")
let lan = InboundListener(name: "fwd-lan", type: .tunnel, port: 18082,
                          listen: "0.0.0.0", target: "10.0.0.9:22",
                          network: [.tcp, .udp], isEnabled: true)
let rendered = InboundListenerStore.render([lan])
let joined = rendered.joined(separator: "\n")
check(joined.contains("listen: 0.0.0.0"), "显式写 listen")
check(joined.contains("network: [tcp,udp]"), "network 是数组、顺序固定（\(joined.components(separatedBy: "\n").last ?? "")）")
check(joined.contains("target: 10.0.0.9:22"), "target 写入")

let disabled = InboundListener(name: "off", type: .socks, port: 18083,
                               listen: "127.0.0.1", target: "",
                               network: [.tcp], isEnabled: false)
let offText = InboundListenerStore.render([disabled]).joined(separator: "\n")
check(offText.contains("# - name: off"), "禁用条目整条注释（\(offText.components(separatedBy: "\n").first ?? "")）")
check(offText.contains("#   listen: 127.0.0.1"), "禁用条目的字段也注释")
check(!offText.contains("target:"), "非 tunnel 不写 target")

// 无论什么组合，渲染结果都必须带 listen —— 这是「不写到局域网」的唯一保证
for l in [lan, disabled] {
    check(InboundListenerStore.render([l]).joined().contains("listen:"), "\(l.name) 的渲染包含 listen")
}

// 往返：render → parse 不丢信息
let roundTrip = InboundListenerStore.parse(from: "listeners:\n" + InboundListenerStore.render([lan]).joined(separator: "\n"))
check(roundTrip.count == 1 && roundTrip[0] == lan, "序列化→解析往返一致")

// ── 3. 替换块：只动 listeners ─────────────────────────────────────────
print("== 替换块 ==")
let replaced = InboundListenerStore.replaceBlock(in: sample, with: [lan])
check(replaced != nil, "替换成功")
if let out = replaced {
    check(out.contains("fwd-lan") && !out.contains("fwd-nas"), "旧条目被替换")
    check(out.contains("mixed-port: 7890") && out.contains("mode: rule"), "顶层键保留")
    check(out.contains("proxy-groups: []"), "块后的内容保留")
    check(InboundListenerStore.parse(from: out).count == 1, "回读只有 1 条")
}

let noBlock = InboundListenerStore.replaceBlock(in: "mixed-port: 7890\n", with: [lan])
check(noBlock?.contains("listeners:") == true, "没有块时追加")
check(noBlock?.contains("  listen: 0.0.0.0") == true, "追加内容完整（含显式 listen）")
check(noBlock?.hasPrefix("mixed-port: 7890") == true, "原有内容保留在块之前")
check(noBlock?.contains("\n\nlisteners:") == true, "追加前留一个空行（便于阅读）")

let removedAll = InboundListenerStore.replaceBlock(in: sample, with: [])
check(removedAll?.contains("listeners:") == false, "清空时整块移除")
check(removedAll?.contains("proxy-groups: []") == true, "清空不影响其它内容")

check(InboundListenerStore.replaceBlock(in: "listeners: [{name: x}]\n", with: [lan]) == nil,
      "内联写法 → nil（不猜，交调用方报错）")
check(InboundListenerStore.replaceBlock(in: "listeners:\n  - name: a\n    port: 1\nlisteners:\n  - name: b\n    port: 2\n", with: [lan]) == nil,
      "重复 listeners 块 → nil")

// ── 4. 校验 ───────────────────────────────────────────────────────────
print("== 校验 ==")
func v(_ l: InboundListener, existing: [InboundListener] = [],
       reserved: [Int: String] = [:]) -> String? {
    InboundListenerStore.validate(l, existing: existing, reservedPorts: reserved)
}
let ok = InboundListener(name: "fwd", type: .tunnel, port: 18090, listen: "127.0.0.1",
                         target: "10.0.0.1:80", network: [.tcp], isEnabled: true)
check(v(ok) == nil, "合法条目通过")

check(v(InboundListener(name: "", type: .tunnel, port: 18090, listen: "127.0.0.1",
                        target: "1.2.3.4:80", network: [.tcp], isEnabled: true)) != nil, "空名称被拒")
check(v(InboundListener(name: "a b", type: .tunnel, port: 18090, listen: "127.0.0.1",
                        target: "1.2.3.4:80", network: [.tcp], isEnabled: true)) != nil, "名称含空格被拒")
check(v(ok, existing: [ok]) != nil, "重名被拒")
check(v(InboundListener(name: "fwd", type: .tunnel, port: 0, listen: "127.0.0.1",
                        target: "1.2.3.4:80", network: [.tcp], isEnabled: true)) != nil, "端口 0 被拒")
check(v(InboundListener(name: "fwd", type: .tunnel, port: 70000, listen: "127.0.0.1",
                        target: "1.2.3.4:80", network: [.tcp], isEnabled: true)) != nil, "端口越界被拒")

let other = InboundListener(name: "other", type: .tunnel, port: 18090, listen: "127.0.0.1",
                            target: "1.2.3.4:80", network: [.tcp], isEnabled: true)
check(v(ok, existing: [other])?.contains("已被「other」占用") == true, "端口冲突指出占用者")
check(v(ok, reserved: [18090: "混合端口"] )?.contains("混合端口") == true, "与内置端口冲突有可读原因")

check(v(InboundListener(name: "fwd", type: .tunnel, port: 18090, listen: "127.0.0.1",
                        target: "1.2.3.4:80", network: [], isEnabled: true)) != nil, "未选协议被拒")
check(v(InboundListener(name: "fwd", type: .tunnel, port: 18090, listen: "192.168.1.5",
                        target: "1.2.3.4:80", network: [.tcp], isEnabled: true)) != nil,
      "只允许 127.0.0.1 / 0.0.0.0（防手滑写错地址导致意外开放）")
check(v(InboundListener(name: "fwd", type: .tunnel, port: 18090, listen: "127.0.0.1",
                        target: "", network: [.tcp], isEnabled: true)) != nil, "tunnel 缺目标被拒")
check(v(InboundListener(name: "fwd", type: .tunnel, port: 18090, listen: "127.0.0.1",
                        target: "1.2.3.4", network: [.tcp], isEnabled: true)) != nil, "目标缺端口被拒")
check(v(InboundListener(name: "fwd", type: .tunnel, port: 18090, listen: "127.0.0.1",
                        target: "1.2.3.4:0", network: [.tcp], isEnabled: true)) != nil, "目标端口 0 被拒")
check(v(InboundListener(name: "s", type: .socks, port: 18090, listen: "127.0.0.1",
                        target: "1.2.3.4:80", network: [.tcp], isEnabled: true)) != nil,
      "非 tunnel 不接受目标地址")

print("")
if failures == 0 { print("InboundListener: 全部通过"); exit(0) }
print("InboundListener: \(failures) 处失败"); exit(1)
