// Tests/TUNLoopSentinel — 直接编译生产源码 Sources/Model/TUNLoopSentinel.swift。
// 钉住 2026-09-16 幽灵流量事故（config tun off、utun100 僵尸持 211 条路由、
// dataaccessd→caldav 的 UDP 被 DIRECT 回注同一隧道，单连接 6 秒 625MB、
// 上行恒 0、18 天记出 10.8TB）。验证两半：该触发时必须触发（事故回放），
// 不该触发时绝不触发（真实下载/代理链/断流/瞬态/回收/上界）。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

// ── 事故回放：DIRECT + caldav + 208MB/拍(104MB/s×2s 快照) + 上行恒 0 ──
// App 实际快照节奏 2s（trafficRefreshInterval），事故 conn 上行自建立起为 0。
print("== 事故回放：必须恰好在第 requiredTicks 拍触发 ==")
var s = TUNLoopSentinel()
var trip: TUNLoopTrip?
for i in 1...6 {
    let r = s.observe(id: "6949c152", chains: ["DIRECT", "苹果服务"],
                      host: "p119-caldav.icloud.com", destinationIP: "17.248.216.20",
                      tickDownBytes: 208_000_000, totalUploadBytes: 0)
    if i < 6 { check(r == nil, "第 \(i) 拍不提前触发") }
    else { trip = r; check(r != nil, "第 6 拍触发") }
}
if let t = trip {
    check(t.connID == "6949c152", "触发携带 connID")
    check(t.host == "p119-caldav.icloud.com", "host 取证正确")
    check(t.destinationIP == "17.248.216.20", "dstIP 取证正确（供路由反查）")
    check(t.ticks == 6 && t.phantomBytes == 6 * 208_000_000,
          "phantom 计数 \(t.phantomBytes / 1_000_000)MB / ticks \(t.ticks)")
}

// ── 负样本 1：真实 iCloud 大下载——上行有持续流量（同步/上传请求） ──
print("== 真实下载：上行 5GB、下行 30MB/拍，30 拍不得触发 ==")
var s2 = TUNLoopSentinel()
var trips = 0
for _ in 1...30 {
    if s2.observe(id: "real", chains: ["DIRECT"], host: "icloud-content.com",
                  destinationIP: "17.248.100.1", tickDownBytes: 30_000_000,
                  totalUploadBytes: 5_000_000_000) != nil { trips += 1 }
}
check(trips == 0, "有上行流量的大下载零触发")

// ── 负样本 2：代理链同样"下行猛、上行小"——DIRECT 是必要条件 ──
print("== 代理链：形状相同但含节点链，不得触发 ==")
var s3 = TUNLoopSentinel()
trips = 0
for _ in 1...30 {
    if s3.observe(id: "prox", chains: ["FRAME-VLESS_TCP/TLS_Vision", "默认代理"],
                  host: "fast.cdn", destinationIP: "104.16.1.1",
                  tickDownBytes: 50_000_000, totalUploadBytes: 10) != nil { trips += 1 }
}
check(trips == 0, "非 DIRECT 链零触发（代理回源的静默大下行不误伤）")

// ── 负样本 3：突发+断流——不连续就不算循环（streak 复位） ──
print("== 断流复位：5 拍猛 + 1 拍静 + 5 拍猛，不得触发 ==")
var s4 = TUNLoopSentinel()
trips = 0
for i in 1...11 {
    let down: Int64 = (i == 6) ? 1_000 : 30_000_000
    if s4.observe(id: "bursty", chains: ["DIRECT"], host: "b", destinationIP: "8.8.8.8",
                  tickDownBytes: down, totalUploadBytes: 0) != nil { trips += 1 }
}
check(trips == 0, "中间断流一拍即复位")

// ── 负样本 4：刚过阈值线下的量级（24.9MB/拍）不触发；恰好 25MB 触发 ──
print("== 阈值边界：24.99MB 不触发 / 25MB 起算 ==")
var s4b = TUNLoopSentinel()
trips = 0
for _ in 1...20 {
    if s4b.observe(id: "edge", chains: ["DIRECT"], host: "e", destinationIP: "9.9.9.9",
                   tickDownBytes: 24_990_000, totalUploadBytes: 0) != nil { trips += 1 }
}
check(trips == 0, "24.99MB/拍永不触发")
var s4c = TUNLoopSentinel()
trip = nil
for _ in 1...6 {
    if let r = s4c.observe(id: "edge2", chains: ["DIRECT"], host: "e", destinationIP: "9.9.9.9",
                           tickDownBytes: 25_000_000, totalUploadBytes: 2_000_000) { trip = r }
}
check(trip != nil, "25MB/拍 + 上行 2MB（≤maxSilentUploadBytes）恰好触发")

// ── 负样本 5：消失即回收；触发后复位；watch 上界有界 ──
print("== 生命周期：回收 / reset / 上限修剪 ==")
var s5 = TUNLoopSentinel()
_ = s5.observe(id: "gone", chains: ["DIRECT"], host: "g", destinationIP: "8.8.4.4",
               tickDownBytes: 30_000_000, totalUploadBytes: 0)
check(s5.watchedCount == 1, "观测中")
s5.reap(excluding: [])
check(s5.watchedCount == 0, "连接消失即回收")
var s6 = TUNLoopSentinel()
for i in 1...70 {
    _ = s6.observe(id: "c\(i)", chains: ["DIRECT"], host: "h", destinationIP: "1.1.1.1",
                   tickDownBytes: 30_000_000, totalUploadBytes: 0)
}
// 稳态：count 冲到 65 即修剪回 32，故任意时刻 ≤ 65；灌 70 条后必远小于 70。
check(s6.watchedCount <= 65 && s6.watchedCount < 70,
      "watch 上界修剪生效 (got \(s6.watchedCount), 保留 phantom 最大的 32 条+其后新入)")
s6.reset()
check(s6.watchedCount == 0, "reset 清空（自愈后重开观测）")

// ── 事故量级 sanity：按 18 天真实速率折算，回放哨兵要报的 phantom/秒 ──
// 625.7MB/6s = 104MB/s。App 节奏 2s → 208MB/拍 → 每拍都是事故回放形状。
// 若快照节奏退化为 5s（后台），104MB/s×5=520MB/拍，形状不变——阈值按字节
// 不按速率，天然跨节奏成立。这里显式钉一次：
print("== 节奏无关性：5s 快照（520MB/拍）同样恰好在第 6 拍触发 ==")
var s7b = TUNLoopSentinel()
trip = nil
for i in 1...6 {
    let r = s7b.observe(id: "slow", chains: ["DIRECT", "苹果服务"], host: "p119-caldav",
                        destinationIP: "17.248.216.20", tickDownBytes: 520_000_000,
                        totalUploadBytes: 0)
    if i == 6 { trip = r }
}
check(trip?.phantomBytes == 6 * 520_000_000, "5s 节奏回放 phantom \(trip!.phantomBytes / 1_000_000_000)GB/30s")

if failures == 0 { print("\nTUNLoopSentinel: 全部通过") }
else { print("\nTUNLoopSentinel: \(failures) 项失败"); exit(1) }
