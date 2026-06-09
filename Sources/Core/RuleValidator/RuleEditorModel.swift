import Foundation
import Combine

@MainActor
public final class RuleEditorModel: ObservableObject {
    @Published public var nodes: [RuleNode] = []
    @Published public var errorMessage: String? = nil
    
    private var targetFilePath: String
    private var originalYaml: String = ""
    
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
            self.nodes = YamlRuleASTEngine.extractRules(from: yaml).sorted { $0.sort < $1.sort }
        } catch {
            self.errorMessage = "加载配置失败：\\(error.localizedDescription)"
        }
    }
    
    public func save() -> Bool {
        do {
            for i in 0..<nodes.count {
                nodes[i].sort = i
            }
            let newYaml = try YamlRuleASTEngine.injectRules(nodes, into: originalYaml)
            try newYaml.write(toFile: targetFilePath, atomically: true, encoding: .utf8)
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
