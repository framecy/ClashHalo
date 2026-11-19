import Foundation

private enum Injected: Error { case failure }

/// Exercise real disk IO, failing exactly one install/removal after earlier writes.
private final class FailingFileManager: FileManager, @unchecked Sendable {
    var failNextIndexWrite = false
    var failedRemoval: String?
    override func createFile(atPath path: String, contents data: Data?,
                             attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if failNextIndexWrite, let data,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           object["version"] as? Int == 2 {
            failNextIndexWrite = false
            return false
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
    override func removeItem(at URL: URL) throws {
        if failedRemoval == URL.lastPathComponent {
            failedRemoval = nil
            throw Injected.failure
        }
        try super.removeItem(at: URL)
    }
}

private let fm = FileManager.default
private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    if try condition() { passed += 1; print("PASS \(label)") }
    else { failed += 1; print("FAIL \(label)") }
}

private func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); failed += 1; print("FAIL \(label)") }
    catch {
        if case ProviderSourceStore.StoreError.rollbackFailed = error {
            failed += 1; print("FAIL \(label): unexpected rollback failure")
        } else { passed += 1; print("PASS \(label)") }
    }
}

private func withStore(_ body: (URL, ProviderSourceStore, FailingFileManager) throws -> Void) throws {
    let root = fm.temporaryDirectory.appendingPathComponent("provider-source-tests-" + UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer {
        // Only the exact, freshly created temporary root can be removed.
        let temp = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if root.path.hasPrefix(temp.path + "/provider-source-tests-"),
           root.resolvingSymlinksInPath().path == root.path { try? fm.removeItem(at: root) }
    }
    let io = FailingFileManager()
    try body(root, ProviderSourceStore(baseDirectory: root.appendingPathComponent("store"), fileManager: io), io)
}

private func node(_ root: URL, _ store: ProviderSourceStore, _ profile: String, _ name: String) -> URL {
    root.appendingPathComponent("store").appendingPathComponent(store.relativePath(profileID: profile, name: name))
}

private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
private func mode(_ url: URL) throws -> Int {
    (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private let urlA = "https://example.com/subscription-a"
private let urlB = "https://example.com/subscription-b"

 do {
    try withStore { root, store, _ in
        try store.load()
        try check(store.records.isEmpty && store.legacySources.isEmpty, "empty load")
        let names = ["同名", "../escape/../../name", "a/b", "a_b", "Quote\"Name", "a", "A"]
        for name in names { try store.save(profileID: "profile-a", name: name, url: urlA, nodes: "nodes-a") }
        try store.save(profileID: "profile-b", name: names[0], url: urlB, nodes: "nodes-b")
        try check(Set(store.records.map(\.path)).count == names.count + 1, "hashed names and profiles do not alias")
        try check(store.relativePath(profileID: "profile-a", name: "../escape/../../name") ==
                  "./provider-files/\(Sha1.hex("profile-a"))/\(Sha1.hex("../escape/../../name")).yaml", "exact SHA1 double-key path")
        try check(store.source(profileID: "profile-a", name: names[0])?.url == urlA &&
                  store.source(profileID: "profile-b", name: names[0])?.url == urlB, "same name retains isolated source URLs")
        try check(text(node(root, store, "profile-a", names[0])) == "nodes-a" &&
                  text(node(root, store, "profile-b", names[0])) == "nodes-b", "same name retains isolated nodes")
        let base = root.appendingPathComponent("store")
        try check(mode(base) == 0o700 && mode(base.appendingPathComponent("provider-files")) == 0o700 &&
                  mode(node(root, store, "profile-a", names[0]).deletingLastPathComponent()) == 0o700, "directories are 0700")
        try check(mode(base.appendingPathComponent("provider-sources-v2.json")) == 0o600 &&
                  mode(node(root, store, "profile-a", names[0])) == 0o600, "index and nodes are 0600")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent("provider-files").path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node(root, store, "profile-a", names[0]).deletingLastPathComponent().path)
        let reloaded = ProviderSourceStore(baseDirectory: base)
        try reloaded.load()
        try check(reloaded.records == store.records, "records survive new instance reload")
        try check(mode(base.appendingPathComponent("provider-files")) == 0o700 &&
                  mode(node(root, store, "profile-a", names[0]).deletingLastPathComponent()) == 0o700,
                  "load tightens existing provider directory permissions")
        try check(!fm.fileExists(atPath: base.appendingPathComponent("manifest.json").path), "never writes a manifest")
        try store.updateNodes(profileID: "profile-b", name: names[0], nodes: "refreshed")
        try check(text(node(root, store, "profile-b", names[0])) == "refreshed" &&
                  store.source(profileID: "profile-b", name: names[0])?.url == urlB, "refresh preserves source URL")
        rejects("refresh refuses unbound source") { try store.updateNodes(profileID: "missing", name: "n", nodes: "bad") }
        try store.remove(profileID: "profile-a", name: names[0])
        try check(!fm.fileExists(atPath: node(root, store, "profile-a", names[0]).path) &&
                  text(node(root, store, "profile-b", names[0])) == "refreshed", "remove does not affect another profile")
        let profileDirectory = node(root, store, "profile-a", names[0]).deletingLastPathComponent()
        try Data("orphan".utf8).write(to: profileDirectory.appendingPathComponent("orphan.yaml"))
        try store.removeProfile("profile-a")
        try check(!fm.fileExists(atPath: profileDirectory.path), "removeProfile clears owned directory including orphan nodes")
        try check(store.records.count == 1 && store.records[0].profileID == "profile-b", "removeProfile isolates records")
        try check(names.allSatisfy { !fm.fileExists(atPath: node(root, store, "profile-a", $0).path) }, "removeProfile deletes owned nodes")
    }

    try withStore { root, store, io in
        try store.save(profileID: "p", name: "n", url: urlA, nodes: "old")
        let file = node(root, store, "p", "n")
        let index = root.appendingPathComponent("store/provider-sources-v2.json")
        let before = store.records
        let beforeIndex = try Data(contentsOf: index)
        io.failNextIndexWrite = true
        rejects("failed index save throws") { try store.save(profileID: "p", name: "n", url: urlB, nodes: "new") }
        try check(store.records == before && text(file) == "old" && Data(contentsOf: index) == beforeIndex,
                  "failed save restores nodes/index and never publishes memory")
        io.failNextIndexWrite = true
        rejects("new record index failure throws") { try store.save(profileID: "p", name: "new", url: urlB, nodes: "new") }
        try check(store.records == before && !fm.fileExists(atPath: node(root, store, "p", "new").path), "new node deleted during rollback")
        io.failNextIndexWrite = true
        rejects("failed refresh index throws") { try store.updateNodes(profileID: "p", name: "n", nodes: "new") }
        try check(text(file) == "old" && store.records == before, "failed refresh restores node bytes")
        io.failNextIndexWrite = true
        rejects("failed remove index throws") { try store.remove(profileID: "p", name: "n") }
        try check(text(file) == "old" && store.records == before, "failed remove restores node bytes and record")
        let snapshot = try store.snapshot(profileID: "p", name: "n")
        try store.save(profileID: "p", name: "n", url: urlB, nodes: "new")
        io.failNextIndexWrite = true
        rejects("failed outer restore throws") { try store.restore(snapshot: snapshot) }
        try check(text(file) == "new" && store.source(profileID: "p", name: "n")?.url == urlB,
                  "failed outer restore rolls back to its own entry state")
        try store.save(profileID: "other", name: "n", url: urlB, nodes: "other")
        try store.restore(snapshot: snapshot)
        try check(text(file) == "old" && store.source(profileID: "p", name: "n")?.url == urlA &&
                  store.source(profileID: "other", name: "n")?.url == urlB, "outer transaction restore leaves unrelated record untouched")
        let empty = try store.snapshot(profileID: "p", name: "empty")
        try store.save(profileID: "p", name: "empty", url: urlB, nodes: "new")
        try store.restore(snapshot: empty)
        try check(store.source(profileID: "p", name: "empty") == nil &&
                  !fm.fileExists(atPath: node(root, store, "p", "empty").path), "empty snapshot restore removes new owned target")
        let foreign = ProviderSourceStore(baseDirectory: root.appendingPathComponent("foreign"))
        rejects("foreign snapshot rejected") { try foreign.restore(snapshot: snapshot) }
        // A record with a missing file must restore that absence, not an empty file.
        try fm.removeItem(at: file)
        let missing = try store.snapshot(profileID: "p", name: "n")
        try store.save(profileID: "p", name: "n", url: urlB, nodes: "new")
        try store.restore(snapshot: missing)
        try check(store.source(profileID: "p", name: "n")?.url == urlA && !fm.fileExists(atPath: file.path),
                  "snapshot distinguishes missing old nodes")
    }

    try withStore { root, store, io in
        try store.save(profileID: "p", name: "a", url: urlA, nodes: "a")
        try store.save(profileID: "p", name: "b", url: urlB, nodes: "b")
        io.failNextIndexWrite = true
        rejects("failed profile removal throws") { try store.removeProfile("p") }
        try check(store.records.count == 2 && text(node(root, store, "p", "a")) == "a" &&
                  text(node(root, store, "p", "b")) == "b", "profile removal rolls back every node")
        let base = root.appendingPathComponent("store")
        let legacy = base.appendingPathComponent("provider-sources.json")
        try JSONEncoder().encode(["a": urlA, "legacy-only": urlB]).write(to: legacy)
        let legacyNode = base.appendingPathComponent("provider-files/old-slug.yaml")
        try Data("legacy".utf8).write(to: legacyNode)
        try store.load()
        try check(store.legacySources == ["a": urlA, "legacy-only": urlB] && mode(legacy) == 0o600, "legacy URLs loaded without inferred ownership")
        rejects("ambiguous legacy migration requires rebinding") { try store.migrateLegacy(profileID: "p", name: "a") }
        try store.save(profileID: "rebound", name: "a", url: urlB, nodes: "explicit")
        try check(store.legacySources["a"] == urlA && text(legacyNode) == "legacy", "explicit rebind preserves legacy data")
        io.failedRemoval = "provider-files"
        let before = store.records
        rejects("removeAll directory failure throws") { try store.removeAll() }
        try check(store.records == before && store.legacySources.count == 2 && text(legacyNode) == "legacy" &&
                  text(node(root, store, "p", "a")) == "a", "removeAll restores legacy and node tree after failure")
        try store.removeAll()
        try check(store.records.isEmpty && store.legacySources.isEmpty && !fm.fileExists(atPath: legacy.path) &&
                  !fm.fileExists(atPath: base.appendingPathComponent("provider-files").path) &&
                  !fm.fileExists(atPath: base.appendingPathComponent("provider-sources-v2.json").path), "removeAll clears legacy URLs, index and provider-files directory")
        try store.load()
        try check(store.records.isEmpty && store.legacySources.isEmpty, "cleared records stay cleared after reload")
    }

    try withStore { root, store, _ in
        try store.save(profileID: "p", name: "n", url: urlA, nodes: "old")
        let before = store.records
        let base = root.appendingPathComponent("store")
        let index = base.appendingPathComponent("provider-sources-v2.json")
        let good = try Data(contentsOf: index)
        try Data("broken".utf8).write(to: index)
        rejects("malformed index load throws") { try store.load() }
        try check(store.records == before, "malformed index leaves memory untouched")
        let malicious: [String: Any] = ["version": 2, "records": [["profileID": "p", "name": "n", "url": urlA, "path": "../../outside"]]]
        try JSONSerialization.data(withJSONObject: malicious).write(to: index)
        rejects("index path traversal rejected") { try store.load() }
        try good.write(to: index)
        try Data("broken".utf8).write(to: base.appendingPathComponent("provider-sources.json"))
        rejects("malformed legacy load throws") { try store.load() }
        try check(store.records == before, "malformed legacy does not drop existing records")
    }

    try withStore { root, store, _ in
        try store.load()
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let marker = outside.appendingPathComponent("marker")
        try Data("untouched".utf8).write(to: marker)
        let files = root.appendingPathComponent("store/provider-files")
        try fm.createSymbolicLink(at: files, withDestinationURL: outside)
        rejects("symlink provider root blocks save") { try store.save(profileID: "p", name: "n", url: urlA, nodes: "bad") }
        rejects("symlink provider root blocks removeAll") { try store.removeAll() }
        try check(text(marker) == "untouched" && store.records.isEmpty, "symlink rejection never changes outside files")
    }

    try withStore { root, store, _ in
        try store.save(profileID: "p", name: "n", url: urlA, nodes: "old")
        let files = root.appendingPathComponent("store/provider-files")
        let dangling = files.appendingPathComponent("dangling.yaml")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing.yaml"))
        rejects("dangling symlink blocks clear before mutations") { try store.removeAll() }
        try check(text(node(root, store, "p", "n")) == "old" && store.records.count == 1,
                  "cleanup preflight preserves valid nodes when sibling unsafe")
    }

    try withStore { root, store, _ in
        let empty = try store.snapshot(profileID: "p", name: "n")
        try store.save(profileID: "p", name: "n", url: urlA, nodes: "old")
        let file = node(root, store, "p", "n")
        let outside = root.appendingPathComponent("outside.yaml")
        try Data("outside".utf8).write(to: outside)
        // The test deletes only the exact freshly generated node in its temp root.
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: outside)
        rejects("nil snapshot restore rejects replaced symlink target") { try store.restore(snapshot: empty) }
        try check(text(outside) == "outside" && store.records.count == 1, "restore never follows/deletes outside symlink destination")
    }

    try withStore { root, store, _ in
        try store.save(profileID: "p", name: "n", url: urlA, nodes: "old")
        let file = node(root, store, "p", "n")
        let outside = root.appendingPathComponent("hardlink.yaml")
        try fm.linkItem(at: file, to: outside)
        rejects("hardlinked nodes block updates") { try store.updateNodes(profileID: "p", name: "n", nodes: "bad") }
        rejects("hardlinked nodes block cleanup") { try store.removeAll() }
        try check(text(outside) == "old", "hardlinked outside bytes unchanged")
    }
} catch {
    failed += 1
    // Never print Foundation's detailed URL/path-bearing errors.
    let nsError = error as NSError
    print("FAIL unexpected test setup or IO error (\(nsError.domain):\(nsError.code))")
}

print("ProviderSourceStore: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
