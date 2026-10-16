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

    /// 五份内置规则，经真实加载器读入并准入。
    private func loadBundledRules() throws -> (rules: [ToolRule], report: RuleAdmissionReport) {
        let directory = try XCTUnwrap(BuiltInRuleResources.directory, "内置规则应当是 bundle 资源。")
        let load = RuleLoader.loadRules(inDirectory: directory)
        XCTAssertEqual(load.diagnostics.map(\.errorDescription), [], "内置规则必须全部读得进来。")
        let report = RuleSetAdmission.admit(rules: load.rules, homeDirectory: try makeHome())
        XCTAssertEqual(report.rejections.map(\.description), [], "内置规则必须零拒绝。")
        return (load.rules, report)
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

    // MARK: - 未命中任何条目时的默认归属

    func test未命中任何分类条目时按不确定归属() {
        XCTAssertEqual(
            ClassificationResolution.resolve(matches: []),
            .uncertain,
            "规则没有声明过的数据就是「无法安全分类」的数据（PRD §5.1）：默认落在不确定档，绝不默认成可归档。"
        )
        XCTAssertEqual(ClassificationResolution.resolve(matches: [.archivableSession]), .archivableSession)
        XCTAssertEqual(ClassificationResolution.resolve(matches: [.cacheAndLog, .archivableSession]), .cacheAndLog)
    }

    func test只展示不碰的实测大头不会因为没有声明就被当成可归档() throws {
        let (_, report) = try loadBundledRules()

        // Cursor AppSupport 实测 14G，全是 Electron / VSCode 内部存储（PRD §5.4、§2.3）：
        // 它是 displayOnly 根，没有任何可归档形态，未声明的内容一律只展示。
        XCTAssertEqual(
            report.category(forRelativePath: "User/workspaceStorage/abc/IndexedDB/file__0.indexeddb.leveldb/LOG",
                            ruleID: "cursor"),
            .uncertain
        )
        XCTAssertFalse(report.matchingCategories(forRelativePath: "User/workspaceStorage/abc/blob",
                                                 ruleID: "cursor")
            .contains(.archivableSession),
                       "AppSupport 下不该有任何「可归档」声明。")

        // Harness 的另一处纯 Electron profile（`@deepseek-ai/dsh-desktop`）同理。
        XCTAssertEqual(
            report.category(forRelativePath: "Local Storage/leveldb/000003.log", ruleID: "deepseek-harness"),
            .uncertain
        )

        // 工具根里没被规则点名过的数据同样按不确定处理，而不是被默默当成可归档。
        XCTAssertEqual(report.category(forRelativePath: "some-undeclared-dir/payload.bin",
                                       ruleID: "codex-cli"),
                       .uncertain)
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
