import SwiftUI

// MARK: - 首次上手三步卡
//
// 为什么需要它：首次安装后配置页只有一句「暂无配置，点击右上角"+"导入」，
// 导入之后还要干什么没人说。这里把这条路铺成三步，并**用真实状态推导完成度**——
// 不新增任何「我引导过了」的持久化标志：用户删掉配置回来，勾选必须自动消失。
//
// 完成判据（全部实时读取 AppModel，不落盘）：
//   1. 有配置        → `store.profiles` 非空
//   2. 选了节点      → `groups` 里存在被选中的真实节点（DIRECT/REJECT 这类内置
//                      项不算「选了节点」，否则一份纯直连配置会显示已完成）
//   3. 开启接管      → `systemProxyOn || tunOn`
//
// 配置页空状态与仪表盘（接管未开启时）共用这一张卡，避免两份文案漂移。

struct GettingStartedCard: View {
    @EnvironmentObject var M: AppModel
    @State private var showImport = false

    /// 内置策略/节点，不是用户从订阅里选出来的出口。
    private static let builtinProxies: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE",
    ]

    private static func hasProfile(_ M: AppModel) -> Bool { !M.store.profiles.isEmpty }

    private static func hasSelectedNode(_ M: AppModel) -> Bool {
        M.groups.contains { g in
            let now = g.now.trimmingCharacters(in: .whitespaces)
            return !now.isEmpty && !builtinProxies.contains(now.uppercased())
        }
    }

    private var step1Done: Bool { Self.hasProfile(M) }
    private var step2Done: Bool { Self.hasSelectedNode(M) }
    private var step3Done: Bool { M.systemProxyOn || M.tunOn }

    /// 仪表盘只在「完全没有配置」时展示这张卡（文档口径，也是唯一不会闪的条件）。
    ///
    /// 不能改成「接管没开」：`systemProxyOn` / `tunOn` 冷启动时是默认 false，要等
    /// reconnect 后才同步（实测可达 +0.5s～+18s）。拿它判可见性，本来就开着代理的
    /// 用户每次启动都会先看到一张引导卡再消失；永远只开网关/临时关掉代理的老用户
    /// 还会被这张卡长期压在统计条上方。
    static func shouldShowOnDashboard(_ M: AppModel) -> Bool {
        M.store.profiles.isEmpty
    }

    /// 配置页把清单压在配置列表上方：**内核可达**（说明 `systemProxyOn`/`tunOn`
    /// 已经同步过，不是默认值）**且确实没开接管**。这样导入订阅后第 1 步的勾当场
    /// 可见，接管一开清单立即退场，冷启动也不会先闪一下。
    static func shouldShowAboveProfileList(_ M: AppModel) -> Bool {
        M.reachable && !(M.systemProxyOn || M.tunOn)
    }

    var body: some View {
        Card(title: "三步开始接管", icon: "sparkles") {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                step(number: 1, title: "导入订阅",
                     detail: step1Done ? "已有 \(M.store.profiles.count) 个配置"
                                       : "粘贴订阅链接，或从本地 YAML 文件导入",
                     done: step1Done) {
                    Button("导入订阅") { showImport = true }
                        .dsButton(.prominent)
                }
                Divider().overlay(DS.Palette.separator)
                step(number: 2, title: "选一个节点",
                     detail: step2Done ? "已在策略组中选定出口"
                                       : (step1Done ? "在「代理节点」里挑一个出口" : "导入订阅后可用"),
                     done: step2Done) {
                    Button("选择节点") { M.route = "proxies" }
                        .dsButton()
                        .disabled(!step1Done)
                }
                Divider().overlay(DS.Palette.separator)
                step(number: 3, title: "开启接管",
                     detail: step3Done
                        ? (M.tunOn ? "TUN 正在接管全部流量" : "系统代理正在接管遵守代理设置的应用")
                        : "系统代理只接管遵守代理设置的应用；TUN 接管全部流量，需要一次管理员授权",
                     done: step3Done) {
                    HStack(spacing: DS.Spacing.s) {
                        Button("系统代理") { M.toggleSystemProxy() }
                            .dsButton()
                            .disabled(!step1Done || M.engine.isBusy || M.systemProxyOn)
                        Button("TUN") { M.toggleTUN() }
                            .dsButton()
                            .disabled(!step1Done || M.engine.isBusy || M.tunOn)
                    }
                }
            }
        }
        .sheet(isPresented: $showImport) { ImportRemoteSheet() }
    }

    @ViewBuilder
    private func step<Action: View>(number: Int,
                                    title: String,
                                    detail: String,
                                    done: Bool,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(DS.Icon.font(DS.Icon.lg))
                .foregroundColor(done ? DS.Palette.ok : .secondary)
                .frame(width: DS.Icon.lg, alignment: .center)
                .accessibilityLabel(done ? "第 \(number) 步已完成" : "第 \(number) 步未完成")

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(title)
                    .font(.dsBodySemibold)
                    .foregroundColor(done ? .secondary : .primary)
                Text(detail)
                    .font(.dsCaption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Spacing.s)

            if !done { action() }
        }
    }
}

#Preview("Getting started") {
    GettingStartedCard()
        .environmentObject(AppModel.shared)
        .padding(DS.Spacing.xl)
        .frame(width: 640)
}
