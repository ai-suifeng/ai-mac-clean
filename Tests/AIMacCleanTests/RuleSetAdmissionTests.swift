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

    func test内置四个工具的实测形状规则都被准入() throws {
        let home = try makeHome()
        let rules = try ["Claude Code", "Codex CLI", "Cursor", "DeepSeek Harness"]
            .map { name -> ToolRule in
                switch name {
                case "Claude Code": return try decode(RuleFixtures.claudeCodeJSON)
                case "Codex CLI": return try decode(RuleFixtures.codexJSON)
                case "Cursor": return try decode(RuleFixtures.cursorJSON)
                default: return try decode(RuleFixtures.harnessJSON)
                }
            }

        let report = RuleSetAdmission.admit(rules: rules, homeDirectory: home)

        XCTAssertEqual(report.rejections.map(\.description), [])
        XCTAssertEqual(report.usableRules.map(\.id), ["claude-code", "codex-cli", "cursor", "deepseek-harness"])
    }

    // MARK: 拒绝粒度是单条规则

    func test一批规则里混入一条坏规则时其余规则照常可用() throws {
        let home = try makeHome()
        let claude = try decode(RuleFixtures.claudeCodeJSON)
        let bad = try decode(RuleAdmissionFixtures.codexAuthArchivableJSON)
        let cursor = try decode(RuleFixtures.cursorJSON)

        let report = RuleSetAdmission.admit(rules: [claude, bad, cursor], homeDirectory: home)

        // 一条坏规则不能让其余已知工具的规则全部失效……
        XCTAssertEqual(report.usableRules.map(\.id), ["claude-code", "cursor"])
        XCTAssertNotNil(report.usableRule(id: "claude-code"))
        // ……也不能被静默忽略：它带着自己的原因单独立在拒绝清单里。
        XCTAssertEqual(report.rejections.count, 1)
        XCTAssertEqual(report.rejections.first?.ruleIdentifier, "codex-cli")
        XCTAssertEqual(report.rejections.first?.reason.isProtectionMonotonicityViolation, true)
        // 被拒绝的规则整体不出现在可用规则集里（含它自己声明为受保护的那些条目）。
        XCTAssertNil(report.usableRule(id: "codex-cli"))
    }

    // MARK: 保护单调性（核心断言，直接打 Seam 2）

    func test把受保护路径标成缓存不构成降级但要给出提示() throws {
        let home = try makeHome()
        let claude = try decode(RuleFixtures.claudeCodeJSON)

        let report = RuleSetAdmission.admit(rules: [claude], homeDirectory: home)

        // 缓存与日志同样「只展示、不动」，不授予删除权限，因此不构成降级（PRD §5.1）。
        XCTAssertEqual(report.usableRules.map(\.id), ["claude-code"])
        let warning = report.warnings.first { $0.pattern == "shell-snapshots/**" }
        XCTAssertEqual(warning?.protectedRuleIdentifier, "claude-code/shell-snapshots")
        XCTAssertEqual(warning?.declaredCategory, .cacheAndLog)
    }


    func test把内置受保护路径改判为可归档的规则被拒绝() throws {
        let home = try makeHome()
        let rule = try decode(RuleAdmissionFixtures.codexAuthArchivableJSON)

        let rejection = RuleSetAdmission.rejection(forRule: rule, homeDirectory: home)

        XCTAssertEqual(rejection?.ruleIdentifier, "codex-cli")
        XCTAssertEqual(rejection?.reason.protectedRuleIdentifier, "codex-cli/auth")

        // 原因要能直接展示给用户，并定位到「哪条规则的哪个字段」。
        let message = rejection?.description ?? ""
        XCTAssertTrue(message.contains("classification[2].category"), message)
        XCTAssertTrue(message.contains("auth.json"), message)
        XCTAssertTrue(message.contains("不能把它降低"), message)
    }
}

private enum RuleAdmissionFixtures {
    static let codexAuthArchivableJSON = """
{
  "schemaVersion": 1,
  "id": "codex-cli",
  "displayName": "Codex CLI",
  "roots": [{ "path": "~/.codex", "role": "toolRoot" }],
  "classification": [
    { "pattern": "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl", "category": "archivableSession" },
    { "pattern": "config.toml", "category": "protected" },
    { "pattern": "auth.json", "category": "archivableSession" },
    { "pattern": "prompts/**", "category": "protected" }
  ]
}
"""
}
