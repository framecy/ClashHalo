import Foundation

/// Local provider IO only. The caller supplies the directory and serializes the whole
/// snapshot → save → configuration/reload → restore sequence. Never discovers app data
/// or downloads a URL. Cross-process writers are intentionally unsupported.
final class ProviderSourceStore {
    struct Record: Codable, Equatable {
        let profileID: String
        let name: String
        let url: String
        /// Relative to mihomo's working directory, not the profile directory.
        let path: String
    }

    struct Snapshot {
        let profileID: String
        let name: String
        let record: Record?
        fileprivate let nodes: Data?
        fileprivate let owner: UUID
    }

    enum StoreError: LocalizedError {
        case unsafePath, invalidIndex, missingSource, foreignSnapshot, legacyNeedsRebinding
        case writeFailed, rollbackFailed

        var errorDescription: String? {
            switch self {
            case .unsafePath: return "本地订阅路径不安全，已停止读写。"
            case .invalidIndex: return "本地订阅索引无效，已保留原文件。"
            case .missingSource: return "当前配置没有绑定此本地订阅的源地址。"
            case .foreignSnapshot: return "本地订阅快照不属于当前存储实例。"
            case .legacyNeedsRebinding: return "旧版订阅没有配置归属，请重新绑定源地址；旧记录已保留。"
            case .writeFailed: return "本地订阅文件写入失败。"
            case .rollbackFailed: return "本地订阅操作失败，且未能完整恢复文件；请勿继续覆盖。"
            }
        }
    }

    private struct Index: Codable {
        let version: Int
        let records: [Record]
    }

    private struct Change {
        let target: URL
        let data: Data?
    }

    private(set) var records: [Record] = []
    private(set) var legacySources: [String: String] = [:]
    private let base: URL
    private let fm: FileManager
    private let owner = UUID()
    private var loaded = false

    /// FileManager injection is also useful for deterministic disk-failure tests.
    init(baseDirectory: URL, fileManager: FileManager = .default) {
        base = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        fm = fileManager
    }

    private var indexURL: URL { base.appendingPathComponent("provider-sources-v2.json") }
    private var legacyURL: URL { base.appendingPathComponent("provider-sources.json") }
    private var filesURL: URL { base.appendingPathComponent("provider-files", isDirectory: true) }

    func relativePath(profileID: String, name: String) -> String {
        "./provider-files/\(Sha1.hex(profileID))/\(Sha1.hex(name)).yaml"
    }

    func source(profileID: String, name: String) -> Record? {
        records.first { $0.profileID == profileID && $0.name == name }
    }

    /// A bad new or legacy index never replaces the last successfully loaded memory.
    func load() throws {
        try ensureBase()
        try secureExistingDirectory(filesURL)
        var next: [Record] = []
        if let data = try readFile(indexURL) {
            let index: Index
            do { index = try JSONDecoder().decode(Index.self, from: data) }
            catch { throw StoreError.invalidIndex }
            guard index.version == 2 else { throw StoreError.invalidIndex }
            try validateRecords(index.records)
            for record in index.records {
                try secureExistingDirectory(nodeURL(profileID: record.profileID, name: record.name)
                    .deletingLastPathComponent())
            }
            next = sorted(index.records)
        }
        var legacy: [String: String] = [:]
        if let data = try readFile(legacyURL) {
            do { legacy = try JSONDecoder().decode([String: String].self, from: data) }
            catch { throw StoreError.invalidIndex }
        }
        records = next
        legacySources = legacy
        loaded = true
    }

    func snapshot(profileID: String, name: String) throws -> Snapshot {
        try prepare()
        try validateIdentity(profileID: profileID, name: name)
        return Snapshot(profileID: profileID, name: name,
                        record: source(profileID: profileID, name: name),
                        nodes: try readFile(nodeURL(profileID: profileID, name: name)), owner: owner)
    }

    func restore(snapshot: Snapshot) throws {
        try prepare()
        guard snapshot.owner == owner else { throw StoreError.foreignSnapshot }
        var next = records.filter { $0.profileID != snapshot.profileID || $0.name != snapshot.name }
        if let record = snapshot.record { next.append(record) }
        try commit(records: next, changes: [Change(
            target: nodeURL(profileID: snapshot.profileID, name: snapshot.name), data: snapshot.nodes)])
    }

