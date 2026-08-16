import Foundation
import Security

// MARK: - Keychain Security Helper

/// Secrets store for subscription URLs, Tailscale auth-key / API token, etc.
///
/// ## Why this is not a plain `SecItemAdd`
///
/// ClashHalo ships **ad-hoc signed** (`codesign -s -`, no Team ID, no keychain
/// access-group entitlement). On that path the Security framework defaults
/// every generic-password item's ACL to *the current code-signing identity*.
/// Rebuilding, reinstalling from a new DMG, or even a fresh ad-hoc re-sign of
/// the same binary produces a **different** identity, so the next launch's
/// `SecItemCopyMatching` silently returns `errSecItemNotFound` even though
/// Keychain Access still shows the entry. That is exactly the "升级 / 重装后
/// Tailscale key 丢了" bug — and the same trap for subscription URLs.
///
/// Fix, two layers:
///
/// 1. **Open ACL on write** (`SecAccessCreate` with `trustedList: nil` — any app).
///    Do **not** pass an empty CFArray: that means *no* app may use the item.
///    Any future binary on this Mac can then read the item, which is the right
///    trade-off for a local-only, non-sandboxed desktop app whose whole point
///    is that the secret must survive the next rebuild.
/// 2. **File mirror** under Application Support. The data directory is not
///    tied to code signing and survives app reinstall. On a Keychain miss we
///    recover from the mirror and re-write the Keychain entry under the new
///    identity, so the next read is cheap again. Mode `0600`, contents base64
///    (obscurity only — there is no KEK that outlives reinstall either).
///
/// Callers stay unchanged: `save` / `read` / `delete`.
struct KeychainHelper {
    static let service = "com.clashhalo.secrets"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Always refresh the mirror first so a Keychain ACL failure still leaves
        // a recoverable copy. Mirror write is best-effort and never blocks the
        // Keychain path.
        writeMirror(account: key, value: value)

        // Delete any prior item (possibly locked to an old code-signing
        // identity we can no longer read) so SecItemAdd cannot collide.
        deleteKeychainItem(account: key)

