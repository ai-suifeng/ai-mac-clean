import XCTest

@testable import AIMacCleanCore

/// Seam B：路径展示工具。home 目录由调用方注入，因此本 seam 既可在临时目录上验证，
/// 也不会去读真实用户主目录（PRD §13 第 3 条）。
final class DisplayPathTests: XCTestCase {

    private let home = "/Users/example"

    func test工具根目录在主目录下时缩写成波浪号() {
        XCTAssertEqual(
            DisplayPath.abbreviate("/Users/example/.codex", homeDirectory: home),
            "~/.codex"
        )
    }

    func test非标准位置的opencode数据同样缩写() {
        XCTAssertEqual(
            DisplayPath.abbreviate("/Users/example/.local/share/opencode", homeDirectory: home),
            "~/.local/share/opencode"
        )
    }

    func test主目录之外的路径原样展示() {
        XCTAssertEqual(
            DisplayPath.abbreviate("/Volumes/Archive/x", homeDirectory: home),
            "/Volumes/Archive/x"
        )
    }

    func test与主目录同前缀的兄弟目录不被误缩写() {
        // `/Users/example-backup` 以 `/Users/example` 开头，但不是主目录的子路径。
        XCTAssertEqual(
            DisplayPath.abbreviate("/Users/example-backup", homeDirectory: home),
            "/Users/example-backup"
        )
    }

    func test主目录本身缩写成波浪号() {
        XCTAssertEqual(DisplayPath.abbreviate(home, homeDirectory: home), "~")
    }

    func test尾部分隔符被规范化() {
        XCTAssertEqual(
            DisplayPath.abbreviate("/Users/example/.codex/", homeDirectory: home),
            "~/.codex"
        )
    }
}
