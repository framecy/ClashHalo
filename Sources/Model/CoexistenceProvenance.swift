import Foundation

// MARK: - Coexistence provenance
//
// Which `route-exclude-address` / `fake-ip-filter` entries this app injected,
// and therefore which ones it is allowed to take back.
//
// Split out of `Coexistence` so the regression suite can compile the real rules
// (see `Scripts/run-tests.sh`). `Coexistence` itself reaches SwiftUI through
// `Models.swift`, and a rule this easy to get wrong should not be untestable
// because of a view dependency. Everything here is pure apart from the
// `UserDefaults` record, and depends only on `HelperProtocol.swift`.
//
// The rule this file exists to get right: *record what you added, not what you
// wanted*. Claiming the whole desired plan silently relabels the user's own
// entries as ours, and the next teardown deletes them.

public enum CoexistenceProvenance {
    private static let provenanceKeyPrefix = "coexistence.injected."

    /// Merge `desired` into `existing` for `field`, dropping entries this app
    /// injected on a previous pass that are no longer wanted, while never
    /// touching entries the user wrote themselves.
    ///
    /// Without the withdrawal half, a VPN that disconnects leaves its prefixes
    /// excluded from TUN forever — traffic silently keeps bypassing the proxy for
    /// a network that is gone, and the config accretes junk no one can attribute.
    ///
    /// Pure with respect to the provenance record: computing a merge must not
    /// claim the entries were applied. Call `commitProvenance` once the kernel
    /// has actually accepted them.
    static func mergePreservingUserEntries(field: String,
                                           desired: [String],
                                           in existing: [String]) -> [String] {
        let previouslyInjected = Set(injectedRecord(field))
        // Anything present that we did not inject last time is the user's — and
        // a protective exclusion is never ours to drop whatever the record says.
        let userOwned = existing.filter {
            !previouslyInjected.contains($0) || isProtectiveExclusion($0)
        }
        return Array(Set(userOwned + desired)).sorted()
    }

    /// A `route-exclude-address` entry that must survive every withdrawal pass.
    ///
    /// Provenance is only as trustworthy as the version that wrote it. A build
    /// that wrongly claimed `224.0.0.0/4` — as the pre-guard coexistence code did
    /// — leaves a record asserting the user's own multicast exclusion belongs to
    /// this app, and the next withdrawal then deletes it. Observed exactly that:
    /// the entry vanished from the running config and mihomo's auto-route
    /// promptly swallowed multicast into its own TUN.
    ///
    /// The asymmetry justifies the special case. Keeping a protective exclusion
    /// that is no longer needed costs nothing — it only tells mihomo to leave
    /// alone a range it should never have taken. Dropping one breaks the local
    /// segment. When the record and the rule disagree about these, the rule wins.
    static func isProtectiveExclusion(_ cidr: String) -> Bool {
        PeerRouteGuard.linkOnlyPrefixes.contains { RouteTable.overlaps(cidr, $0) }
    }

    /// The subset of `desired` that was not already in `existingBefore` — i.e.
    /// what this injection actually *added*, and therefore the only thing it may
    /// ever withdraw.
    ///
    /// Provenance used to be committed as the whole plan, which quietly claimed
    /// every entry the user had already written by hand and the plan happened to
    /// agree with. That is not a corner case: the Tailscale vendor entry emits
    /// `100.64.0.0/10`, the exact string any Tailscale user puts in their own
    /// `route-exclude-address`. One TUN off/on cycle was enough to relabel it as
    /// ours, and the following teardown deleted it — CGNAT then fell into
    /// auto-route and Tailscale traffic went into the wrong tunnel. Same for a
    /// hand-written `fd7a:115c:a1e0::/48`.
    ///
    /// `isProtectiveExclusion` already patches this for link-only prefixes;
    /// recording the truth in the first place fixes the whole class rather than
    /// one enumerated list of survivors.
    static func newlyInjected(desired: [String], existingBefore: [String]) -> [String] {
        let had = Set(existingBefore)
        return desired.filter { !had.contains($0) }.sorted()
    }

    /// What we recorded as injected for `field` on the last accepted change.
    static func injectedRecord(_ field: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: provenanceKeyPrefix + field) ?? []
    }

    /// Record what the kernel accepted, so the next pass can withdraw whatever
    /// is no longer wanted. Call only after a confirmed apply.
    static func commitProvenance(field: String, injected: [String]) {
        UserDefaults.standard.set(injected.sorted(), forKey: provenanceKeyPrefix + field)
    }

    /// Entries to strip when coexistence is torn down (TUN off): whatever we
    /// injected last, minus anything the user has since written by hand.
    ///
    /// Note this *computes* the withdrawal — it does not forget the record.
    /// Clearing provenance without removing the entries would silently promote
    /// them to user-owned, and they would then survive every later withdrawal
    /// pass: exactly the accretion this mechanism exists to prevent.
    static func withdraw(field: String, from existing: [String]) -> [String] {
        let injected = Set(injectedRecord(field))
        return existing
            .filter { !injected.contains($0) || isProtectiveExclusion($0) }
            .sorted()
    }

    // MARK: Resolver identity (fingerprint normalization)

    /// Resolver identity for **fingerprint purposes**: each `<server>#<iface>`
    /// binding reduced to its address, then deduped and sorted.
    ///
    /// Why the `#utunN` suffix must never enter the plan fingerprint
    /// (2026-10-14 审查中-6)：BSD 按创建顺序发放 utun 序号，睡眠唤醒/隧道重建
    /// 会给同一个对端换号（utun8→utun9）。后缀入指纹后，每次换号都被
    /// `reconcileCoexistenceIfChanged` 当成「拓扑变化」，回以整块 `tun` PATCH
    /// + 全量静态路由重装——2026-10-14 日志里一天 6 次假性「拓扑变化」同步、
    /// 路由条数在 7/8/9 之间振荡，就是这么来的。而那个 PATCH **根本携带不了
    /// DNS 绑定**：mihomo 忽略运行时 `dns` PATCH，`<server>#<iface>` pin 活在
    /// config.yaml 里，只能由用户触发的 `repairDNSInterfaceBindings` 修复
    /// （漂移检测走 `Coexistence.resolverDrift`）。也就是说换号引发的整块
    /// PATCH 纯属无谓消耗：它既修不了绑定，还会重建 TUN、抖掉在途连接。
    ///
    /// 剥掉后缀后，指纹只随**实质变化**而动：解析器地址集合、排除网段集合、
    /// fake-ip-filter 集合。策略字符串本身保留后缀（那是 mihomo 的接口绑定
    /// 语法，`dnsAdvice` 必须原样打印给用户抄进 config.yaml）。
    ///
    /// 去重是必要的：换号过渡期新旧两个接口可能同时被检测到，同一地址的两条
    /// 绑定（`1.2.3.4#utun8`、`1.2.3.4#utun9`）在指纹语义下是同一个事实。
    ///
    /// 住在本文件的理由与 provenance 相同：这是极易改错的纯规则，而
    /// `Coexistence.swift` 经 `Models.swift` 摸到 SwiftUI，回归套件编不了它。
    static func resolverIdentity(_ resolvers: [String]) -> [String] {
        Array(Set(resolvers.map { entry -> String in
            // 与 `Coexistence.resolverInterfaces` 同一套解析：`#` 前是地址。
            // 无后缀的条目原样保留；`first ??` 防御空串（`"".split` 得空数组，
            // 直接下标会崩——resolverInterfaces 用 `count == 2` guard 挡同类）。
            String(entry.split(separator: "#", maxSplits: 1).first ?? Substring(entry))
        })).sorted()
    }
}