    func save(profileID: String, name: String, url: String, nodes: String) throws {
        try prepare()
        try validateIdentity(profileID: profileID, name: name)
        guard !url.isEmpty else { throw StoreError.invalidIndex }
        let record = Record(profileID: profileID, name: name, url: url,
                            path: relativePath(profileID: profileID, name: name))
        var next = records.filter { $0.profileID != profileID || $0.name != name }
        next.append(record)
        try commit(records: next, changes: [Change(target: nodeURL(profileID: profileID, name: name),
                                                   data: Data(nodes.utf8))])
    }

    func updateNodes(profileID: String, name: String, nodes: String) throws {
        try prepare()
        guard source(profileID: profileID, name: name) != nil else { throw StoreError.missingSource }
        try commit(records: records, changes: [Change(target: nodeURL(profileID: profileID, name: name),
                                                       data: Data(nodes.utf8))])
    }

    func remove(profileID: String, name: String) throws {
        try prepare()
        try validateIdentity(profileID: profileID, name: name)
        let next = records.filter { $0.profileID != profileID || $0.name != name }
        try commit(records: next, changes: [Change(target: nodeURL(profileID: profileID, name: name), data: nil)])
    }

    func removeProfile(_ profileID: String) throws {
        try prepare()
        guard !profileID.isEmpty else { throw StoreError.invalidIndex }
        var files: [URL] = []
        var directories: [URL] = []
        try collectTree(filesURL.appendingPathComponent(Sha1.hex(profileID), isDirectory: true),
                        files: &files, directories: &directories)
        try commit(records: records.filter { $0.profileID != profileID },
                   changes: files.map { Change(target: $0, data: nil) }, removingDirectories: directories)
    }

    /// No inference from a global name is safe: even one current profile is not proof
    /// of the old URL's ownership. The UI must explicitly rebind via save().
    func migrateLegacy(profileID: String, name: String? = nil) throws {
        try prepare()
        if name.map({ legacySources[$0] != nil }) ?? !legacySources.isEmpty {
            throw StoreError.legacyNeedsRebinding
        }
    }

    /// Includes unindexed/old-layout provider files and the legacy URL map. Unknown
    /// symlinks or special files abort the entire operation before anything is removed.
    func removeAll() throws {
        try prepare()
        var files: [URL] = []
        var directories: [URL] = []
        try collectTree(filesURL, files: &files, directories: &directories)
        let changes = files.map { Change(target: $0, data: nil) }
            + [Change(target: legacyURL, data: nil), Change(target: indexURL, data: nil)]
        try transact(changes, removingDirectories: directories)
        records = []
        legacySources = [:]
    }

    private func prepare() throws {
        if !loaded { try load() }
        else { try ensureBase() }
    }

    private func nodeURL(profileID: String, name: String) -> URL {
        filesURL.appendingPathComponent(Sha1.hex(profileID), isDirectory: true)
            .appendingPathComponent(Sha1.hex(name) + ".yaml")
    }

    private func sorted(_ records: [Record]) -> [Record] {
        records.sorted { ($0.profileID, $0.name) < ($1.profileID, $1.name) }
    }

    private func validateIdentity(profileID: String, name: String) throws {
        guard !profileID.isEmpty, !name.isEmpty else { throw StoreError.invalidIndex }
    }

    private func validateRecords(_ records: [Record]) throws {
        var identities = Set<[String]>()
        var paths = Set<String>()
        for record in records {
            try validateIdentity(profileID: record.profileID, name: record.name)
            guard !record.url.isEmpty,
                  record.path == relativePath(profileID: record.profileID, name: record.name),
                  identities.insert([record.profileID, record.name]).inserted,
                  paths.insert(record.path).inserted else { throw StoreError.invalidIndex }
            try validatePath(nodeURL(profileID: record.profileID, name: record.name))
        }
    }

