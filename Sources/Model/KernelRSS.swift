import Foundation

// MARK: - Kernel resident memory
//
// The kernel runs as root (single-identity rule, v1.1.7), so the obvious API
// is unavailable: `proc_pid_rusage` and `proc_pidinfo` both return EPERM when
// the caller is not root and not the target's uid — verified against the live
// kernel on 2026-09-28 (`v2 rc=-1 errno=1`). Reading it from the helper would
// work but means a new XPC method and a forced `kSharedHelperVersion` bump for
// a number that is purely diagnostic.
//
// `ps` reads it without privilege, through the kernel's process table rather
// than the target's task port, and the app already shells out to `ps` for
// exactly this question — `EngineControl.managedKernels(at:)` enumerates the
// managed kernel by full executable path. Same command shape, same suffix
// match, one extra column, so the identification rules cannot drift apart
// between "which mihomo is mine" and "how much memory does it hold".
//
// This is a fork, not a syscall: callers keep it off the snapshot path and
// cache the result. See `AppModel.sampleKernelMemory()`.
enum KernelRSS {
    /// Kept identical to `EngineControl.managedKernels`' suffix. A foreign
    /// `mihomo` elsewhere on disk must not be measured, let alone reaped.
    static let kernelPathSuffix = "/Library/Application Support/ClashHalo/bin/mihomo"

    /// Resident bytes of the managed kernel, or nil when it is not running.
    nonisolated static func read() async -> Int64? {
        await withCheckedContinuation { (cont: CheckedContinuation<Int64?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/ps")
                p.arguments = ["-axww", "-o", "pid=,uid=,rss=,comm="]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()

                // KB, not bytes: that is the unit `ps -o rss` reports.
                var largest: Int64 = -1
                for row in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
                    // Hand-parsed for the same reason `managedKernels` is: the
                    // path lives under "Application Support", so the last
                    // column contains spaces and must be the whole remainder.
                    var rest = row.drop { $0 == " " }
                    guard let pidEnd = rest.firstIndex(of: " ") else { continue }
                    rest = rest[pidEnd...].drop { $0 == " " }
                    guard let uidEnd = rest.firstIndex(of: " ") else { continue }
                    rest = rest[uidEnd...].drop { $0 == " " }
                    guard let rssEnd = rest.firstIndex(of: " "),
                          let kb = Int64(rest[..<rssEnd]) else { continue }
                    let comm = String(rest[rssEnd...].drop { $0 == " " })
                    // Suffix as well as equality: `ps` can report the firmlinked
                    // `/System/Volumes/Data/Users/...` form of a home path.
                    guard comm.hasSuffix(kernelPathSuffix) else { continue }
                    if kb > largest { largest = kb }
                }
                cont.resume(returning: largest >= 0 ? largest * 1024 : nil)
            }
        }
    }
}
