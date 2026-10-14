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
}
