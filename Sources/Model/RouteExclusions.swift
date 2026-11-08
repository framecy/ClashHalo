import Foundation

// MARK: - route-exclude-address 的多源合并
//
// `tun.route-exclude-address` 现在有两个来源：
//   1. 共存（peer）：别的 VPN 隧道要用的网段，不能让 auto-route 吞掉；
//   2. 直连（direct）：规则判 DIRECT 的 IP 段，排除后不再进用户态协议栈。
//
// 归属记录只有一个（`CoexistenceProvenance` 的 `route-exclude-address` 键）。
// 两个源各写各的会互相覆盖——A 源 commit 之后 B 源再 commit，A 的条目就从记录里
// 消失了，下一次撤回会把它当成「用户手写」或「不该存在」处理。这正是
// CoexistenceProvenance 文件头记录的事故类型（Tailscale 的 100.64.0.0/10 被认领
// 又被撤回，CGNAT 掉进 auto-route）。
//
// 所以合并必须收敛到唯一一处：先求并集，再对并集做一次 newlyInjected，最后只
// commit 这一次。任何新的排除源都必须经过这里，不许自己 commit。

public struct RouteExclusionSources: Equatable {
    /// 共存：对端隧道声明的网段。
    public var peer: [String]
    /// 直连：用户采纳的 IP 型 DIRECT 网段。
    public var direct: [String]

    public init(peer: [String] = [], direct: [String] = []) {
        self.peer = peer; self.direct = direct
    }

    /// 送去 PATCH 的完整清单（去重 + 稳定排序）。
    public var desired: [String] { Array(Set(peer + direct)).sorted() }
    public var isEmpty: Bool { peer.isEmpty && direct.isEmpty }
}

public enum RouteExclusionMerge {
    /// 把多源并进现有清单，并算出「本次真正新增」的条目。
    ///
    /// - `merged`：要写进 PATCH 的完整列表（用户手写条目原样保留）。
    /// - `injected`：只包含本次新增的条目——这是唯一允许 commit 给 provenance 的值。
    ///   把整份 desired 当成 injected 会认领用户手写的条目，下次撤回就删掉它们。
    public static func merge(sources: RouteExclusionSources,
                             existing: [String],
                             field: String = "route-exclude-address")
        -> (merged: [String], injected: [String], record: [String]) {
        let desired = sources.desired
        let merged = CoexistenceProvenance.mergePreservingUserEntries(
            field: field, desired: desired, in: existing)
        let injected = CoexistenceProvenance.newlyInjected(desired: desired, existingBefore: existing)
        // 记录的是「我们至今认领、且这次仍然想要的」——只记 newlyAdded 会在第二轮
        // 把上一轮的认领抹掉（那时它们已经在 existing 里了），条目就此变成"用户手写"，
        // 以后谁也撤不回来。见 CoexistenceProvenance.nextRecord。
        let record = CoexistenceProvenance.nextRecord(
            previous: CoexistenceProvenance.injectedRecord(field),
            newlyAdded: injected,
            desired: desired)
        return (merged, injected, record)
    }

    /// TUN 关闭时该保留的清单：撤回我们注入过的，用户手写的原样留下。
    public static func withdraw(existing: [String],
                                field: String = "route-exclude-address") -> [String] {
        CoexistenceProvenance.withdraw(field: field, from: existing)
    }
}
