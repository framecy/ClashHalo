import Foundation

@MainActor
func runTests() async {
    var passed = 0, failed = 0
    func expect(_ condition: Bool, _ label: String) {
        if condition { passed += 1; print("✓ \(label)") }
        else { failed += 1; print("✗ \(label)") }
    }
    let queue = ProviderOperationQueue()
    var order: [String] = []
    let first = Task { @MainActor in
        try await queue.run {
            order.append("A-write")
            try? await Task.sleep(nanoseconds: 10_000_000)
            order.append("A-rollback")
            throw ProviderOperationError.message("示例失败")
        }
    }
    await Task.yield()
    let second = Task { @MainActor in
        try await queue.run { order.append("B-write"); return true }
    }
    _ = try? await first.value
    _ = try? await second.value
    expect(order == ["A-write", "A-rollback", "B-write"], "前笔失败回滚完整结束才开始后笔")

    var state = "old"
    var applied = false
    do {
        try await ProviderCommit.run(write: { state = "new" }, validate: {}, apply: { applied = true }, rollback: { state = "old" })
        expect(state == "new" && applied, "成功包含写入和应用确认")
    } catch { expect(false, "成功链不得抛错") }
    for stage in ["write", "validate", "apply"] {
        state = "old"
        do {
            try await ProviderCommit.run(write: {
                state = "new"
                if stage == "write" { throw ProviderOperationError.message("write") }
            }, validate: {
                if stage == "validate" { throw ProviderOperationError.message("validate") }
            }, apply: {
                if stage == "apply" { throw ProviderOperationError.message("apply") }
            }, rollback: { state = "old" })
            expect(false, "\(stage) 失败不能返回成功")
        } catch { expect(state == "old", "\(stage) 失败恢复原数据") }
    }
    do {
        try await ProviderCommit.run(write: { throw ProviderOperationError.message("失败") }, validate: {}, apply: {}, rollback: {
            throw ProviderOperationError.message("回滚失败")
        })
        expect(false, "回滚失败必须报告")
    } catch { expect(error.localizedDescription.contains("未能完整回滚"), "回滚失败不能宣称原配置已保留") }

    var finished = false
    let cancellation = Task { @MainActor in
        try await queue.run {
            try? await Task.sleep(nanoseconds: 10_000_000)
            finished = true
        }
    }
    await Task.yield()
    cancellation.cancel()
    _ = try? await cancellation.value
    expect(finished, "取消等待者不会中断提交")
    print("ProviderOperation: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
Task { @MainActor in await runTests() }
dispatchMain()
