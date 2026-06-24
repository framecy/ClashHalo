import Foundation
import CryptoKit

/// SHA1 hex digest of a string. Used to deduplicate engine reloads
/// when a Profile's YAML content is unchanged from the last applied version.
/// macOS 10.15+ standard library, no third-party dependency.
enum Sha1 {
    static func hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
