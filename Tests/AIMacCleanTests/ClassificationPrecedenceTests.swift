import XCTest

import AIMacCleanCore
@testable import AIMacCleanRules

/// issue #25：分类判定顺序（验收 6）。
///
/// 一条路径同时匹配多条分类条目时，结果必须**确定**，不能取决于规则文件里
/// 谁写在前面。判定顺序是 `受保护 > 不确定 > 缓存与日志 > 可归档会话`，
/// 取向只有一个：越不容易丢数据越靠前（PRD §5.1、§2.3）。
///
/// 断言打在 `RuleSetAdmission` 的公开查询上——深扫（#23）就是从这里取类别的。
/// 全部数据写在测试内的夹具规则里，真实 AI 工具数据目录绝不参与（PRD §13 第 3 条）。
final class ClassificationPrecedenceTests: XCTestCase {

    private var fixture: TemporaryDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try TemporaryDirectoryFixture(named: "classification-precedence")
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    private func makeHome() throws -> String {
        try fixture.makeDirectory("home").resolvingSymlinksInPath().path
    }

    private func admit(_ json: String) throws -> RuleAdmissionReport {
        let rule = try RuleLoader.loadRule(from: Data(json.utf8), source: "夹具")
        return RuleSetAdmission.admit(rules: [rule], homeDirectory: try makeHome())
    }

    // MARK: - 判定顺序

    func test判定顺序从受保护到可归档会话() {
        XCTAssertEqual(
            ClassificationResolution.precedence,
            [.protected, .uncertain, .cacheAndLog, .archivableSession],
            "判定顺序是受保护 > 不确定 > 缓存与日志 > 可归档会话（PRD §5.1）。"
        )
    }

    func test一组命中类别里取判定顺序最高的那一类() {
        // 受保护最高：它同时是代码层强制的不变量，任何更低档的类别都不能盖过它。
        XCTAssertEqual(ClassificationResolution.preferred([.archivableSession, .protected]), .protected)
        XCTAssertEqual(ClassificationResolution.preferred([.cacheAndLog, .uncertain]), .uncertain)
        XCTAssertEqual(ClassificationResolution.preferred([.archivableSession, .cacheAndLog]), .cacheAndLog)
        XCTAssertEqual(ClassificationResolution.preferred([.archivableSession, .uncertain]), .uncertain)
        XCTAssertEqual(ClassificationResolution.preferred([.protected]), .protected)
        XCTAssertNil(ClassificationResolution.preferred([]), "没有命中任何类别时没有可取的判定结果。")
    }

    // MARK: - 通过准入结果的类别查询（深扫的取数口）

    func test同一路径命中多条时按判定顺序而不是声明顺序() throws {
        // 可归档会话声明在**前**、受保护声明在**后**：按声明顺序会取到可归档，
        // 按判定顺序必须取到受保护。
        let report = try admit(Self.declarationOrderFixture)

        XCTAssertEqual(report.rejections.map(\.description), [])
        XCTAssertEqual(
            report.category(forRelativePath: "data/state.sqlite", ruleID: "user-extension"),
            .protected,
            "受保护是最高档：同一路径命中多条时不能被写在后面的受保护条目反被声明的先后决定。"
        )
        // 只命中可归档条目的路径照常是可归档。
        XCTAssertEqual(
            report.category(forRelativePath: "data/2025/rollout.jsonl", ruleID: "user-extension"),
            .archivableSession
        )
    }

    func test缓存与不确定之间的判定顺序同样与声明顺序无关() throws {
        let report = try admit(Self.cacheVersusUncertainFixture)

        XCTAssertEqual(report.rejections.map(\.description), [])
        XCTAssertEqual(
            report.category(forRelativePath: "store/state.sqlite", ruleID: "user-extension"),
            .uncertain,
            "「认不出来，仅展示占用」比「这是缓存」更保守，因此不确定优先。"
        )
        XCTAssertEqual(
            report.category(forRelativePath: "store/blob/abc", ruleID: "user-extension"),
            .cacheAndLog
        )
    }

    // MARK: - 夹具

    /// 可归档声明在前、受保护声明在后。
    private static let declarationOrderFixture = """
    {
      "schemaVersion": 1,
      "id": "user-extension",
      "displayName": "用户扩展工具",
      "roots": [{ "path": "~/.amc-precedence", "role": "toolRoot" }],
      "classification": [
        { "pattern": "data/**", "category": "archivableSession" },
        { "pattern": "data/*.sqlite", "category": "protected" }
      ]
    }
    """

    /// 缓存声明在前、不确定声明在后。
    private static let cacheVersusUncertainFixture = """
    {
      "schemaVersion": 1,
      "id": "user-extension",
      "displayName": "用户扩展工具",
      "roots": [{ "path": "~/.amc-precedence", "role": "toolRoot" }],
      "classification": [
        { "pattern": "store/**", "category": "cacheAndLog" },
        { "pattern": "store/*.sqlite", "category": "uncertain" }
      ]
    }
    """
}
