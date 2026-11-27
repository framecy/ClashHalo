import Foundation

/// 内核（mihomo）在配置里**没写这个键**时实际采用的值。
///
/// 为什么需要这张表：内核的缺省值来自 `DefaultRawConfig()` 预置结构体 + YAML 逐键
/// 覆盖（v1.19.32 `config/config.go:486-600`），所以「没写」并不等于 `false`。界面
/// 若一律 `(dict[key] as? Bool) == true`，「缺省为开」的键就会被显示成关，而用户点
/// 一次开关写进去的值正好等于内核在用的值——行为毫无变化，看起来像开关失灵
/// （2026-11-27 嗅探页实测）。枚举型键同理：`tun.stack` 没写时内核用的是 `Mips`，
/// 而选择器把「没写」显示成第一个选项 `gVisor`——用户以为在跑 gVisor，实际是 Mips；
/// 他随手选一下「System」，等于在一次无关操作里换掉了数据面。
///
/// 覆盖面：**界面上凡是有内核缺省的布尔开关与枚举选择器，都必须在这里有一行**。
/// `Scripts/run-tests.sh` 的 `kernel-defaults` 预检会扫描 `Sources/UI` 里的
/// `NToggle` / `ToggleRow` / `NPicker` 调用点，任何没登记的键直接判 FAIL——新增
/// 控件时先查上游 `DefaultRawConfig()`（枚举再查 `constant/` 里的映射表）再登记，
/// 不许按「缺省都是 false / 第一个选项」猜。
///
/// 数据来源（逐条核到行，mihomo v1.19.32）：
/// - 顶层：`ipv6` 缺省 **true**（:491）；`allow-lan`、`geodata-mode`
///   （:495 取 `geodata.GeodataMode()`，`component/geodata/utils.go:14` 的 `geoMode`
///   零值 false）、`geo-auto-update`、`unified-delay`（:497）、`tcp-concurrent`
///   （:504）、`disable-keep-alive`、`inbound-mptcp`（RawGeneral 未预置，零值）都是 false。
/// - `tun.auto-route` / `tun.auto-detect-interface` 缺省 **true**（:552-553）。
///   `AppModel.applyTUNState` 的 `tunPatchBody()` 也按 `?? true` 回落，两处必须一致。
/// - `tun.stack` 缺省 `Mips`（:550 `Stack: C.TunMips`；`constant/tun.go:10-16` 的
///   枚举与 `StackTypeMapping` 认 `gvisor` / `system` / `mixed` / `mips` 四个值，
///   `String()` 为 "Mips"）。注意 UI 展示的是 `String()` 形态、写盘用小写键。
/// - `dns.enable`、`dns.ipv6` 缺省 false（:509-510）。注意 `dns.use-hosts` /
///   `dns.use-system-hosts` 缺省 true（:511-512），目前没做成开关，将来若加必须登记。
/// - `sniffer` 的 `force-dns-mapping` / `parse-pure-ip` / `override-destination`
///   缺省 **true**（:598-600），`enable` 缺省 false（:593）。
///
/// 说明两个数据源差异（决定了表里哪些键"看起来用不到"却必须留）：
/// `M.configs` 来自运行时 `GET /configs`，它已经返回 materialize 后的顶层与 `tun`
/// 块（缺省值在内核侧就补齐了，`tun.stack` 回来的是 "Mips"/"Mixed" 这种 `String()`
/// 形态），所以这些键在正常情况下显示本来就是对的；而 `GET /configs` **不返回**
/// `sniffer` 与 `dns`，这两块由 `AppModel+Config.refreshConfigs` 从 `config.yaml`
/// 原样读入（「没写」就是没写）。表里两层都登记，是为了让「内核挂了 / 数据源变了 /
/// 以后改成从磁盘读」这几种情况仍然显示内核语义，而不是靠当前数据源恰好在凑巧正确。
enum KernelDefaults {
    /// `parent` 为空串表示顶层键。
    static func bool(parent: String, key: String) -> Bool {
        bools[path(parent, key)] ?? false
    }

