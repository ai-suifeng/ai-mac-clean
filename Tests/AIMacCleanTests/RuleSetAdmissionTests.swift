import XCTest

import AIMacCleanCore
@testable import AIMacCleanRules

/// Seam R5：规则集准入（issue #11；spec #7「规则集准入（Seam 2）」）。
///
/// 这是本票的核心断言落点：**直接打 `RuleSetAdmission` 的公开接口**，不经过加载器、
/// 更不经过发现流程——否则测试无法区分「保护单调性生效」与「那条规则压根没走到」。
/// 所有测试数据只写在临时目录里，真实 AI 工具数据目录绝不参与（PRD §13 第 3 条）。
final class RuleSetAdmissionTests: XCTestCase {

    private var fixture: TemporaryDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try TemporaryDirectoryFixture(named: "rule-admission")
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    private func decode(_ json: String) throws -> ToolRule {
        try ToolRule.decode(from: Data(json.utf8))
    }

    /// 临时主目录；规则里的 `~/` 都相对它展开。
    private func makeHome(_ name: String = "home") throws -> String {
        try fixture.makeDirectory(name).resolvingSymlinksInPath().path
    }

    // MARK: 合规规则集

    func test不削弱内置保护的规则集被准入() throws {
        let home = try makeHome()
        let claude = try decode(RuleFixtures.claudeCodeJSON)

        let report = RuleSetAdmission.admit(rules: [claude], homeDirectory: home)

        XCTAssertEqual(report.rejections.map(\.ruleIdentifier), [])
        XCTAssertEqual(report.usableRules.map(\.id), ["claude-code"])
    }
}
