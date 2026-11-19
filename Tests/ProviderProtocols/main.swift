// Tests/ProviderProtocols —— 直接编译生产源码 Sources/Model/ProviderProtocols.swift。
// 钉住订阅卡「协议分布」的三个口径：
//   1. 数值之和必须等于节点数（订阅卡上的「N 节点」与这一行不能互相矛盾）；
//   2. 协议种类超过 maxShown+1 才折叠，折叠打的是「种类数」不是节点数；
//   3. proxies 为 nil / 空数组时不产出任何文案（显示 0 会让人以为订阅坏了）。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

// ── 1. 典型订阅：QiuChen 式一行摘要 ───────────────────────────────────
print("== 典型三协议订阅 ==")
var types = [String](repeating: "Vless", count: 61)
types += [String](repeating: "Hysteria2", count: 25)
types += [String](repeating: "Shadowsocks", count: 2)
let s = ProviderProtocols.summarize(types)
check(s.text == "VLESS 61 · HYSTERIA2 25 · SS 2", "摘要 = \(s.text)")
check(s.total == 88, "总数 = 节点数")
check(s.items.reduce(0) { $0 + $1.count } + 0 == s.total, "分项之和 = 总数")
check(s.hiddenKinds == 0, "三种协议不折叠")

// ── 2. 折叠：超过 4 种才折叠为前 3 + N ────────────────────────────────
print("== 折叠边界 ==")
let four = ["Vless", "Hysteria2", "Shadowsocks", "Trojan"]
let s4 = ProviderProtocols.summarize(four)
check(s4.hiddenKinds == 0 && s4.items.count == 4, "恰好 4 种全部展示")
check(s4.text == "HYSTERIA2 1 · SS 1 · TROJAN 1 · VLESS 1", "4 种时无 +N（\(s4.text)）")

let five = ["Vless", "Hysteria2", "Shadowsocks", "Trojan", "Snell"]
let s5 = ProviderProtocols.summarize(five)
check(s5.hiddenKinds == 2, "5 种折叠 2 种")
check(s5.items.count == 3, "只展示 3 种")
check(s5.text.hasSuffix("+2"), "摘要以 +2 结尾（\(s5.text)）")
check(s5.total == 5 && s5.items.reduce(0) { $0 + $1.count } == 3,
      "总数仍按全部节点算（5），展示项只覆盖 3 个")

// ── 3. 空输入不产出文案 ─────────────────────────────────────────────
print("== 空输入 ==")
let empty = ProviderProtocols.summarize([])
check(empty.text.isEmpty && empty.isEmpty && empty.total == 0, "空数组 → 无文案")
check(ProviderProtocols.summarize(["", "  "]).text == "未知 2", "空类型归为「未知」而不是丢弃")

// ── 4. 排序稳定性：同数量按字母序，避免每次渲染顺序跳动 ──────────────
print("== 排序稳定性 ==")
let a = ProviderProtocols.summarize(["Trojan", "Vless", "Snell"])
let b = ProviderProtocols.summarize(["Snell", "Vless", "Trojan"])
check(a.text == b.text, "同一组数据不同输入顺序 → 同一文案（\(a.text)）")
check(a.items.first?.label == "SNELL", "同数量按字母序")

let skewed = ProviderProtocols.summarize(["Trojan"] + ["Vless", "Vless", "Vless"])
check(skewed.items.first?.label == "VLESS" && skewed.items.first?.count == 3, "数量多的排前面")

// ── 5. 短名归一 —— 只归一到明确对应，不吞掉未知协议 ──────────────────
print("== 短名归一 ==")
check(ProviderProtocols.shortLabel("Vless") == "VLESS", "大小写归一")
check(ProviderProtocols.shortLabel("Shadowsocks") == "SS", "Shadowsocks → SS")
check(ProviderProtocols.shortLabel("Hysteria2") == "HYSTERIA2", "Hysteria2 保持")
check(ProviderProtocols.shortLabel("SomeFutureProto") == "SOMEFUTUREPROTO",
      "未收录协议原样大写，不改写成别的")
check(ProviderProtocols.shortLabel("") == "未知", "空串 → 未知")

// ── 6. 单协议 ───────────────────────────────────────────────────────
print("== 单协议 ==")
let one = ProviderProtocols.summarize([String](repeating: "Trojan", count: 7))
check(one.text == "TROJAN 7" && one.total == 7, "单协议摘要 = \(one.text)")

print("")
if failures == 0 { print("ProviderProtocols: 全部通过"); exit(0) }
print("ProviderProtocols: \(failures) 处失败"); exit(1)
