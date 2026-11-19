// Tests/DeviceIdentity —— 直接编译生产源码 Sources/Model/DeviceIdentity.swift。
//
// 钉住四件事：
//   1. OUI 表是手写长表，格式必须全部合法、不得有重复键（字典字面量重复键会运行时崩溃，
//      所以表改成文本解析；这里断言解析结果没有丢条目）；
//   2. `arp -an` 的行解析（macOS 实测格式：MAC 会去前导零、incomplete 条目要跳过）；
//   3. 跨网段/拿不到 MAC 时必须显示「未知」而不是空串或伪造身份；
//   4. 类型只能来自厂商白名单或端口指纹，判不出就不猜。
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") }
    else { print("  ✗ \(msg)"); failures += 1 }
}

// ── 1. 表完整性 ───────────────────────────────────────────────────────
print("== OUI 表 ==")
let count = DeviceIdentityResolver.ouiEntryCount
check(count >= 400, "条目数 \(count)（≥400）")
check(DeviceIdentityResolver.ouiEntryCount == count, "重复调用结果稳定（解析确定性）")

let keys = DeviceIdentityResolver.ouiKeys
check(keys.allSatisfy { $0.count == 6 && $0.allSatisfy { c in c.isHexDigit || ("A"..."F").contains(String(c)) } },
      "每个 OUI 都是 6 位十六进制（写错格式会被解析器跳过，这里确保没被跳过）")
check(Set(keys).count == keys.count, "无重复键（重复键在字典字面量里会运行时崩溃）")

// 逐条格式校验：任何一条写成 5 位/含空格/非 hex，都会被解析器跳过。
// 通过「已知厂商的抽样命中」间接确认表没被写坏。
let samples: [(String, String)] = [
    ("00:1B:63:00:00:00", "Apple"),
    ("F0:C1:F1:11:22:33", "Apple"),
    ("24:0A:C4:01:02:03", "Espressif"),
    ("7C:9E:BD:AA:BB:CC", "Espressif"),
    ("1C:61:B4:00:11:22", "TP-Link"),
    ("04:CF:8C:33:44:55", "Xiaomi"),
    ("B8:27:EB:12:34:56", "RaspberryPi"),
    ("00:0E:58:99:88:77", "Sonos"),
    ("B0:A7:37:00:00:01", "Roku"),
    ("00:09:BF:00:00:02", "Nintendo"),
]
for (mac, vendor) in samples {
    check(DeviceIdentityResolver.vendor(forMAC: mac) == vendor, "\(mac) → \(vendor)")
}
check(DeviceIdentityResolver.vendor(forMAC: "02:11:22:33:44:55").isEmpty, "未收录 OUI → 空（未知）")

// ── 2. ARP 行解析 ─────────────────────────────────────────────────────
print("== ARP 解析 ==")
let real = DeviceIdentityResolver.parseARPLine("? (192.168.1.33) at 0:e0:4c:12:34:56 on en0 ifscope [ethernet]")
check(real?.ip == "192.168.1.33", "提取 IP")
check(real?.mac == "00:e0:4c:12:34:56", "MAC 去前导零并归一化（\(real?.mac ?? "nil")）")

let full = DeviceIdentityResolver.parseARPLine("? (192.168.1.33) at 00:e0:4c:12:34:56 on en0 ifscope [ethernet]")
check(full?.mac == "00:e0:4c:12:34:56", "完整 MAC 保持原样（小写）")

check(DeviceIdentityResolver.parseARPLine("? (192.168.1.40) at (incomplete) on en0 ifscope [ethernet]") == nil,
      "incomplete 条目 → nil（显示未知，不伪造）")
check(DeviceIdentityResolver.parseARPLine("? (fe80::1) at 0:e0:4c:12:34:56 on en0 [ethernet]") == nil,
      "IPv6 条目不解析")
