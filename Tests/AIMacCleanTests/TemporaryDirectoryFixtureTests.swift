import XCTest

@testable import AIMacCleanCore

/// Seam F：测试数据落地的唯一入口（PRD §13 第 3 条、spec #7「测试禁止触碰真实数据目录」）。
///
/// 本票只提供夹具与最小守卫；机械化拦截由 issue #14 落地。
final class TemporaryDirectoryFixtureTests: XCTestCase {

    func test夹具建在系统临时目录下而不是用户主目录() throws {
        let fixture = try TemporaryDirectoryFixture(named: "amc-fixture")
        defer { fixture.remove() }

        let path = fixture.url.path
        XCTAssertTrue(
            path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "测试夹具必须落在临时目录下，实际落在：\(path)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func test夹具可以写入并删除文件() throws {
        let fixture = try TemporaryDirectoryFixture(named: "amc-fixture-files")
        let projectsDirectory = try fixture.makeDirectory("projects")
        let fileURL = projectsDirectory.appendingPathComponent("demo.jsonl")

        try Data("{}".utf8).write(to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        fixture.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func test夹具名字相同时不会互相覆盖() throws {
        let first = try TemporaryDirectoryFixture(named: "amc-fixture-unique")
        let second = try TemporaryDirectoryFixture(named: "amc-fixture-unique")
        defer {
            first.remove()
            second.remove()
        }

        XCTAssertNotEqual(first.url, second.url)
    }

    func test夹具基址落在真实工具目录下时拒绝创建() throws {
        // 例如有人把 TMPDIR 指到了 ~/.claude/tmp：夹具宁可失败，也不能在真实目录里建假数据。
        let forbiddenBase = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/tmp", isDirectory: true)

        XCTAssertThrowsError(try TemporaryDirectoryFixture(named: "amc-fixture", baseDirectory: forbiddenBase)) { error in
            XCTAssertTrue("\(error)".contains("~/.claude"), "报错要指出命中的禁区，实际：\(error)")
        }
    }

    func test夹具落地的每个路径都通过护栏判定() throws {
        let fixture = try TemporaryDirectoryFixture(named: "amc-fixture-guarded")
        defer { fixture.remove() }

        let subdirectory = try fixture.makeDirectory("projects/demo")
        for path in [fixture.url.path, subdirectory.path] {
            XCTAssertNil(
                RealToolDirectoryGuard.live.violation(forPath: path),
                "\(path) 不该落在任何真实 AI 工具数据目录下"
            )
        }
    }
}
