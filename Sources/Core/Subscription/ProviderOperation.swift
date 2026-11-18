import Foundation

/// 配置持久化共用串行队列。等待者取消不截断已经开始的提交/回滚。
/// 内核生命周期仍由 engine.isBusy 门控；队列避免设置事务与订阅事务交错回滚。
@MainActor
final class ProviderOperationQueue {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    func run<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        generation &+= 1
        let current = generation
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { @MainActor in
            _ = try? await task.value
            if self.generation == current { self.tail = nil }
        }
        return try await task.value
    }
}

/// 提交错误不携带配置、节点、URL 或底层网络响应，避免 Toast/日志泄漏凭据。
enum ProviderOperationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// 生产提交与测试共用的失败语义：成功必须包含应用确认；任何阶段失败均尝试回滚。
@MainActor
enum ProviderCommit {
    static func run(write: () throws -> Void,
                    validate: () async throws -> Void,
                    apply: () async throws -> Void,
                    rollback: () async throws -> Void) async throws {
        do {
            try write()
            try await validate()
            try await apply()
        } catch {
            let failure = error
            do { try await rollback() }
            catch { throw ProviderOperationError.message("操作失败，且未能完整回滚；请检查配置文件后再试") }
            throw failure
        }
    }
}