check(DeviceIdentityResolver.parseARPLine("garbage") == nil, "异常行 → nil")
check(DeviceIdentityResolver.normalizeMAC("0:e0:4c:12:34:56") == "00:e0:4c:12:34:56", "去前导零")
check(DeviceIdentityResolver.normalizeMAC("00:00:00:00:00:00") == nil, "全零不是设备地址")
check(DeviceIdentityResolver.normalizeMAC("ff:ff:ff:ff:ff:ff") == nil, "广播不是设备地址")
check(DeviceIdentityResolver.normalizeMAC("00:e0:4c:68:1b") == nil, "缺段 → nil")
check(DeviceIdentityResolver.normalizeMAC("zz:e0:4c:12:34:56") == nil, "非 hex → nil")

// ── 3. 身份判定 ───────────────────────────────────────────────────────
print("== 身份判定 ==")
let apple = DeviceIdentityResolver.identify(mac: "00:1b:63:12:34:56")
check(apple.vendor == "Apple" && apple.deviceType == "Apple 设备", "Apple 设备")
check(apple.evidence == .vendor, "依据来自厂商")
check(apple.summary.hasSuffix("（推测）"), "展示带「推测」：\(apple.summary)")

let iot = DeviceIdentityResolver.identify(mac: "7c:9e:bd:12:34:56")
check(iot.deviceType == "IoT 设备", "Espressif → IoT")

let noMac = DeviceIdentityResolver.identify(mac: nil)
check(noMac.mac.isEmpty && noMac.vendor.isEmpty && noMac.deviceType.isEmpty, "拿不到 MAC 时三字段都空")
check(noMac.summary.isEmpty, "全未知时 summary 为空串（界面据此不显示这一行）")
check(noMac.evidence == .none, "依据为 none")

let badMac = DeviceIdentityResolver.identify(mac: "not-a-mac")
check(badMac.mac.isEmpty && badMac.summary.isEmpty, "非法 MAC 不产出身份")
check(badMac.evidence == .none, "非法 MAC → none")

// ── 4. 端口指纹兜底 ───────────────────────────────────────────────────
print("== 端口指纹 ==")
let mdns = DeviceIdentityResolver.identify(mac: "02:11:22:33:44:55", observedPorts: [5353])
check(mdns.deviceType == "家庭设备" && mdns.evidence == .port, "未知厂商 + mDNS → 家庭设备")
check(mdns.vendor.isEmpty, "端口指纹不编造厂商")

let ssdp = DeviceIdentityResolver.identify(mac: "", observedPorts: [1900])
check(ssdp.deviceType == "家庭设备", "SSDP 同样归家庭设备")

let apns = DeviceIdentityResolver.identify(mac: nil, observedPorts: [5223])
check(apns.deviceType == "Apple 设备" && apns.evidence == .port, "5223 → Apple 设备（端口证据）")

let gcm = DeviceIdentityResolver.identify(mac: nil, observedPorts: [5228])
check(gcm.deviceType == "Android 设备", "5228 → Android 设备")

check(DeviceIdentityResolver.identify(mac: nil, observedPorts: [443, 80]).deviceType.isEmpty,
      "常见 web 端口不作为指纹（不猜）")

// 厂商优先于端口：Apple 设备的 5353 不能把它降级成「家庭设备」
let appleWithMDNS = DeviceIdentityResolver.identify(mac: "00:1b:63:12:34:56", observedPorts: [5353])
check(appleWithMDNS.deviceType == "Apple 设备" && appleWithMDNS.evidence == .vendor,
      "厂商结论优先于端口指纹")

// ── 5. 地址判定 ──────────────────────────────────────────────────────
print("== 地址判定 ==")
check(DeviceIdentityResolver.isIPv4("192.168.1.1"), "合法 IPv4")
check(!DeviceIdentityResolver.isIPv4("192.168.1"), "缺段")
check(!DeviceIdentityResolver.isIPv4("256.1.1.1"), "越界")
check(!DeviceIdentityResolver.isIPv4("fe80::1"), "IPv6 不算 IPv4")

print("")
if failures == 0 { print("DeviceIdentity: 全部通过"); exit(0) }
print("DeviceIdentity: \(failures) 处失败"); exit(1)
