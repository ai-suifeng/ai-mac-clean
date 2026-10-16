import Foundation
import XCTest

/// Seam A1：真实 AI 工具数据目录禁区清单的**解析**。
///
/// 清单的唯一来源是仓库里的 `TestSupport/ForbiddenRealToolDirectories.txt`，
/// C 拦截器与 Swift 断言层都从这一个文件读，不允许各写一份（issue #14）。
final class ForbiddenRealToolDirectoryListTests: XCTestCase {

    private let home = "/Users/example"

    func test清单文本解析出主目录锚定的绝对路径() throws {
        let list = try ForbiddenRealToolDirectoryList.parse("""
        ~/.claude
        ~/Library/Application Support/Cursor
        """, homeDirectory: home)

        XCTAssertEqual(list.roots.map(\.homeRelativePath), ["~/.claude", "~/Library/Application Support/Cursor"])
        XCTAssertEqual(list.roots[0].expandedPath, "/Users/example/.claude")
        XCTAssertEqual(
            list.roots[1].expandedPath,
            "/Users/example/Library/Application Support/Cursor"
        )
    }

    func test清单文本忽略空行与井号注释() throws {
        let list = try ForbiddenRealToolDirectoryList.parse("""
        # 禁区清单：测试禁止触碰

        ~/.codex

          # 缩进注释也算注释
        ~/.gemini
        """, homeDirectory: home)

        XCTAssertEqual(list.roots.map(\.homeRelativePath), ["~/.codex", "~/.gemini"])
    }

    func test清单文本允许写绝对路径() throws {
        let list = try ForbiddenRealToolDirectoryList.parse("/Applications/Cursor.app", homeDirectory: home)

        XCTAssertEqual(list.roots[0].expandedPath, "/Applications/Cursor.app")
        XCTAssertEqual(list.roots[0].homeRelativePath, "/Applications/Cursor.app")
    }

    func test清单文本出现重复条目时拒绝() {
        XCTAssertThrowsError(try ForbiddenRealToolDirectoryList.parse("""
        ~/.claude
        ~/.claude
        """, homeDirectory: home)) { error in
            XCTAssertTrue("\(error)".contains("重复"), "重复条目要给出可读原因，实际：\(error)")
        }
    }

    func test清单文本出现重复条目时大小写与尾斜杠差异也算重复() {
        XCTAssertThrowsError(try ForbiddenRealToolDirectoryList.parse("""
        ~/.Cursor
        ~/.cursor/
        """, homeDirectory: home)) { error in
            XCTAssertTrue("\(error)".contains("重复"), "实际：\(error)")
        }
    }

    func test清单文本出现非主目录锚定的相对路径时拒绝() {
        // 只接受 `~/…` 与绝对路径：清单是安全边界，宁可解析失败也不要默默放宽。
        XCTAssertThrowsError(try ForbiddenRealToolDirectoryList.parse(".claude", homeDirectory: home)) { error in
            XCTAssertTrue("\(error)".contains(".claude"), "报错要指出是哪一条，实际：\(error)")
        }
    }

    func test清单文本为空时拒绝() {
        XCTAssertThrowsError(try ForbiddenRealToolDirectoryList.parse("\n# 只有注释\n", homeDirectory: home))
    }

    func test仓库里的禁区清单覆盖文档列出的全部目录() throws {
        let list = try ForbiddenRealToolDirectoryList.load()
        let declared = Set(list.roots.map(\.homeRelativePath))

        // issue #14 / spec #7「构造数据的纪律」点名的目录：清单可以扩充，但不许删。
        let required: Set<String> = [
            "~/.claude",
            "~/.claudebak",
            "~/.codex",
            "~/.cursor",
            "~/.gemini",
            "~/.local/share/opencode",
            "~/Library/Application Support/deepseek-harness-desktop",
            "~/Library/Application Support/Cursor",
        ]

        XCTAssertTrue(required.isSubset(of: declared), "缺失：\(required.subtracting(declared).sorted())")
    }

    func test仓库里的禁区清单每一条都锚定到主目录或绝对路径() throws {
        let list = try ForbiddenRealToolDirectoryList.load()

        for root in list.roots {
            XCTAssertTrue(
                root.homeRelativePath.hasPrefix("~/") || root.homeRelativePath.hasPrefix("/"),
                "禁区条目必须锚定主目录或绝对路径：\(root.homeRelativePath)"
            )
        }
    }
}