        // Prefer an open ACL so the next ad-hoc re-sign can still read the
        // item. `kSecAttrAccess` and `kSecAttrAccessible` are mutually
        // exclusive — never set both on the same add. Fall back to the
        // protection-class-only form if SecAccessCreate is unavailable.
        var status = errSecParam
        if let access = openAccess(descriptor: "ClashHalo secret \(key)") {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccess as String: access
            ]
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // Either SecAccessCreate failed, or the open-ACL add was rejected.
            // Retry with the classic protection class so a secret is still
            // written; the mirror covers reinstall either way.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            status = SecItemAdd(query as CFDictionary, nil)
        }
        // Mirror alone is enough to survive reinstall; treat Keychain success
        // as nice-to-have so a transient errSec* does not lose the secret.
        return status == errSecSuccess || mirrorExists(account: key)
    }

    static func read(key: String) -> String? {
        // File mirror first. The mirror is not tied to code-signing identity
        // and never blocks, so checking it before touching the Keychain avoids
        // the authorization-dialog stall that happens when the Keychain item
        // is ACL-locked to a *previous* ad-hoc signing identity.
        if let mirrored = readMirror(account: key), !mirrored.isEmpty {
            // Best-effort: re-seed the Keychain under the current identity in
            // the background so the next read *might* hit the fast path. This
            // is fire-and-forget; the mirror already has the value.
            let k = key, v = mirrored
            Task.detached(priority: .utility) { _ = save(key: k, value: v) }
            return mirrored
        }
        // No mirror — the Keychain is the only source. This can block if the
        // item is ACL-locked, but at this point there is no alternative.
        if let value = readKeychainItem(account: key) {
            _ = save(key: key, value: value)   // establish the mirror
            return value
        }
        return nil
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let kc = deleteKeychainItem(account: key)
        let mir = deleteMirror(account: key)
        return kc || mir
    }

    /// Eagerly re-persist well-known accounts so the open ACL + mirror land
    /// *before* the next rebuild, even if nothing in this session would have
    /// called `read` on them (e.g. Tailnet disabled, so the auth key is never
    /// pulled into the overlay). Safe to call every launch — `read` checks the
    /// mirror first and only touches the Keychain when the mirror is missing.
    static func migrateKnownAccounts(_ accounts: [String]) {
        for account in accounts where !account.isEmpty {
            _ = read(key: account)
        }
    }

    // MARK: Keychain primitives

    private static func readKeychainItem(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // Suppress the authorization dialog. When a Keychain item is ACL-locked
        // to a previous ad-hoc signing identity, SecItemCopyMatching shows an
        // authorization panel that blocks forever in a headless launch. Telling
        // the framework not to interact turns that into a clean errSecItemNotFound
        // / errSecInteractionNotAllowed, which we treat as "item not available" —
        // the caller falls through to the file mirror or returns nil.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess, let data = dataTypeRef as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func deleteKeychainItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is success for "make sure it's gone".
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Build an ACL that does **not** pin the item to the current code-signing
    /// identity.
    ///
    /// `SecAccessCreate`'s second argument is decisive:
    ///   - `NULL`  → any application may use the item (what we want)
    ///   - empty array → **no** application may use the item
    ///   - non-empty  → only those trusted apps
    /// Passing an empty CFArray here would silently lock the secret harder
    /// than the default — the exact opposite of the fix. Always pass nil.
    ///
    /// `SecAccessCreate` has been annotated deprecated since 10.10; its
    /// replacement (`SecAccessControl`) cannot express "any app on this Mac"
    /// without a keychain-access-groups entitlement and Team ID, which an
    /// ad-hoc build does not have. The warning is accepted noise.
    private static func openAccess(descriptor: String) -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate(descriptor as CFString, nil, &access)
        guard status == errSecSuccess else { return nil }
        return access
    }

    // MARK: Application Support mirror
    //
    // Layout: ~/Library/Application Support/ClashHalo/secrets/<sha1(account)>.token
    // Account names are hashed so a Tailscale key filename never literally
    // contains "authkey" in a directory listing, and so odd characters in
    // subscription profile UUIDs cannot break the path.

    /// Exposed for the regression suite — pure path derivation, no I/O.
    static func mirrorFileName(forAccount account: String) -> String {
        Sha1.hex("\(service)|\(account)") + ".token"
    }

    /// Override point for the regression suite so tests never touch the real
    /// Application Support tree. Production always leaves this `nil`.
    static var mirrorDirectoryOverride: URL?

    static var mirrorDirectory: URL {
        if let override = mirrorDirectoryOverride { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClashHalo/secrets",
                                    isDirectory: true)
    }

    private static func mirrorURL(account: String) -> URL {
        mirrorDirectory.appendingPathComponent(mirrorFileName(forAccount: account),
                                               isDirectory: false)
    }

    private static func mirrorExists(account: String) -> Bool {
        FileManager.default.fileExists(atPath: mirrorURL(account: account).path)
    }

    private static func writeMirror(account: String, value: String) {
        let fm = FileManager.default
        let dir = mirrorDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            // base64 is deliberate obscurity, not encryption: a local attacker
            // with filesystem access already owns the machine. What we need is
            // survival across app reinstall, which raw Keychain does not give
            // an ad-hoc-signed binary.
            let payload = Data(value.utf8).base64EncodedData()
            let url = mirrorURL(account: account)
            try payload.write(to: url, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort: Keychain may still hold the secret. Swallowing here
            // keeps save()/read() signatures simple for every caller.
        }
    }

    private static func readMirror(account: String) -> String? {
        let url = mirrorURL(account: account)
        guard let data = try? Data(contentsOf: url),
              let decoded = Data(base64Encoded: data),
              let value = String(data: decoded, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    private static func deleteMirror(account: String) -> Bool {
        let url = mirrorURL(account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Tailscale credential keys (Keychain account names)

/// Keychain account names for Tailscale integration. Values themselves are
/// stored via `KeychainHelper` under the existing `com.clashhalo.secrets`
/// service — same mechanism as subscription URLs. Distinct accounts here so a
/// subscription profile can never collide with a Tailscale auth key.
let kTailscaleAuthKey  = "tailscale.authkey"
let kTailscaleAPIToken = "tailscale.api.token"

/// Mask a `tskey-…` string for display. `tskey-auth-xxxxxBLOWUP` → `tskey-auth-xxxxx…UP`.
func maskTailscaleKey(_ s: String) -> String {
    guard s.count > 10 else { return String(repeating: "•", count: s.count) }
    let head = s.prefix(16)
    let tail = s.suffix(2)
    return "\(head)…\(tail)"
}

