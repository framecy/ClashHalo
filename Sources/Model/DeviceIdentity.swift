import Foundation

// MARK: - 局域网设备身份（MAC / 厂商 / 类型）
//
// 纯逻辑：无 SwiftUI、无 MainActor、无进程调用、无文件读取，可单独编译进回归套件
// （`Tests/DeviceIdentity`，登记在 `Scripts/run-tests.sh`）。
//
// 网关模式下设备列表过去只有裸 IP，用户判断不了「要不要给这台设备放行」。
// 身份的三个来源与各自的可信度：
//   1. MAC —— `/usr/sbin/arp -an` 无需特权即可读，但**只含同网段最近通信过的设备**；
//      跨 VLAN / 三层网关后拿不到，必须如实显示「未知」，不能留空让人以为坏了。
//   2. 厂商 —— OUI 前 3 字节查内置表。IEEE 全量约 3.5 万条、CSV 约 2 MB，超出
//      「进包体」预算（文档要求先测体积，>500KB 就不该进包），因此只收消费级/IoT
//      常见厂商，其余归「未知厂商」。
//   3. 类型 —— 先看厂商白名单，再看连接目标端口指纹（mDNS/SSDP/APNs/GCM），
//      两者都没有就显示「未知」。**判不出不猜**。

struct DeviceIdentity: Equatable {
    /// 归一化 MAC（小写、每段两位），拿不到时为空串。
    let mac: String
    /// 厂商名，未知时为空串。
    let vendor: String
    /// 推测的设备类型（「手机」「IoT 设备」…），未知时为空串。
    let deviceType: String
    /// 类型判定的依据，用于界面上标注可信度。
    let evidence: Evidence

    enum Evidence: String, Equatable {
        case vendor      // 厂商白名单
        case port        // 目标端口指纹
        case none        // 判不出
    }

    /// 展示用一行：`Apple · Apple 设备（推测）`；全未知时返回空串。
    var summary: String {
        var parts: [String] = []
        // 类型已经含厂商名时不再重复（`Apple` + `Apple 设备` → `Apple 设备`）。
        if !vendor.isEmpty, !deviceType.hasPrefix(vendor) { parts.append(vendor) }
        if !deviceType.isEmpty { parts.append(deviceType) }
        else if !vendor.isEmpty { parts.append(vendor) }
        guard !parts.isEmpty else { return "" }
        let text = parts.joined(separator: " · ")
        return evidence == .none ? text : "\(text)（推测）"
    }
}

enum DeviceIdentityResolver {

    // MARK: - ARP 解析

    /// 解析 `/usr/sbin/arp -an` 的一行：
    /// `? (192.168.1.33) at 0:e0:4c:68:1b:e9 on en0 ifscope [ethernet]`
    /// 只认完整条目；`at (incomplete)`、IPv6、异常行一律返回 nil（如实显示未知）。
    static func parseARPLine(_ line: String) -> (ip: String, mac: String)? {
        guard let open = line.firstIndex(of: "("),
              let close = line[line.index(after: open)...].firstIndex(of: ")") else { return nil }
        let ip = String(line[line.index(after: open)..<close])
        guard isIPv4(ip), let atRange = line.range(of: " at ") else { return nil }
        let macRaw = line[atRange.upperBound...].prefix { $0 != " " }
        guard let mac = normalizeMAC(String(macRaw)) else { return nil }
        return (ip, mac)
    }

    /// `0:e0:4c:68:1b:e9` → `00:e0:4c:68:1b:e9`；不合法返回 nil。
    static func normalizeMAC(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var out: [String] = []
        out.reserveCapacity(6)
        for p in parts {
            guard !p.isEmpty, p.count <= 2, p.allSatisfy({ $0.isHexDigit }) else { return nil }
            out.append(p.count == 1 ? "0" + p.lowercased() : p.lowercased())
        }
        let mac = out.joined(separator: ":")
        // 全零/广播不是设备地址。
        guard mac != "00:00:00:00:00:00", mac != "ff:ff:ff:ff:ff:ff" else { return nil }
        return mac
    }

