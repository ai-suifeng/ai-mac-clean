import XCTest

import AIMacCleanPathGuard

/// 验收演示：证明「一旦测试去碰真实 AI 工具数据目录，这轮测试就会失败」
/// （issue #14 验收第 1 条）。
///
/// 这个用例是**故意写错的**：它假设自己能读到 `~/.claude`。
///   - 护栏生效时：内核拒绝 → 断言挂掉 → 本轮测试失败（这正是要证明的行为）。
///   - 关掉护栏时：断言通过 → 恰好反证「失败是由护栏造成的，不是别的原因」。
///
/// 因此它默认不跑，只有设 AMC_TEST_GUARD_DEMO=1 才启用；由
/// `Scripts/run-tests.sh --demo-violation` 驱动，并**期望**它失败。
///
/// 安全：只请求列目录，拿不到任何内容；护栏生效时内核在打开之前就拒绝了。
final class PathGuardViolationDemoTests: XCTestCase {

    private func requireDemoEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AMC_TEST_GUARD_DEMO"] == "1",
            "违规演示只在 AMC_TEST_GUARD_DEMO=1 时运行（见 Scripts/run-tests.sh --demo-violation）"
        )
        // 护栏不在就跳过，而不是「让它真的去读」——那个对照组本身就是本规则禁止的行为。
        // 需要对照组证据时用 TestSupport/probe/guard-self-check.c（只做元数据 stat）。
        try XCTSkipUnless(
            amc_path_guard_is_armed(),
            "护栏未装载：本演示会真的读到真实目录，按 issue #14 的规则必须跳过"
        )
    }

    func test演示_列出真实工具目录的测试会被护栏拦下() throws {
        try requireDemoEnabled()

        let realDirectory = NSHomeDirectory() + "/.claude"
        let contents = try? FileManager.default.contentsOfDirectory(atPath: realDirectory)

        XCTAssertNotNil(
            contents,
            """
            护栏没有拦住对 \(realDirectory) 的访问。
            若本用例通过，说明内核沙箱失效——这是本演示要暴露的失败模式。
            """
        )
    }

    func test演示_读取真实工具目录下的文件会被护栏拦下() throws {
        try requireDemoEnabled()

        let realDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/.codex", isDirectory: true)
        let entries = try? FileManager.default.contentsOfDirectory(
            at: realDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )

        XCTAssertNotNil(
            entries,
            """
            护栏没有拦住对 \(realDirectory.path) 的访问。
            若本用例通过，说明内核沙箱失效——这是本演示要暴露的失败模式。
            """
        )
    }
}
