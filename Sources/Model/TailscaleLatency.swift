enum TailscaleLatency {

    /// Whether a public URL delay test is meaningful for this node.
    ///
    /// Without an exit node (and without a broader route covering the test
    /// URL), mihomo fails the dial outright and does **not** fall back to
    /// direct. Running the regular group test against such a node paints it
    /// red forever — which is noise, not a signal. With an exit node the
    /// public URL is the right probe.
    static func usesPublicURLTest(nodeType: String, exitNode: String) -> Bool {
        guard nodeType.caseInsensitiveCompare("Tailscale") == .orderedSame
                || nodeType.caseInsensitiveCompare("tailscale") == .orderedSame else {
            return true   // not our concern
        }
        return !exitNode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sentinel written into `Node.delay` for a peer-only tailscale node so the
    /// UI can render "对等" instead of a red dash. Distinct from 0 (untested)
    /// and from any real RTT.
    static let peerOnlySentinel = -2
}
