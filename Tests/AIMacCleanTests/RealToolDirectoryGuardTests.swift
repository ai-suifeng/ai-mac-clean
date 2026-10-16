import XCTest

/// Seam A2：路径是否落在禁区目录之下。
///
/// 判定是纯字符串运算：护栏不允许为了「确认一下」去 stat 真实目录。
final class RealToolDirectoryGuardTests: XCTestCase {

    private let home = "/Users/example"
    private let workingDirectory = "/Users/example/code"

    private func makeGuard(_ entries: [String] = ["~/.claude", "~/.cursor", "~/Library/Application Support/Cursor"])
        throws -> RealToolDirectoryGuard
    {
        RealToolDirectoryGuard(
            list: try ForbiddenRealToolDirectoryList.parse(entries.joined(separator: "\n"), homeDirectory: home)
        )
    }

    func test落在禁区根之下的路径被判违规() throws {
        let violation = try makeGuard().violation(forPath: "/Users/example/.claude/projects/foo")

        XCTAssertEqual(violation?.root.homeRelativePath, "~/.claude")
        XCTAssertEqual(violation?.path, "/Users/example/.claude/projects/foo")
    }

    func test禁区根本身被判违规() throws {
        let violation = try makeGuard().violation(forPath: "/Users/example/.cursor")

        XCTAssertEqual(violation?.root.homeRelativePath, "~/.cursor")
    }

    func test带尾斜杠的禁区路径同样被判违规() throws {
        let violation = try makeGuard().violation(forPath: "/Users/example/.cursor/")

        XCTAssertEqual(violation?.root.homeRelativePath, "~/.cursor")
    }

    func test与禁区同前缀的兄弟目录不算违规() throws {
        // 实测：~/.claudebak、~/.claude-tap、~/.codexbar 名字像工具，但不是工具本身。
        for path in ["/Users/example/.claudebak", "/Users/example/.claude-tap", "/Users/example/.codexbar"] {
            XCTAssertNil(try makeGuard().violation(forPath: path), "\(path) 不该被判违规")
        }
    }

    func test主目录本身不算违规() throws {
        XCTAssertNil(try makeGuard().violation(forPath: "/Users/example"))
    }

    func test上层穿越回到禁区的路径被判违规() throws {
        let violation = try makeGuard().violation(forPath: "/Users/example/tmp/../.claude/projects")

        XCTAssertEqual(violation?.root.homeRelativePath, "~/.claude")
    }

    func test大小写不同的禁区路径被判违规() throws {
        // APFS 默认大小写不敏感：`~/.CURSOR` 指的就是同一个目录。
        let violation = try makeGuard().violation(forPath: "/Users/EXAMPLE/.Cursor/History")

        XCTAssertEqual(violation?.root.homeRelativePath, "~/.cursor")
    }

    func test相对路径按当前工作目录解析() throws {
        // 相对路径的危险形态：进程 cwd 恰好是主目录时，「相对」并不代表「安全」。
        let violation = try makeGuard().violation(
            forPath: ".claude/projects/foo",
            workingDirectory: home
        )

        XCTAssertEqual(violation?.path, "/Users/example/.claude/projects/foo")
    }

    func test相对路径基准在主目录之外时不算违规() throws {
        XCTAssertNil(
            try makeGuard().violation(forPath: ".claude/projects/foo", workingDirectory: workingDirectory)
        )
    }

    func test临时目录不在任何禁区之下() throws {
        let violation = try makeGuard().violation(forPath: "/var/folders/xy/T/ai-mac-clean-tests/demo-1/.claude")

        XCTAssertNil(violation, "临时目录树里的 `.claude` 是假目录，必须放行")
    }

    func test违规描述同时给出路径命中根与来源() throws {
        let violation = try XCTUnwrap(
            try makeGuard().violation(forPath: "/Users/example/.claude/projects/foo")
        )

        let text = violation.report(source: "Seam 1 发现管线")
        XCTAssertTrue(text.contains("/Users/example/.claude/projects/foo"), text)
        XCTAssertTrue(text.contains("~/.claude"), text)
        XCTAssertTrue(text.contains("Seam 1 发现管线"), text)
    }
}