    /// OUI 前缀（前 3 字节，大写、无分隔）。
    static func oui(_ mac: String) -> String {
        mac.split(separator: ":").prefix(3).joined().uppercased()
    }

    // MARK: - 厂商表

    /// 常见消费级 / IoT 厂商 OUI（前 3 字节，大写、无分隔）。
    ///
    /// **刻意保持小而稳定**：这是数据资产，不随版本频繁更新；未收录一律「未知厂商」。
    /// 用文本表而不是字典字面量：字典字面量里出现重复键会在**运行时崩溃**，而这是
    /// 一份手写的长列表——文本表在解析时校验格式，写错一条最多是查不到，不会崩。
    /// 体积约 7 KB 源码（IEEE 全量约 3.5 万条 / 约 2 MB，不满足进包体预算）。
    private static let ouiSource = """
001B63 Apple
001CB3 Apple
001E52 Apple
0021E9 Apple
002312 Apple
002500 Apple
0026B0 Apple
003065 Apple
0050E4 Apple
006D52 Apple
0080C8 Apple
0090B1 Apple
00A040 Apple
00C610 Apple
00F4B9 Apple
040CCE Apple
041E64 Apple
04489A Apple
04D3CF Apple
04F13E Apple
04F7E4 Apple
086D41 Apple
087045 Apple
089E01 Apple
08E689 Apple
0C1539 Apple
0C3021 Apple
0C4DE9 Apple
0C5101 Apple
0C74C2 Apple
0C771A Apple
0CBC9F Apple
101C0C Apple
103025 Apple
10417F Apple
1093E9 Apple
109ADD Apple
10DDB1 Apple
14109F Apple
145A05 Apple
148FC6 Apple
1499E2 Apple
14BD61 Apple
18AF61 Apple
18E7F4 Apple
18EE69 Apple
18F643 Apple
1C1AC0 Apple
1C36BB Apple
1C5CF2 Apple
1C9148 Apple
1CABA7 Apple
1CE62B Apple
206980 Apple
207D74 Apple
209BCD Apple
20A2E4 Apple
20C9D0 Apple
24A074 Apple
24AB81 Apple
24E314 Apple
24F094 Apple
28CFDA Apple
28E02C Apple
28E7CF Apple
28ED6A Apple
28F076 Apple
2C1F23 Apple
2C200B Apple
2C3361 Apple
2C61F6 Apple
2CB43A Apple
2CF0A2 Apple
2CF0EE Apple
3010E4 Apple
3035AD Apple
30636B Apple
3090AB Apple
30F7C5 Apple
34363B Apple
34A395 Apple
34C059 Apple
34E2FD Apple
380F4A Apple
38484C Apple
3871DE Apple
38B54D Apple
38C986 Apple
38CA84 Apple
3C0754 Apple
3C15C2 Apple
3C2EF9 Apple
3CAB8E Apple
3CD0F8 Apple
3CE072 Apple
400E85 Apple
40331A Apple
406C8F Apple
4098AD Apple
40A6D9 Apple
40B395 Apple
40D32D Apple
441400 Apple
442A60 Apple
448500 Apple
44D884 Apple
44FB42 Apple
483B38 Apple
48437C Apple
48746E Apple
48A195 Apple
48BF6B Apple
48D705 Apple
48E9CA Apple
4C3275 Apple
4C57CA Apple
4C74BF Apple
4C8D79 Apple
4CB199 Apple
503237 Apple
5C95AE Apple
5CF5DA Apple
5CF938 Apple
601AC7 Apple
60FACD Apple
60FB42 Apple
64B9E8 Apple
64E682 Apple
685B35 Apple
68644B Apple
68A86D Apple
68AE20 Apple
68D93C Apple
6C3E6D Apple
6C4008 Apple
6C709F Apple
6C94F8 Apple
70A2B3 Apple
70CD60 Apple
70DEE2 Apple
70ECE4 Apple
741BB2 Apple
7476AA Apple
748114 Apple
74B587 Apple
74E1B6 Apple
74E2F5 Apple
780F77 Apple
7831C1 Apple
783A84 Apple
786C1C Apple
787B8A Apple
78A3E4 Apple
78CA39 Apple
78D75F Apple
78FD94 Apple
7C11BE Apple
7C6D62 Apple
7C6DF8 Apple
7CC3A1 Apple
7CC537 Apple
7CD1C3 Apple
7CF05F Apple
7CFADF Apple
80006E Apple
80929F Apple
80BE05 Apple
80E650 Apple
80EA96 Apple
84038D Apple
848506 Apple
84FCFE Apple
885395 Apple
8863DF Apple
886B6E Apple
88C663 Apple
88E87F Apple
8C006D Apple
8C2937 Apple
8C2DAA Apple
8C7B9D Apple
8C7C92 Apple
8C8590 Apple
8CFABE Apple
9027E4 Apple
9060F1 Apple
90840D Apple
90B0ED Apple
90B21F Apple
90C1C6 Apple
90FD61 Apple
94E96A Apple
94F6A3 Apple
9803D8 Apple
985B4A Apple
989E63 Apple
98B8E3 Apple
98D6BB Apple
98E0D9 Apple
98F0AB Apple
98FE94 Apple
9C04EB Apple
9C207B Apple
9C293F Apple
9C35EB Apple
9C4FDA Apple
9C84BF Apple
9CE65E Apple
9CF387 Apple
9CFC01 Apple
A01828 Apple
A03BE3 Apple
A0999B Apple
A0D795 Apple
A0EDCD Apple
A45E60 Apple
A46706 Apple
A4B197 Apple
A4C361 Apple
A4D18C Apple
A4D1D2 Apple
A4F1E8 Apple
A82066 Apple
A860B6 Apple
A8667F Apple
A86B7C Apple
A886DD Apple
A88808 Apple
A8BB56 Apple
A8C222 Apple
AC293A Apple
AC61EA Apple
AC7F3E Apple
AC87A3 Apple
ACBC32 Apple
ACCF85 Apple
ACE4B5 Apple
ACFD1C Apple
B03495 Apple
B065BD Apple
B09FBA Apple
B0CA68 Apple
B0F1EC Apple
B418D1 Apple
B44BD2 Apple
B49CDF Apple
B4F0AB Apple
B8098A Apple
B817C2 Apple
B844D9 Apple
B853AC Apple
B8782E Apple
B88D12 Apple
B8BEA8 Apple
B8C111 Apple
B8C75D Apple
B8E856 Apple
B8F6B1 Apple
B8FF61 Apple
BC3BAF Apple
BC52B7 Apple
BC6778 Apple
BC6C21 Apple
BC926B Apple
BC9FEF Apple
BCA920 Apple
BCD1D3 Apple
BCE143 Apple
C01ADA Apple
C06394 Apple
C0847A Apple
C0CEF3 Apple
C0D012 Apple
C0F2FB Apple
C42C03 Apple
C475AB Apple
C4B301 Apple
C81EE7 Apple
C82A14 Apple
C8334B Apple
C86000 Apple
C869CD Apple
C86F1D Apple
C88550 Apple
C8B5B7 Apple
C8BC53 Apple
C8D083 Apple
C8E0EB Apple
C8F650 Apple
CC08E0 Apple
CC25EF Apple
CC29F5 Apple
CC4463 Apple
CC785F Apple
CC88C7 Apple
CCC760 Apple
D0034B Apple
D023DB Apple
D02598 Apple
D0497C Apple
D0A637 Apple
D0C5F3 Apple
D0E140 Apple
D4DCCD Apple
D4F46F Apple
D8004D Apple
D81D72 Apple
D83062 Apple
D8A25E Apple
D8BB2C Apple
D8CF9C Apple
D8D1CB Apple
D8DE3A Apple
DC0C5C Apple
DC2B2A Apple
DC3714 Apple
DC415F Apple
DC52A3 Apple
DC86D8 Apple
DC9B9C Apple
DCA4CA Apple
DCA904 Apple
DCE1AD Apple
E04F43 Apple
E05F45 Apple
E0ACCB Apple
E0B52D Apple
E0B9BA Apple
E0C767 Apple
E0C97A Apple
E0D173 Apple
E0F5C6 Apple
E0F847 Apple
E425E7 Apple
E44246 Apple
E4509A Apple
E498D6 Apple
E4C63D Apple
E4CE8F Apple
E4E4AB Apple
E4F365 Apple
E8040B Apple
E80688 Apple
E80B6C Apple
E8802E Apple
E88D28 Apple
E89218 Apple
E8B2AC Apple
E8B4C8 Apple
EC3586 Apple
EC852F Apple
ECADB8 Apple
F02475 Apple
F0766F Apple
F0B479 Apple
F0B0E7 Apple
F0C1F1 Apple
F0CBD8 Apple
F0D1A9 Apple
F0DBE2 Apple
F0DCE2 Apple
F0F61C Apple
F40616 Apple
F437B7 Apple
F45C89 Apple
F4F15A Apple
F4F951 Apple
F81EDF Apple
F82793 Apple
F86214 Apple
F895EA Apple
F8FFC2 Apple
FC253F Apple
FC2A9C Apple
FC3F7C Apple
FC9965 Apple
FCC734 Apple
FCE998 Apple
FCFC48 Apple
240AC4 Espressif
246F28 Espressif
2C3AE8 Espressif
30AEA4 Espressif
3C6105 Espressif
3C71BF Espressif
48E729 Espressif
4CEBD6 Espressif
540F57 Espressif
5CCF7F Espressif
600194 Espressif
68C63A Espressif
7C9EBD Espressif
807D3A Espressif
84CC0C Espressif
84F3EB Espressif
8CAAB5 Espressif
A020A6 Espressif
A4CF12 Espressif
B4E62D Espressif
BCDDC2 Espressif
C44F33 Espressif
CC50E3 Espressif
D8F15B Espressif
DC4F22 Espressif
ECFA5C Espressif
F008D1 Espressif
F4CFA2 Espressif
001D0F TP-Link
003192 TP-Link
14CC20 TP-Link
1C61B4 TP-Link
34E894 TP-Link
50C7BF TP-Link
60E327 TP-Link
6466B3 TP-Link
704F57 TP-Link
98DAC4 TP-Link
A42BB0 TP-Link
B0BE76 TP-Link
C46E1F TP-Link
C4E984 TP-Link
04CF8C Xiaomi
34CE00 Xiaomi
50E24E Xiaomi
64B473 Xiaomi
78110C Xiaomi
8CBEBE Xiaomi
F0F336 Xiaomi
F8A45F Xiaomi
001A11 Google
3C5AB4 Google
54FCE3 Google
94EB2C Google
A47733 Google
F4F5D8 Google
0012FB Samsung
2C4402 Samsung
34AA8B Samsung
5001BB Samsung
78BDBC Samsung
8C7712 Samsung
AC5A14 Samsung
D0176A Samsung
E8E5D6 Samsung
001BFC Intel
001E64 Intel
0024D7 Intel
3C9509 Intel
4851B7 Intel
7CB27D Intel
94C691 Intel
B49691 Intel
B8AEED Intel
E4A471 Intel
00E04C Realtek
52D4AA Realtek
00095B Netgear
20E52A Netgear
A040A0 Netgear
001E58 D-Link
0050BA D-Link
1CBDB9 D-Link
B827EB RaspberryPi
DCA632 RaspberryPi
E45F01 RaspberryPi
2CCF67 RaspberryPi
000E58 Sonos
5CAAFD Sonos
78285A Sonos
949F3E Sonos
B8E937 Sonos
B0A737 Roku
CC6DA0 Roku
DC3A5E Roku
D83134 Roku
0009BF Nintendo
58BDA3 Nintendo
98B6E9 Nintendo
78A2A0 Nintendo
001DBA Sony
0013A9 Sony
FCF152 Sony
30F9ED Sony
0C47C9 Amazon
44650D Amazon
68544F Amazon
74C246 Amazon
F0272D Amazon
18B430 Nest
001788 Philips
001132 Synology
0090A9 WesternDigital
001A8C HonHai
001565 Yealink
"""

