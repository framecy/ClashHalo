// 网关 DNS 体检纯逻辑回归：钉住 GatewayDNSCheck.evaluate 与 allowsKernelReload 白名单。
// 2026-11-08 事故：App 内 fork netstat 输出 0 字节导致每次启动白重载 2 次内核。
// 本套件钉住两条核心原则：① 探测不到只报告、绝不重载；② 只有 declarationDrift 允许重载。
import Foundation

var total = 0
var failed = 0

func check(_ cond: Bool, _ name: String) {
    total += 1
    if cond {
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name)")
    }
}

func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    total += 1
    if got == want {
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name) — got \(got), want \(want)")
    }
}

let lanA = "192.168.1.10"
let lanB = "10.0.0.20"

print("── 1. 声明漂移（唯一允许重载内核的分支）──")
do {
    let v1 = GatewayDNSCheck.evaluate(allowLan: false, dnsListen: kGatewayDNSListen,
                                      lan: [.init(address: lanA, outcome: .valid)], loopback: .valid)
    checkEq(v1, .declarationDrift(allowLan: false, dnsListen: kGatewayDNSListen),
            "allow-lan=false → declarationDrift（即使探测成功也以声明优先）")
    check(v1.allowsKernelReload, "declarationDrift 允许重载内核")
    check(!v1.isHealthy, "declarationDrift 不算健康")

    let v2 = GatewayDNSCheck.evaluate(allowLan: true, dnsListen: "127.0.0.1:1053",
                                      lan: [.init(address: lanA, outcome: .never)], loopback: .never)
    checkEq(v2, .declarationDrift(allowLan: true, dnsListen: "127.0.0.1:1053"),
            "dns.listen 非 0.0.0.0:53 → declarationDrift")
    check(v2.allowsKernelReload, "dns.listen 漂移允许重载内核")

    let v3 = GatewayDNSCheck.evaluate(allowLan: true, dnsListen: nil, lan: [], loopback: .never)
    checkEq(v3, .declarationDrift(allowLan: true, dnsListen: nil),
            "dns.listen 缺失 → declarationDrift")
    check(v3.allowsKernelReload, "dns.listen 缺失允许重载内核")
}

print("── 2. 无可探测局域网地址（undetermined）──")
do {
    let v = GatewayDNSCheck.evaluate(allowLan: true, dnsListen: kGatewayDNSListen,
                                     lan: [], loopback: .valid)
    if case .undetermined = v {
        check(true, "lan 为空 → undetermined")
    } else {
        check(false, "lan 为空应返回 undetermined，实际 \(v)")
    }
    check(!v.allowsKernelReload, "★ undetermined 绝不允许重载内核")
    check(!v.isHealthy, "undetermined 不算健康")
}

print("── 3. 健康判定（只认 NOERROR / .valid）──")
do {
    let v = GatewayDNSCheck.evaluate(
        allowLan: true,
        dnsListen: kGatewayDNSListen,
        lan: [.init(address: lanA, outcome: .valid)],
        loopback: .valid
    )
    checkEq(v, .healthy(lanAddresses: [lanA]), "单 LAN 地址 NOERROR → healthy")
    check(v.isHealthy, "isHealthy == true")
    check(!v.allowsKernelReload, "healthy 不重载内核")

    let vMulti = GatewayDNSCheck.evaluate(
        allowLan: true,
        dnsListen: kGatewayDNSListen,
        lan: [.init(address: lanA, outcome: .never), .init(address: lanB, outcome: .valid)],
        loopback: .never
    )
    checkEq(vMulti, .healthy(lanAddresses: [lanB]), "多网卡中任一 LAN 地址 NOERROR 即健康，并仅列应答地址")
    check(vMulti.isHealthy && !vMulti.allowsKernelReload, "多网卡部分应答健康且不重载")
}

print("── 4. 无 NOERROR 应答（lanUnanswered：只报告、绝不重载）──")
do {
    // 场景 A：回环正常但 LAN 超时（监听范围或端口占用）
    let v1 = GatewayDNSCheck.evaluate(
        allowLan: true,
        dnsListen: kGatewayDNSListen,
        lan: [.init(address: lanA, outcome: .never)],
        loopback: .valid
    )
    checkEq(v1, .lanUnanswered(lanAddresses: [lanA], gotReply: false, loopbackAnswered: true),
            "LAN 超时 + 回环 NOERROR → gotReply=false, loopbackAnswered=true")
    check(!v1.allowsKernelReload, "★ LAN 无应答绝不允许重载内核（重载修不了端口占用）")
    check(!v1.isHealthy, "lanUnanswered 不算健康")

    // 场景 B：LAN 与回环均超时（内核 DNS 未起或被占用）
    let v2 = GatewayDNSCheck.evaluate(
        allowLan: true,
        dnsListen: kGatewayDNSListen,
        lan: [.init(address: lanA, outcome: .never), .init(address: lanB, outcome: .never)],
        loopback: .never
    )
    checkEq(v2, .lanUnanswered(lanAddresses: [lanA, lanB], gotReply: false, loopbackAnswered: false),
            "双双超时 → gotReply=false, loopbackAnswered=false")
    check(!v2.allowsKernelReload, "★ 全超时同样不允许重载内核")

    // 场景 C：收到 SERVFAIL/NXDOMAIN（.refused）不算健康，归因 gotReply=true
    let v3 = GatewayDNSCheck.evaluate(
        allowLan: true,
        dnsListen: kGatewayDNSListen,
        lan: [.init(address: lanA, outcome: .refused)],
        loopback: .refused
    )
    checkEq(v3, .lanUnanswered(lanAddresses: [lanA], gotReply: true, loopbackAnswered: false),
            "★ SERVFAIL/NXDOMAIN(.refused) 不算健康，且标记 gotReply=true")
    check(!v3.isHealthy && !v3.allowsKernelReload, "refused 不健康且不触发重载")

    // 场景 D：malformed / mismatch 也不算健康，但标记有字节回包
    let v4 = GatewayDNSCheck.evaluate(
        allowLan: true,
        dnsListen: kGatewayDNSListen,
        lan: [.init(address: lanA, outcome: .malformed)],
        loopback: .valid
    )
    checkEq(v4, .lanUnanswered(lanAddresses: [lanA], gotReply: true, loopbackAnswered: true),
            "malformed 标记 gotReply=true 且不算健康")
    check(!v4.allowsKernelReload, "malformed 不触发重载")
}

print("")
if failed == 0 {
    print("全部通过（\(total) 项）")
} else {
    print("失败 \(failed)/\(total) 项")
    exit(1)
}
