import Foundation

// MARK: - 订阅（proxy-provider）被策略组引用的统计
//
// 纯逻辑：无 SwiftUI、无文件读写、无 MainActor，可单独编译进回归套件
// （`Tests/ProviderUsage`，登记在 `Scripts/run-tests.sh`）。
//
// 为什么需要它：ClashHalo 里「订阅」是 proxy-provider，必须被某个策略组的 `use:`
// 引用才会出现在「代理节点」页。用户删掉引用后会看到「订阅有 86 个节点，代理节点
// 页却没有」——这是纯心智落差，不是故障。这里统计每个 provider 被多少个策略组引用，
// 让订阅卡自己说清这件事。
//
// 解析口径与 `EngineControl.readConfigFile` / `writeProxyProviders` 保持一致：
// 只做行扫描，`proxy-groups:` 块内 2 空格缩进的 `- name:` 开启一个组，组内
// `use:` 支持两种写法（2026-10-20 在真实 config.yaml 里都存在）：
//
//     use:                    use: ["US-LH", "US-BWH"]
//       - "US-LH"             （内联数组）
//       - "US-BWH"
//
// 不引入第二套 YAML 理解：不解析锚点/多行标量，遇到看不懂的行就跳过。

enum ProviderUsage {

    /// 统计每个 provider 被多少个策略组的 `use:` 引用。
    /// - 同一组里重复写同一个 provider 只算一次。
    /// - `use: []` 与没有 `use:` 的组不计入。
    /// - 只统计 `proxy-groups:` 块，`rules:` 里的同名文本不算。
    static func groupReferences(in yaml: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var inGroups = false
        var inUseBlock = false
        var currentGroupProviders = Set<String>()

        func commit() {
            for name in currentGroupProviders { counts[name, default: 0] += 1 }
            currentGroupProviders = []
        }

        for raw in yaml.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if isTopLevelKey {
                if inGroups { commit() }
                inGroups = trimmed.hasPrefix("proxy-groups:")
                inUseBlock = false
                continue
            }
            guard inGroups else { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // 组边界：2 空格缩进的 `- name:`
            if raw.hasPrefix("  - ") || raw.hasPrefix("  -\t") {
                commit()
                inUseBlock = false
                continue
            }

            // 组内字段：4 空格缩进
            if raw.hasPrefix("    ") {
                if inUseBlock {
                    // `use:` 的列表项：`      - "US-LH"`
                    if trimmed.hasPrefix("- ") {
                        if let name = scalar(String(trimmed.dropFirst(2))) {
                            currentGroupProviders.insert(name)
                        }
                        continue
                    }
                    // 列表项之外的新字段，说明 use 块结束
                    inUseBlock = false
                }
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                guard key == "use" else { continue }
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    inUseBlock = true                       // 块状写法
                } else {
                    for name in parseInlineList(value) {    // 内联数组
                        currentGroupProviders.insert(name)
                    }
                }
            }
        }
        if inGroups { commit() }
        return counts
    }

    /// `["US-LH", "US-BWH"]` / `[US-LH]` / `US-LH` → 名称数组。
    ///
    /// 必须先剥行尾注释再去方括号：`use: ["A", "B"]  # 备注` 里字符串是以备注结尾的，
    /// 先判 `hasSuffix("]")` 会漏掉那个 `]`，最后一个名称会变成 `B]`。
    static func parseInlineList(_ raw: String) -> [String] {
        var text = YamlScalar.stripInlineComment(raw).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") { text.removeFirst() }
        if text.hasSuffix("]") { text.removeLast() }
        return text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .compactMap { scalar(String($0)) }
    }

    /// 取出 `proxy-groups:` 块里所有策略组名（顺序即文件顺序，可能有重复）。
    ///
    /// 用途：规则表单保存前的「目标还在不在」判定。内核 `/proxies` 只反映**运行中**的
    /// 配置——手改 `config.yaml` 新增了策略组、还没 reload 时，新组不在 `/proxies` 里；
    /// 而规则最终是写进这份 config.yaml 的，所以文件里的组名也算数，否则会误判成失效。
    ///
    /// 口径与 `groupReferences` 完全一致（同一份行扫描）：只认 2 空格缩进的 `- name:`
    /// 开启的组，不解析锚点/多行标量，看不懂的行就跳过；`- {name: X, type: …}` 这种
    /// 内联映射取不到名字（返回里没有它），调用方本来就有内核 `/proxies` 兜底。
    static func groupNames(in yaml: String) -> [String] {
        var names: [String] = []
        var inGroups = false

        for raw in yaml.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if isTopLevelKey {
                inGroups = trimmed.hasPrefix("proxy-groups:")
                continue
            }
            guard inGroups else { continue }
            guard raw.hasPrefix("  - ") || raw.hasPrefix("  -\t") else { continue }

            // 组边界行：`- name: 默认代理` / `- name: "US-LH"  # 备注`
            let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("name:") else { continue }
            if let name = scalar(String(body.dropFirst("name:".count))) {
                names.append(name)
            }
        }
        return names
    }

    /// 去掉引号与行尾注释。整行以 `#` 开头的是注释，不是名称。
    static func scalar(_ raw: String) -> String? {
        var text = YamlScalar.stripInlineComment(raw).trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") { return nil }
        text = text.replacingOccurrences(of: "\"", with: "")
                   .replacingOccurrences(of: "'", with: "")
        return text.isEmpty ? nil : text
    }

    /// 找出 `proxy-groups:` 块里**没有任何节点来源**的策略组名。
    ///
    /// 节点来源 = `proxies:`（内联数组或块状列表）或 `use:`（内联数组或块状列表）
    /// 至少有一个非空条目。删除订阅后，只靠被删 provider 供血的组会变成空 select，
    /// `mihomo -t` 校验会失败——但内核报错是英文语法错，用户看不出「组空了」这个
    /// 真正原因。调用方（`saveProxyProviders`）在写盘后、校验前用它给出中文解释。
    ///
    /// 口径与 `groupReferences` 完全一致：同一份行扫描，不解析锚点/多行标量，
    /// 看不懂的行就跳过。返回顺序即文件顺序。
    static func groupsMissingMembers(in yaml: String) -> [String] {
        var missing: [String] = []
        var inGroups = false
        var currentName: String?
        var currentHasMembers = false
        var inUseBlock = false
        var inProxiesBlock = false

        func commit() {
            if let name = currentName, !currentHasMembers { missing.append(name) }
            currentName = nil
            currentHasMembers = false
            inUseBlock = false
            inProxiesBlock = false
        }

        for raw in yaml.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isTopLevelKey = !raw.hasPrefix(" ") && !raw.hasPrefix("\t")
                && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#")

            if isTopLevelKey {
                if inGroups { commit() }
                inGroups = trimmed.hasPrefix("proxy-groups:")
                continue
            }
            guard inGroups else { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // 组边界：2 空格缩进的 `- name:`
            if raw.hasPrefix("  - ") || raw.hasPrefix("  -\t") {
                commit()
                let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("name:") {
                    currentName = scalar(String(body.dropFirst("name:".count)))
                }
                continue
            }

            // 组内字段：4 空格缩进
            guard currentName != nil, raw.hasPrefix("    ") else { continue }
            if inUseBlock || inProxiesBlock {
                if trimmed.hasPrefix("- ") {
                    currentHasMembers = true   // 块状列表里有一个条目就够
                    continue
                }
                inUseBlock = false
                inProxiesBlock = false         // 新字段出现，列表块结束
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            // include-all 家族：成员来自全部节点/provider，本身就有来源，
            // 不认会把合法配置误判成空组、导致所有订阅保存被回滚。
            if key.hasPrefix("include-all") { currentHasMembers = true; continue }
            guard key == "use" || key == "proxies" else { continue }
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                if key == "use" { inUseBlock = true } else { inProxiesBlock = true }
            } else {
                if parseInlineList(value).isEmpty == false { currentHasMembers = true }
            }
        }
        if inGroups { commit() }
        return missing
    }

    /// 展示文案：`被 2 个策略组引用` / `未被任何策略组引用`。
    static func summary(count: Int) -> String {
        count > 0 ? "被 \(count) 个策略组引用" : "未被任何策略组引用"
    }
}
