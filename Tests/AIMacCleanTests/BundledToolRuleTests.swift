import XCTest

import AIMacCleanCore
@testable import AIMacCleanRules

/// issue #15：内置规则文件（spec #7 User Stories 20–26）。
///
/// 断言落点只有两个 seam，都不经发现流程：
///
/// - **规则资源**：规则文件是 bundle 资源，用真实加载器 `RuleLoader.loadRules(inDirectory:)`
///   一次读全；新增工具 = 新增一个规则文件，不改代码（User Story 20）。
/// - **规则集准入**：读进来的全部规则过 `RuleSetAdmission.admit`，零拒绝（User Story 29），
///   再用准入结果的类别查询断言实测形状（PRD §5.4 / §14.5）。
///
/// 所有目录树都建在临时目录里，真实 AI 工具数据目录绝不参与（PRD §13 第 3 条、issue #14 护栏）。
final class BundledToolRuleTests: XCTestCase {

    private var fixture: TemporaryDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try TemporaryDirectoryFixture(named: "bundled-rules")
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    // MARK: - 规则资源

    /// 内置规则文件的目录（bundle 资源，由 SwiftPM 的 `resources` 打进包）。
    private func bundledRuleDirectory() throws -> URL {
        let directory = try XCTUnwrap(
            BuiltInRuleResources.directory,
            "内置规则应当以 bundle 资源的形式存在，而不是写死在代码里（User Story 20）。"
        )
        return directory
    }

    /// 用真实加载器读全部内置规则。
    private func loadBundledRules() throws -> (rules: [ToolRule], report: RuleAdmissionReport) {
        let directory = try bundledRuleDirectory()
        let load = RuleLoader.loadRules(inDirectory: directory)
        XCTAssertEqual(load.diagnostics.map(\.errorDescription), [],
                       "内置规则文件必须全部读得进来。")
        let home = try makeHome()
        let report = RuleSetAdmission.admit(rules: load.rules, homeDirectory: home)
        return (load.rules, report)
    }

    /// 临时主目录；规则里的 `~/` 都相对它展开。
    private func makeHome(_ name: String = "home") throws -> String {
        try fixture.makeDirectory(name).resolvingSymlinksInPath().path
    }

    // MARK: Slice 1：规则文件是 bundle 资源，一次读全

    func test内置规则目录是bundle资源目录() throws {
        let directory = try bundledRuleDirectory()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      "规则文件应当随包分发：\(directory.path)")
        XCTAssertTrue(isDirectory.boolValue)

        // 规则文件落在本模块的资源 bundle 里，而不是源码目录或二进制里的字符串。
        XCTAssertTrue(directory.path.contains(".bundle"),
                      "规则文件应当随 bundle 资源分发：\(directory.path)")
    }

    func test内置规则覆盖五个工具且全部读得进来() throws {
        let (rules, _) = try loadBundledRules()

        XCTAssertEqual(rules.map(\.id),
                       ["claude-code", "codex-cli", "cursor", "deepseek-harness", "opencode"])
        XCTAssertEqual(rules.map(\.displayName),
                       ["Claude Code", "Codex CLI", "Cursor", "DeepSeek Harness", "OpenCode"])
        XCTAssertEqual(rules.map(\.schemaVersion), [Int](repeating: ToolRule.currentSchemaVersion, count: 5))
    }
}
