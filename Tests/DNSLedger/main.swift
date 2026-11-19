// 系统 DNS 重定向台账回归套件：钉住 TunnelDNSLedger 的 5 条不变量、TUN-4 接管失败回滚，
// 以及 TUNDNSAddress.shouldSweepResidueOn 的逐地址取证语义。
// 直接编译生产源码（TunnelDNSLedger.swift + TUNDNSAddress.swift + StubDriver.swift）。
import Foundation

final class InMemoryLedgerStore: DNSLedgerStore {
    var strings: [String: String] = [:]
    var bools: [String: Bool] = [:]

    func string(forKey key: String) -> String? { strings[key] }
    func bool(forKey key: String) -> Bool { bools[key] ?? false }
    func setString(_ value: String?, forKey key: String) {
        if let value { strings[key] = value } else { strings.removeValue(forKey: key) }
    }
    func setBool(_ value: Bool, forKey key: String) {
        bools[key] = value
    }
}

final class MockDNSDriver: SystemDNSDriving {
    var defaultSvc: String? = "Wi-Fi"
    /// service -> [String]?（nil 表示读取失败；[] 表示 Empty）
    var dnsByService: [String: [String]?] = ["Wi-Fi": ["192.168.1.1"]]
    /// 自定义写入钩子（返回 true/false，并可观察写入前 pending 状态）
    var onApply: (([String], String?) -> Bool)?
    var appliedCalls: [(servers: [String], service: String?)] = []

    func currentDNS(service: String?) async -> [String]? {
        let key = service ?? defaultSvc ?? ""
        if let val = dnsByService[key] { return val }
        return nil
    }

    @discardableResult
    func applyDNS(_ servers: [String], service: String?) async -> Bool {
        appliedCalls.append((servers, service))
        if let onApply { return onApply(servers, service) }
        if let svc = service ?? defaultSvc {
            dnsByService[svc] = (servers == ["Empty"]) ? [] : servers
        }
        return true
    }

    func defaultService() async -> String? { defaultSvc }
}

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

