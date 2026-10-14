import XCTest

import AIMacCleanCore
import AIMacCleanPathGuard

/// 护栏自检：证明「测试禁止触碰真实 AI 工具数据目录」这条规则是**自动化生效**的，
/// 而不是靠自觉（issue #14 / spec #7「构造数据的纪律」第 1 条）。
///
/// 本文件里的用例在每次测试运行时都会跑：护栏一旦失效，它们会立刻失败，
/// 不会出现「护栏悄悄没装上」的情况。
final class PathGuardSelfCheckTests: XCTestCase {

    private var home: String { NSHomeDirectory() }

    /// 对一条路径做纯元数据 stat，返回 (是否成功, errno)。不读内容、不枚举、不写。
    private func statMetadata(of path: String) -> (succeeded: Bool, code: Int32) {
        var info = stat()
        var result: Int32 = -1
        var code: Int32 = 0
        path.withCString { pointer in
            errno = 0
            result = stat(pointer, &info)
            code = errno
        }
        return (result == 0, code)
    }

    func test护栏已在本进程装载() {
        XCTAssertTrue(
            amc_path_guard_is_armed(),
            "护栏没有装载：内核沙箱未生效，本次测试运行不受保护"
        )
        XCTAssertGreaterThan(amc_path_guard_root_count(), 0, "禁区清单是空的")
        let log = String(cString: amc_path_guard_armed_log())
        XCTAssertTrue(
            log.contains("护栏已装载"),
            "装载日志缺失，入口脚本与 CI 没法校验护栏：\(log)"
        )
    }

    func test访问真实工具目录被内核拒绝() {
        let outcome = statMetadata(of: home + "/.claude")

        XCTAssertFalse(outcome.succeeded, "stat 竟然成功了，说明内核沙箱没在拦")
        XCTAssertEqual(
            outcome.code,
            EPERM,
            "errno=\(outcome.code)，期望 EPERM（内核沙箱拒绝）"
        )
    }

    func test临时目录仍然可以正常访问() {
        // 护栏不能变成「什么都拒绝」：临时目录必须照常可读可写，否则测试没法跑。
        let outcome = statMetadata(of: FileManager.default.temporaryDirectory.path)

        XCTAssertTrue(
            outcome.succeeded,
            "临时目录被误伤（errno=\(outcome.code)）——护栏过度拦截了"
        )
    }

    func test内核层与Swift层的判定结论一致() throws {
        // 两层实现独立（一份 C、一份 Swift），必须给出同一个答案，否则诊断会互相打架。
        let swiftGuard = try RealToolDirectoryGuard(list: ForbiddenRealToolDirectoryList.load())
        let temporary = FileManager.default.temporaryDirectory.path
        let cases: [(path: String, blocked: Bool)] = [
            (home + "/.claude/projects", true),
            (home + "/.cursor/User/History", true),
            (home + "/.local/share/opencode/storage", true),
            // 同前缀的兄弟目录不是工具本身（实测：~/.claude-tap、~/.codexbar）。
            (home + "/.claude-tap", false),
            (home + "/.codexbar", false),
            (home + "/Downloads", false),
            (temporary + "demo", false),
        ]

        for testCase in cases {
            var rootBuffer = [CChar](repeating: 0, count: 4096)
            let kernelSaysBlocked = amc_path_guard_check_path(
                testCase.path,
                &rootBuffer,
                4096,
                nil,
                0
            ) != 0
            let swiftSaysBlocked = swiftGuard.violation(forPath: testCase.path) != nil

            XCTAssertEqual(kernelSaysBlocked, testCase.blocked, "内核层判定与预期不符：\(testCase.path)")
            XCTAssertEqual(swiftSaysBlocked, kernelSaysBlocked, "两层判定不一致：\(testCase.path)")
        }
    }

    func test内核层给出的禁区根是绝对路径() {
        var rootBuffer = [CChar](repeating: 0, count: 4096)
        let blocked = amc_path_guard_check_path(
            home + "/.codex/sessions",
            &rootBuffer,
            4096,
            nil,
            0
        ) != 0

        XCTAssertTrue(blocked)
        let root = String(cString: rootBuffer)
        XCTAssertEqual(root, home + "/.codex")
        XCTAssertTrue(root.hasPrefix("/"), "禁区根应是绝对路径，实际：\(root)")
    }

    func test内核层判定不需要路径真实存在() {
        // 纯字面判定：一条不存在的路径照样按「落在禁区之下」拒绝，
        // 证明护栏没有为了确认而去 stat 真实目录。
        var rootBuffer = [CChar](repeating: 0, count: 4096)
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let blocked = amc_path_guard_check_path(
            home + "/.gemini/amc-does-not-exist/sessions",
            &rootBuffer,
            4096,
            &pathBuffer,
            4096
        )

        XCTAssertNotEqual(blocked, 0)
        XCTAssertEqual(String(cString: pathBuffer), home + "/.gemini/amc-does-not-exist/sessions")
        XCTAssertEqual(String(cString: rootBuffer), home + "/.gemini")
    }
}
