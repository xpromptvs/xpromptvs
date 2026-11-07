import XCTest

/// A BOUNDED spin. An unbounded one turns a broken expectation into a HUNG test, which a mutation
/// run pays for at the full Bazel timeout — measured at 300 s per mutant before this existed.
func waitUntil(_ condition: @Sendable () -> Bool, _ what: String,
               file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

/// The same bound around a task's result: `await task.value` on a task that will never finish is
/// the other way a mutant hangs instead of failing.
func valueOrTimeout<T: Sendable>(_ task: Task<T, Never>, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) async -> T? {
    let race = Task<T?, Never> {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    let result = await race.value
    if result == nil { XCTFail("timed out waiting for \(what)", file: file, line: line) }
    return result
}