Task {
    var logs: [String] = []
    let sink: (String) -> Void = { logs.append($0) }

    func resetEnv() -> (InMemoryLedgerStore, MockDNSDriver) {
        let store = InMemoryLedgerStore()
        let driver = MockDNSDriver()
        TunnelDNSLedger.store = store
        TunnelDNSLedger.driver = driver
        TunnelDNSLedger.logSink = sink
        logs.removeAll()
        return (store, driver)
    }

    print("── 0. DNSLedgerCodec 编解码与防污染净化 ──")
    checkEq(DNSLedgerCodec.encode([]), "Empty", "空列表编码为 Empty 哨兵（区分快照缺失空串）")
    checkEq(DNSLedgerCodec.encode([" 1.1.1.1 ", "", "8.8.8.8"]), "1.1.1.1,8.8.8.8", "去空白后逗号拼接")
    checkEq(DNSLedgerCodec.decode(""), ["Empty"], "缺失快照解码回 Empty（回退 DHCP）")
    checkEq(DNSLedgerCodec.decode("Empty"), ["Empty"], "Empty 哨兵解码为 [\"Empty\"]")
    checkEq(DNSLedgerCodec.decode("1.1.1.1, 8.8.8.8"), ["1.1.1.1", "8.8.8.8"], "多 DNS 解码")
    checkEq(DNSLedgerCodec.sanitizedRestoreTarget(fromSnapshot: "198.18.0.1,198.19.0.1"), ["Empty"],
            "被 fake-ip 污染的快照净化后回退 Empty")
    checkEq(DNSLedgerCodec.sanitizedRestoreTarget(fromSnapshot: "198.18.0.1,223.5.5.5"), ["223.5.5.5"],
            "混合快照仅剔除 fake-ip、保留真实 DNS")

    print("── 1. 不变量 2：三态读取（nil 放弃、[] 存 Empty、剔除 fake-ip）──")
    do {
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = nil
        let ok = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(!ok, "currentDNS == nil 时放弃重定向（不把读取失败当 Empty）")
        check(driver.appliedCalls.isEmpty, "读取失败时绝不调用 applyDNS")
        check(TunnelDNSLedger.record(for: .tun) == nil, "读取失败时不留账本记录")
    }
    do {
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = []
        let ok = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(ok, "currentDNS == []（合法 DHCP 空值）允许重定向")
        checkEq(TunnelDNSLedger.record(for: .tun)?.snapshot, "Empty", "空列表快照落盘为 Empty")
    }
    do {
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = ["198.18.0.0", "10.10.0.1"]
        let ok = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(ok, "读取到残留 fake-ip 时仍可重定向")
        checkEq(TunnelDNSLedger.record(for: .tun)?.snapshot, "10.10.0.1",
                "快照自动剔除 198.18.0.0，只留真实 DNS")
    }

    print("── 2. 不变量 3：pending → committed 两段式与写失败回滚 ──")
    do {
        let (store, driver) = resetEnv()
        var sawPendingDuringWrite = false
        var sawCommittedDuringWrite = true
        driver.onApply = { _, _ in
            sawPendingDuringWrite = store.bool(forKey: DNSRedirectOwner.tun.pendingKey)
            sawCommittedDuringWrite = store.bool(forKey: DNSRedirectOwner.tun.overriddenKey)
            return true
        }
        let ok = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(ok, "写入成功返回 true")
        check(sawPendingDuringWrite && !sawCommittedDuringWrite,
              "applyDNS 执行瞬间账本处于 pending=true, committed=false")
        check(TunnelDNSLedger.isActive(.tun) && !store.bool(forKey: DNSRedirectOwner.tun.pendingKey),
              "写入确认后转正为 committed=true, pending=false")
    }
    do {
        let (_, driver) = resetEnv()
        driver.onApply = { _, _ in false }
        let ok = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(!ok, "applyDNS 返回 false 时 redirect 返回 false")
        check(TunnelDNSLedger.record(for: .tun) == nil, "写失败立即回滚删除 pending 账本（不留有账无写）")
    }

    print("── 3. 不变量 1 & TUN-4：属主隔离、接管继承原快照与接管失败保护 ──")
    do {
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = ["10.0.0.1"]
        _ = await TunnelDNSLedger.redirect(owner: .proxy, servers: ["127.0.0.1"], log: sink)
        checkEq(TunnelDNSLedger.record(for: .proxy)?.snapshot, "10.0.0.1", "proxy 属主记下最初快照 10.0.0.1")

        // TUN-4：TUN 接管 proxy 时写入失败，proxy 原账本与快照绝不能被清掉
        driver.onApply = { _, _ in false }
        let failTakeover = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(!failTakeover, "TUN 接管写入失败返回 false")
        check(TunnelDNSLedger.record(for: .tun) == nil, "接管失败后 tun 不留账")
        checkEq(TunnelDNSLedger.record(for: .proxy)?.snapshot, "10.0.0.1",
                "★ TUN-4：接管失败时原 proxy 账本与快照完好保留")

        // 恢复写入成功：TUN 接管并继承 10.0.0.1（而非 127.0.0.1），随后清除 proxy 账本
        driver.onApply = nil
        let okTakeover = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(okTakeover, "TUN 接管写入成功")
        checkEq(TunnelDNSLedger.record(for: .tun)?.snapshot, "10.0.0.1",
                "★ TUN 接管继承最初快照 10.0.0.1（而非 127.0.0.1）")
        check(TunnelDNSLedger.record(for: .proxy) == nil, "接管确认成功后清除原 proxy 账本")
    }
    do {
        // 不同服务上的双属主互不覆盖
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = ["10.0.0.1"]
        driver.dnsByService["Ethernet"] = ["172.16.0.1"]
        _ = await TunnelDNSLedger.redirect(owner: .proxy, servers: ["127.0.0.1"], service: "Wi-Fi", log: sink)
        _ = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], service: "Ethernet", log: sink)
        checkEq(TunnelDNSLedger.record(for: .proxy)?.service, "Wi-Fi", "不同服务下 proxy 账本保留")
        checkEq(TunnelDNSLedger.record(for: .tun)?.service, "Ethernet", "不同服务下 tun 账本独立")
        checkEq(TunnelDNSLedger.activeOwners().count, 2, "activeOwners 报告两属主同时在账")
    }

    print("── 4. 不变量 4：恢复失败保留账本、服务回退与 restoreAll 不短路 ──")
    do {
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = ["223.5.5.5"]
        _ = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)

        driver.onApply = { _, _ in false }
        let r1 = await TunnelDNSLedger.restore(owner: .tun, log: sink)
        check(!r1, "恢复写入失败返回 false")
        check(TunnelDNSLedger.record(for: .tun) != nil, "★ 恢复失败保留账本待重试（杜绝退出路径失忆）")

        // 原 pin 服务不可用时回退当前默认服务
        driver.onApply = { _, svc in svc == nil }
        let r2 = await TunnelDNSLedger.restore(owner: .tun, log: sink)
        check(r2, "原服务写入失败时回退默认服务（service=nil）成功")
        check(TunnelDNSLedger.record(for: .tun) == nil, "恢复确认成功后才清账")
    }
    do {
        // restoreAll 不短路：tun 失败时 proxy 仍继续恢复
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = ["10.0.0.1"]
        driver.dnsByService["Ethernet"] = ["172.16.0.1"]
        _ = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], service: "Ethernet", log: sink)
        _ = await TunnelDNSLedger.redirect(owner: .proxy, servers: ["127.0.0.1"], service: "Wi-Fi", log: sink)
        driver.onApply = { _, svc in svc == "Wi-Fi" }
        let allOK = await TunnelDNSLedger.restoreAll(log: sink)
        check(!allOK, "部分属主还原失败时 restoreAll 返回 false")
        check(TunnelDNSLedger.record(for: .tun) != nil, "失败的 tun 账本保留")
        check(TunnelDNSLedger.record(for: .proxy) == nil, "★ restoreAll 不短路：成功的 proxy 已还原并清账")
    }

    print("── 5. 不变量 5：服务漂移自愈（Wi-Fi → Ethernet）──")
    do {
        let (_, driver) = resetEnv()
        driver.dnsByService["Wi-Fi"] = ["10.0.0.1"]
        driver.dnsByService["Ethernet"] = ["192.168.50.1"]
        driver.defaultSvc = "Wi-Fi"
        _ = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        driver.appliedCalls.removeAll()

        driver.defaultSvc = "Ethernet"
        let ok = await TunnelDNSLedger.redirect(owner: .tun, servers: ["198.18.0.1"], log: sink)
        check(ok, "默认服务漂移后重新重定向成功")
        checkEq(driver.appliedCalls.count, 2, "服务漂移触发两次写：先还旧服务、再写新服务")
        checkEq(driver.appliedCalls.first?.service, "Wi-Fi", "先还原旧服务 Wi-Fi")
        checkEq(driver.appliedCalls.first?.servers, ["10.0.0.1"], "旧服务按原快照 10.0.0.1 还原")
        checkEq(TunnelDNSLedger.record(for: .tun)?.service, "Ethernet", "新账本 pin 到 Ethernet")
        checkEq(TunnelDNSLedger.record(for: .tun)?.snapshot, "192.168.50.1", "新账本快照为 Ethernet 原值")
    }

    print("── 6. shouldSweepResidueOn 逐地址取证（审查中-2）──")
    check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: false, isDefaultService: false,
                                             otherTunnelIsUp: true, residueRoutedIntoOtherTunnel: false) == true,
          "★ 共存隧道 UP 但残留未路由进对方隧道 → 照清（中-2 修复点）")
    check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: false, isDefaultService: false,
                                             otherTunnelIsUp: true, residueRoutedIntoOtherTunnel: true) == false,
          "共存隧道 UP 且残留确实路由进对方隧道 → 跳过不误伤")
    check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: false, isDefaultService: false,
                                             otherTunnelIsUp: true, residueRoutedIntoOtherTunnel: nil) == false,
          "未做逐地址取证（nil）时保持保守跳过")
    check(TUNDNSAddress.shouldSweepResidueOn(hasProvenance: true, isDefaultService: false,
                                             otherTunnelIsUp: true, residueRoutedIntoOtherTunnel: true) == true,
          "有来源证据时无论共存状态一律清理")

    print("")
    if failed == 0 {
        print("全部通过（\(total) 项）")
        exit(0)
    } else {
        print("失败 \(failed)/\(total) 项")
        exit(1)
    }
}
dispatchMain()