    /// 厂商名兜底可读化：表里用无空格的英文名，展示时不额外加空格。
    private static let ouiTable: [String: String] = {
        var map: [String: String] = [:]
        for line in ouiSource.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).uppercased()
            // 手写长表难免打错：格式不对就跳过（查不到 = 显示未知），绝不让它崩。
            guard key.count == 6, key.allSatisfy({ $0.isHexDigit }) else { continue }
            map[key] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return map
    }()

    /// 表内条目数，供回归套件断言表没有在编辑中被写坏。
    static var ouiEntryCount: Int { ouiTable.count }

    /// 表内全部 OUI 键（只读）。套件用它断言「每条都是 6 位 hex 且不重复」——
    /// 手写长表最怕的是重复键，而字典字面量的重复键会直接崩在运行时。
    static var ouiKeys: [String] { Array(ouiTable.keys) }

    static func vendor(forMAC mac: String) -> String {
        ouiTable[oui(mac)] ?? ""
    }

    // MARK: - 类型

    /// 厂商 → 类型。**只能给到「这一类设备里最可能的那种」**，所以展示必须带「推测」。
    /// 共用同一批 OUI 的厂商（Apple 的 Mac/iPhone/HomePod）不硬分。
    private static func typeFromVendor(_ vendor: String) -> String {
        switch vendor {
        case "Apple": return "Apple 设备"
        case "Espressif": return "IoT 设备"
        case "TP-Link", "Netgear", "D-Link": return "路由器"
        case "Xiaomi", "Google", "Nest", "Amazon": return "智能家居"
        case "Samsung", "Sony", "Roku": return "影音设备"
        case "Nintendo": return "游戏机"
        case "Sonos": return "音箱"
        case "Intel", "Realtek", "HonHai": return "电脑"
        case "RaspberryPi": return "单板机"
        case "Synology", "WesternDigital": return "NAS"
        case "Philips": return "智能灯"
        case "Yealink": return "话机"
        default: return ""
        }
    }

    /// 端口指纹 → 类型。只认有明确含义的端口，别的不猜。
    /// - 5223 APNs → Apple 设备；5228 GCM/FCM → Android
    /// - 7680 Windows 更新 → 电脑
    /// - 5353 mDNS / 1900 SSDP → 家庭网络设备
    private static func typeFromPorts(_ ports: Set<Int>) -> String {
        if ports.contains(5223) { return "Apple 设备" }
        if ports.contains(5228) { return "Android 设备" }
        if ports.contains(7680) { return "Windows 电脑" }
        if ports.contains(5353) || ports.contains(1900) { return "家庭设备" }
        return ""
    }

    /// 组合判定。`observedPorts` 是该设备最近观察到的目标端口（聚合热路径收集）。
    static func identify(mac: String?, observedPorts: Set<Int> = []) -> DeviceIdentity {
        let normalized = mac.flatMap { normalizeMAC($0) } ?? ""
        let v = normalized.isEmpty ? "" : vendor(forMAC: normalized)

        if !v.isEmpty {
            return DeviceIdentity(mac: normalized, vendor: v,
                                  deviceType: typeFromVendor(v), evidence: .vendor)
        }
        let t = typeFromPorts(observedPorts)
        if !t.isEmpty {
            return DeviceIdentity(mac: normalized, vendor: "", deviceType: t, evidence: .port)
        }
        return DeviceIdentity(mac: normalized, vendor: "", deviceType: "", evidence: .none)
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in !p.isEmpty && Int(p).map { (0...255).contains($0) } == true }
    }
}