    /// 没登记时返回 nil——调用方必须显式决定「不认识这个键」怎么显示，不能拿到一个
    /// 看起来合法的值继续渲染。
    static func string(parent: String, key: String) -> String? {
        strings[path(parent, key)]
    }

    /// 这个键的内核缺省值是否已经核实并登记过。
    static func isKnownBool(parent: String, key: String) -> Bool {
        bools[path(parent, key)] != nil
    }

    static func isKnownString(parent: String, key: String) -> Bool {
        strings[path(parent, key)] != nil
    }

    static func path(_ parent: String, _ key: String) -> String {
        parent.isEmpty ? key : "\(parent).\(key)"
    }

    /// 只有「缺省为 true」与「已核实为 false」的键都显式登记，预检才能挡住漏登记。
    static let bools: [String: Bool] = [
        // 顶层（RawConfig）
        "ipv6": true,
        "allow-lan": false,
        "geodata-mode": false,
        "geo-auto-update": false,
        "tcp-concurrent": false,
        "unified-delay": false,
        "disable-keep-alive": false,
        "inbound-mptcp": false,
        // tun
        "tun.auto-route": true,
        "tun.auto-detect-interface": true,
        // dns（`GET /configs` 不返回，来源是 config.yaml）
        "dns.enable": false,
        "dns.ipv6": false,
        // sniffer（同上）
        "sniffer.enable": false,
        "sniffer.override-destination": true,
        "sniffer.force-dns-mapping": true,
        "sniffer.parse-pure-ip": true
    ]

    /// 枚举型缺省值，写成**内核 `String()` 的形态**（`GET /configs` 也是这个形态），
    /// 调用方比较时统一 `lowercased()`；写盘用的键名见 `NPicker` 的 options。
    static let strings: [String: String] = [
        // tun.stack 缺省 C.TunMips（config.go:550）→ String() == "Mips"
        "tun.stack": "Mips",
        // dns.enhanced-mode 缺省 C.DNSMapping（config.go:514）→ String() == "redir-host"
        // （`constant/dns.go:45`）。界面的选项顺序是 fake-ip 在前，缺键时回落第一个
        // 选项就会显示 Fake-IP，而内核实际在用 Redir-Host——fake-ip 会分配 198.18.x
        // 假地址，两者对「哪些应用能上网」的影响完全不同，不能显示错。
        "dns.enhanced-mode": "redir-host",
        // 以下三条缺省值本身与界面第一个选项一致（所以过去没露出症状），但同样是
        // 「内核语义」而非「界面顺序」，一并登记，让预检能覆盖这三个 PickerRow。
        // geodata-loader 缺省 "memconservative"（config.go:496）
        "geodata-loader": "memconservative",
        // log-level 缺省 log.INFO → String() == "info"（config.go:499、log/level.go:45）
        "log-level": "info",
        // find-process-mode 缺省 process.FindProcessStrict → String() == "strict"
        // （config.go:505）。界面选项顺序是 always / strict / off，第一个不是缺省值，
        // 缺键时过去会显示「总是」而内核在用 strict。
        "find-process-mode": "strict"
    ]
}

/// 布尔型配置项的取值判定：显式写了就用写的，没写用内核缺省。
///
/// 供 `NToggle`（嵌套键）与 `ToggleRow`（顶层键）共用。缺省值必须来自
/// `KernelDefaults`——这里刻意不提供「一律 false」的默认参数，否则「某项缺省是开」
/// 的地方又会悄悄退回旧行为。
enum NestedBoolSetting {
    static func effectiveValue(in block: [String: Any]?, key: String, defaultValue: Bool) -> Bool {
        if let explicit = block?[key] as? Bool { return explicit }
        return defaultValue
    }
}
