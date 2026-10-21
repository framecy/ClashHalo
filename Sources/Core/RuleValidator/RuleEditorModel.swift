import Foundation
import Combine

@MainActor
public final class RuleEditorModel: ObservableObject {
    @Published public var nodes: [RuleNode] = []
    @Published public var errorMessage: String? = nil
    
    private var targetFilePath: String
    private var originalYaml: String = ""
    /// `load()` 时解析出的节点快照。保存时用它区分「改了哪条规则」，
    /// 从而只改动对应的行，而不是把整个 rules 块按节点重建（那会丢掉块内注释）。
    private var loadedNodes: [RuleNode] = []
    
    public init(targetFilePath: String) {
        self.targetFilePath = targetFilePath
    }
    
    public func setTargetPath(_ path: String) {
        self.targetFilePath = path
    }
    
    public func load() {
        do {
            let yaml = try String(contentsOfFile: targetFilePath, encoding: .utf8)
            self.originalYaml = yaml
            self.loadedNodes = YamlRuleASTEngine.extractRules(from: yaml).sorted { $0.sort < $1.sort }
            self.nodes = loadedNodes
        } catch {
            self.errorMessage = "加载配置失败：\\(error.localizedDescription)"
        }
    }
    
    public func save() -> Bool {
        do {
            for i in 0..<nodes.count {
                nodes[i].sort = i
            }
            // 保留 rules 块内的注释与空行：旧实现按节点重建整块，用户手写的证据注释
            // 会在每次保存时被清掉（真实配置实测一次空往返少 50 行，其中 43 行注释）。
            let newYaml = try YamlRuleASTEngine.injectRulesPreservingComments(
                nodes, into: originalYaml, loadedNodes: loadedNodes)
            try newYaml.write(toFile: targetFilePath, atomically: true, encoding: .utf8)
            // 保存成功后把基线推进到刚落盘的内容：
            //   * `originalYaml` 决定「块外内容」取哪一版，留着旧版会在下一次保存时
            //     把期间别的写点（网关覆盖、profile 切换）改过的字节回滚掉；
            //   * `loadedNodes` 是注释归属的锚点，不更新的话第二次保存会因为
            //     「规则被删」而把注释全搬到块尾（UUID 还在，但基线是旧的）。
            self.originalYaml = newYaml
            self.loadedNodes = nodes
            // The target is the live config.yaml, which carries the tailnet
            // auth-key in plain text — keep the 0600 promise across writers.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetFilePath)
            return true
        } catch {
            self.errorMessage = "保存失败：\\(error.localizedDescription)"
            return false
        }
    }
    
    public func addNode(_ node: RuleNode) {
        var n = node
        n.sort = 0
        nodes.insert(n, at: 0)
    }
    
    public func updateNode(id: UUID, with node: RuleNode) {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes[index] = node
        }
    }
    
    public func deleteNodes(ids: Set<UUID>) {
        nodes.removeAll { ids.contains($0.id) }
    }
    
    public func toggleNodes(ids: Set<UUID>, isEnabled: Bool) {
        for i in 0..<nodes.count {
            if ids.contains(nodes[i].id) {
                nodes[i].isEnabled = isEnabled
            }
        }
    }
    
    public func toggleNode(id: UUID) {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes[index].isEnabled.toggle()
        }
    }
    
    public func moveNode(from source: IndexSet, to destination: Int) {
        nodes.move(fromOffsets: source, toOffset: destination)
    }
}
