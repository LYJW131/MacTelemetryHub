import Foundation
import Testing

@testable import TelemetryCore

/// `isAvailable` / `noteFailure` 都是 mutating（冷却到点的清零发生在里面），
/// 而 `#expect` 的宏展开按不可变捕获，所以每次调用都先落到局部变量再断言。
struct IconUploadBudgetTests {
    private let start = Date(timeIntervalSince1970: 1_789_099_506)
    private let hash = "icon-hash"

    @Test func backoffGrowsTwoFourEightAndExhaustsAfterThreeFailures() {
        var budget = IconUploadBudget()
        var available = budget.isAvailable(hash, now: start)
        #expect(available)

        let first = budget.noteFailure(hash, now: start)
        #expect(first == (1, .seconds(2)))
        available = budget.isAvailable(hash, now: start)
        #expect(available)

        let second = budget.noteFailure(hash, now: start.addingTimeInterval(2))
        #expect(second == (2, .seconds(4)))
        available = budget.isAvailable(hash, now: start.addingTimeInterval(2))
        #expect(available)

        let third = budget.noteFailure(hash, now: start.addingTimeInterval(6))
        #expect(third == (3, .seconds(8)))
        #expect(budget.attemptCount(hash) == 3)
        // 三次用尽，此后不再试 —— 不然会打成热循环
        available = budget.isAvailable(hash, now: start.addingTimeInterval(6))
        #expect(!available)
    }

    /// 用尽不是永久放弃：过了冷却期从头来。从前是到进程重启为止，实测
    /// 启动初期一次瞬时 TLS 错误就能让某个应用的图标永久消失。
    @Test func cooldownResetsTheBudget() {
        var budget = IconUploadBudget()
        for _ in 0..<3 { _ = budget.noteFailure(hash, now: start) }

        var available = budget.isAvailable(
            hash, now: start.addingTimeInterval(IconUploadBudget.retryCooldown - 1)
        )
        #expect(!available)

        let due = start.addingTimeInterval(IconUploadBudget.retryCooldown)
        available = budget.isAvailable(hash, now: due)
        #expect(available)
        #expect(budget.attemptCount(hash) == 0)
        // 清零之后又是完整的三次
        let afterReset = budget.noteFailure(hash, now: due)
        #expect(afterReset == (1, .seconds(2)))
    }

    /// 额度按图标身份记，一个应用传不上去不该拖累别的。
    @Test func budgetIsPerIconHash() {
        var budget = IconUploadBudget()
        for _ in 0..<3 { _ = budget.noteFailure(hash, now: start) }
        let exhausted = budget.isAvailable(hash, now: start)
        let other = budget.isAvailable("other-hash", now: start)
        #expect(!exhausted)
        #expect(other)
    }

    @Test func successAndResetClearTheCount() {
        var budget = IconUploadBudget()
        _ = budget.noteFailure(hash, now: start)
        _ = budget.noteFailure(hash, now: start)
        budget.noteSuccess(hash)
        #expect(budget.attemptCount(hash) == 0)
        var available = budget.isAvailable(hash, now: start)
        #expect(available)

        for _ in 0..<3 { _ = budget.noteFailure(hash, now: start) }
        budget.removeAll()
        #expect(budget.attemptCount(hash) == 0)
        available = budget.isAvailable(hash, now: start)
        #expect(available)
    }
}