    private func commit(records next: [Record], changes: [Change], removingDirectories: [URL] = []) throws {
        try validateRecords(next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ordered = sorted(next)
        let data = try encoder.encode(Index(version: 2, records: ordered))
        // Node files go first; a failed index replacement restores their exact bytes.
        try transact(changes + [Change(target: indexURL, data: data)], removingDirectories: removingDirectories)
        records = ordered
    }

    /// Exception-atomic, not a crash-recovery journal. Keep all old bytes until every
    /// replacement/deletion succeeds, then and only then publish memory to callers.
    private func transact(_ changes: [Change], removingDirectories: [URL] = []) throws {
        let backups = try changes.map { Change(target: $0.target, data: try readFile($0.target)) }
        var attempted: [Int] = []
        var removedDirectories: [URL] = []
        do {
            for (index, change) in changes.enumerated() {
                attempted.append(index)
                try apply(change)
            }
            for directory in removingDirectories.reversed() {
                try validatePath(directory)
                guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw StoreError.unsafePath
                }
                try fm.removeItem(at: directory)
                removedDirectories.append(directory)
            }
        } catch {
            let original = error
            var rollbackFailed = false
            for directory in removedDirectories.reversed() {
                do { try ensureDirectory(directory) }
                catch { rollbackFailed = true }
            }
            for index in attempted.reversed() {
                do { try apply(backups[index]) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw StoreError.rollbackFailed }
            throw original
        }
    }

    private func apply(_ change: Change) throws {
        try validatePath(change.target)
        if let data = change.data {
            try ensureDirectory(change.target.deletingLastPathComponent())
            // A private staging directory means URL/node bytes are never exposed by
            // a permissive umask, including the brief interval before atomic install.
            let stageDirectory = base.appendingPathComponent(".provider-write-" + UUID().uuidString,
                                                            isDirectory: true)
            try ensureDirectory(stageDirectory)
            let stage = stageDirectory.appendingPathComponent("data")
            defer {
                // Staging paths are generated here; revalidate even during cleanup.
                if (try? validatePath(stageDirectory)) != nil { try? fm.removeItem(at: stageDirectory) }
            }
            guard fm.createFile(atPath: stage.path, contents: data,
                                attributes: [.posixPermissions: 0o600]) else { throw StoreError.writeFailed }
            try validatePath(stage)
            try validatePath(change.target)
            if try attributes(change.target) != nil {
                _ = try fm.replaceItemAt(change.target, withItemAt: stage,
                                         backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: stage, to: change.target)
            }
        } else if try attributes(change.target) != nil {
            try validatePath(change.target)
            try fm.removeItem(at: change.target)
        }
    }

    private func readFile(_ url: URL) throws -> Data? {
        try validatePath(url)
        guard let attrs = try attributes(url) else { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw StoreError.unsafePath }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try Data(contentsOf: url)
    }

    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try fm.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }

    private func ensureBase() throws {
        guard base.isFileURL, base.path != "/",
              base.resolvingSymlinksInPath().path == base.path else { throw StoreError.unsafePath }
        if try attributes(base) == nil {
            try fm.createDirectory(at: base, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        guard try attributes(base)?[.type] as? FileAttributeType == .typeDirectory,
              base.resolvingSymlinksInPath().path == base.path else { throw StoreError.unsafePath }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    }

    /// Both lexical containment and canonical identity are checked. No symlink,
    /// hardlinked file, special file, or non-directory ancestor is followed.
    private func validatePath(_ url: URL) throws {
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(base.path + "/"),
              target.resolvingSymlinksInPath().path == target.path,
              base.resolvingSymlinksInPath().path == base.path,
              try attributes(base)?[.type] as? FileAttributeType == .typeDirectory else {
            throw StoreError.unsafePath
        }
        let components = target.path.dropFirst(base.path.count + 1).split(separator: "/")
        var current = base
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            guard let attrs = try attributes(current) else { continue }
            let type = attrs[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular,
                  index == components.count - 1 || type == .typeDirectory,
                  type != .typeRegular || (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw StoreError.unsafePath
            }
        }
    }

    private func secureExistingDirectory(_ url: URL) throws {
        try validatePath(url)
        guard let attrs = try attributes(url) else { return }
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.unsafePath }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func ensureDirectory(_ url: URL) throws {
        if url.path == base.path { try ensureBase(); return }
        try validatePath(url)
        try ensureDirectory(url.deletingLastPathComponent())
        if try attributes(url) == nil {
            try fm.createDirectory(at: url, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        guard try attributes(url)?[.type] as? FileAttributeType == .typeDirectory else {
            throw StoreError.unsafePath
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func collectTree(_ directory: URL, files: inout [URL], directories: inout [URL]) throws {
        try validatePath(directory)
        guard let attrs = try attributes(directory) else { return }
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.unsafePath }
        directories.append(directory)
        // Build child URLs from our pinned root. Foundation enumeration URLs can
        // otherwise switch /var to /private/var once an existing child is removed.
        for name in try fm.contentsOfDirectory(atPath: directory.path) {
            let child = directory.appendingPathComponent(name)
            try validatePath(child)
            if try attributes(child)?[.type] as? FileAttributeType == .typeDirectory {
                try collectTree(child, files: &files, directories: &directories)
            } else { files.append(child) }
        }
    }
}
