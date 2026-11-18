import Foundation

/// 将单个普通块 provider 转成本地文件。只处理直接子字段，保留 health-check/filter 等。
/// 模板/flow/多行 scalar 无法证明安全时，在任何下载/持久化之前即可预检并拒绝。
public enum ProviderRewrite {
    public struct Result {
        public var yaml: String
        public var changed: Bool
    }

    public static func canConvertToFile(_ yaml: String, name: String) -> Bool {
        convertibleBlock(yaml, name: name) != nil
    }

    public static func convertToFile(_ yaml: String, name: String, filePath: String) -> Result? {
        guard !filePath.isEmpty, !filePath.contains("\n"), !filePath.contains("\r"),
              let block = convertibleBlock(yaml, name: name) else { return nil }
        var lines = yaml.components(separatedBy: "\n")
        let pad = String(repeating: " ", count: block.fieldIndent)
        let eol = lines[block.range.lowerBound].hasSuffix("\r") ? "\r" : ""
        let path = YamlScalar.quoteIfNeeded(filePath)
        let scalarContent = ProviderConfiguration.blockScalarContentLines(in: lines)
        for field in block.fields.reversed() {
            switch field.key {
            case "type":
                lines[field.range.lowerBound] = ProviderConfiguration.replacingValue(in: lines[field.range.lowerBound], with: "file")
            case "path":
                lines[field.range.lowerBound] = ProviderConfiguration.replacingValue(in: lines[field.range.lowerBound], with: path)
            case "url", "interval", "header":
                // 删除整个直接字段（包括 header 子块），保留字段之间独立的注释。
                let indexes = field.range.filter {
                    scalarContent.contains($0) || !ProviderConfiguration.clean(lines[$0]).isEmpty
                }
                for index in indexes.reversed() { lines.remove(at: index) }
            default: break
            }
        }
        var added: [String] = []
        if !block.fields.contains(where: { $0.key == "type" }) { added.append(pad + "type: file" + eol) }
        if !block.fields.contains(where: { $0.key == "path" }) { added.append(pad + "path: " + path + eol) }
        lines.insert(contentsOf: added, at: block.range.lowerBound + 1)
        let result = lines.joined(separator: "\n")
        return Result(yaml: result, changed: result != yaml)
    }

    public static func httpURL(_ yaml: String, name: String) -> String? {
        guard let entry = ProviderConfiguration.entries(in: yaml).first(where: { $0.name == name }),
              entry.type.lowercased() != "file", !entry.url.isEmpty else { return nil }
        return entry.url
    }

    public static func isFileProvider(_ yaml: String, name: String) -> Bool {
        ProviderConfiguration.entries(in: yaml).first(where: { $0.name == name })?.type.lowercased() == "file"
    }

    private static func convertibleBlock(_ yaml: String, name: String) -> ProviderConfiguration.ProviderBlock? {
        let lines = yaml.components(separatedBy: "\n")
        guard let blocks = ProviderConfiguration.providerBlocks(in: lines),
              let block = blocks.first(where: { $0.name == name }),
              let entry = ProviderConfiguration.entries(in: yaml).first(where: { $0.name == name }),
              ["", "http", "file"].contains(entry.type.lowercased()) else { return nil }
        // 这些字段要原位替换或移除；不接受结构值或多行 scalar，避免残留半段内容。
        for field in block.fields where ["type", "path", "url", "interval"].contains(field.key) {
            guard ProviderConfiguration.isSimpleScalar(field, lines: lines) else { return nil }
        }
        return block
    }

    static func unquote(_ text: String) -> String { ProviderConfiguration.unquote(text) }
}
