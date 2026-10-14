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

    // MARK: 符号链接的真实目标

    func test工具根是指向共享技能目录的符号链接时整棵都受保护() throws {
        // 实测形态（PRD §14.5、issue #5）：`~/.codex/skills` 与 `~/.opencode/skills`
        // 是指向 `~/.agents/skills` 的符号链接，164 个用户 skill 就在里面。
        let fakeHome = try ProtectedPathTestSupport.FakeHome.make(named: "skills-link", fixture: fixture)
        let shared = try ProtectedPathTestSupport.createDirectory(
            named: ".agents/skills",
            in: fakeHome.root
        )
        try ProtectedPathTestSupport.createDirectory(named: "my-skill", in: shared)
        try ProtectedPathTestSupport.createSymbolicLink(
            named: "skills",
            in: fakeHome.codexRoot,
            pointingTo: shared
        )

        let rule = try decode(RuleAdmissionFixtures.skillsSymlinkRootJSON)
        let rejection = RuleSetAdmission.rejection(forRule: rule, homeDirectory: fakeHome.homeDirectory)

        XCTAssertEqual(rejection?.reason.protectedRuleIdentifier, "home/shared-skills")
        XCTAssertTrue(rejection?.description.contains("真实目标") ?? false, rejection?.description ?? "")
    }

    // MARK: 容忍缺失

    func test规则声明的路径在磁盘上不存在时准入通过() throws {
        let home = try makeHome()
        // 工具根指向一个从未被创建过的路径：规则声明的路径在磁盘上缺失不是拒绝理由
        // （spec #7 User Story 22、PRD §5.4）。
        let missingRoot = fixture.url.path + "/never-created-home/.claude"
        let ghost = try decode(RuleAdmissionFixtures.ghostToolRuleJSON.replacingOccurrences(
            of: "<<ROOT>>", with: missingRoot
        ))

        let report = RuleSetAdmission.admit(rules: [ghost], homeDirectory: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot))
        XCTAssertEqual(report.rejections.map(\.description), [])
        XCTAssertEqual(report.usableRules.map(\.id), ["ghost-tool"])
    }

    func test缺失的工具根下内置保护照样生效() throws {
        let home = try makeHome()
        let missingRoot = fixture.url.path + "/never-created-home/.claude"
        let bad = try decode(RuleAdmissionFixtures.codexSettingsArchivableJSON.replacingOccurrences(
            of: "<<ROOT>>", with: missingRoot
        ))

        // 判定完全走路径形状，不依赖磁盘：这个工具根根本不存在，
        // 但 `settings.json` 仍然撞在内置受保护条目上。
        let rejection = RuleSetAdmission.rejection(forRule: bad, homeDirectory: home)

        XCTAssertEqual(rejection?.reason.protectedRuleIdentifier, "claude-code/settings")
    }

    // MARK: 类别封闭：规则不得凭空新增类别，也不得把不确定降级为可归档

    func test规则声明封闭枚举以外的新类别被拒绝() throws {
        let home = try makeHome()
        let raw = RawToolRule(source: "user-extension.json",
                              data: Data(RuleAdmissionFixtures.unknownCategoryJSON.utf8))

        let report = RuleSetAdmission.admit(rawRules: [raw], homeDirectory: home)

        XCTAssertEqual(report.usableRules.map(\.id), [])
        let rejection = report.rejections.first
        XCTAssertEqual(rejection?.source, "user-extension.json")
        guard case let .malformed(format)? = rejection?.reason else {
            return XCTFail("期望读到类别封闭相关的拒绝原因，实际：\(String(describing: rejection?.reason))")
        }
        XCTAssertTrue(rejection?.description.contains("shred") ?? false, rejection?.description ?? "")
    }

    func test把不确定降级为可归档的规则被拒绝() throws {
        let home = try makeHome()
        let rule = try decode(RuleAdmissionFixtures.uncertainDowngradeJSON)

        let rejection = RuleSetAdmission.rejection(forRule: rule, homeDirectory: home)

        XCTAssertEqual(rejection?.reason.uncertainShapeIdentifier, "uncertain/protobuf")
        let message = rejection?.description ?? ""
        XCTAssertTrue(message.contains("classification[0].category"), message)
        XCTAssertTrue(message.contains("*.pb"), message)
    }

    func test把同一路径声明为不确定时准入通过() throws {
        let home = try makeHome()
        let rule = try decode(RuleAdmissionFixtures.uncertainDeclaredJSON)

        let report = RuleSetAdmission.admit(rules: [rule], homeDirectory: home)

        XCTAssertEqual(report.rejections.map(\.description), [])
        XCTAssertEqual(report.usableRule(id: "user-extension")?.id, "user-extension")
    }

    // MARK: 用户规则只能抬高保护

    func test用户规则把路径加入受保护集合时被接受且该路径确实受保护() throws {
        let home = try makeHome()
        let rule = try decode(RuleAdmissionFixtures.userProtectedAdditionJSON)

        let report = RuleSetAdmission.admit(rules: [rule], homeDirectory: home)

        XCTAssertEqual(report.rejections.map(\.description), [])
        XCTAssertEqual(report.usableRules.map(\.id), ["user-extension"])
        XCTAssertEqual(report.category(forRelativePath: "custom-secrets/token.json", ruleID: "user-extension"), .protected)
        XCTAssertEqual(report.category(forRelativePath: "custom-secrets/nested/deep/token", ruleID: "user-extension"), .protected)
        // 抬高保护不影响同一条规则里既有的分类。
        XCTAssertEqual(
            report.category(forRelativePath: "sessions/2025/10/14/rollout-1.jsonl", ruleID: "user-extension"),
            .archivableSession
        )
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

    /// 工具根就是 `~/.codex/skills` 这个符号链接。
    static let skillsSymlinkRootJSON = """
{
  "schemaVersion": 1,
  "id": "skills-editor",
  "displayName": "技能编辑工具",
  "roots": [{ "path": "~/.codex/skills", "role": "toolRoot" }],
  "classification": [
    { "pattern": "my-skill/notes.jsonl", "category": "archivableSession" }
  ]
}
"""

    /// 工具根指向一个不存在的绝对路径。
    static let ghostToolRuleJSON = """
{
  "schemaVersion": 1,
  "id": "ghost-tool",
  "displayName": "尚未安装的工具",
  "roots": [{ "path": "<<ROOT>>", "role": "toolRoot" }],
  "classification": [
    { "pattern": "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl", "category": "archivableSession" },
    { "pattern": "config.toml", "category": "protected" }
  ]
}
"""

    /// 把 `settings.json` 改判为可归档，工具根用占位符替换。
    static let codexSettingsArchivableJSON = """
{
  "schemaVersion": 1,
  "id": "ghost-tool",
  "displayName": "尚未安装的工具",
  "roots": [{ "path": "<<ROOT>>", "role": "toolRoot" }],
  "classification": [
    { "pattern": "settings.json", "category": "archivableSession" }
  ]
}
"""

    /// 凭空发明一个类别。
    static let unknownCategoryJSON = """
{
  "schemaVersion": 1,
  "id": "user-extension",
  "displayName": "用户扩展工具",
  "roots": [{ "path": "~/.cursor", "role": "toolRoot" }],
  "classification": [
    { "pattern": "assets/**", "category": "shred" }
  ]
}
"""

    /// 把 PRD §5.1 点名的「不确定」数据（`.pb`）降级为可归档。
    static let uncertainDowngradeJSON = """
{
  "schemaVersion": 1,
  "id": "user-extension",
  "displayName": "用户扩展工具",
  "roots": [{ "path": "~/.cursor", "role": "toolRoot" }],
  "classification": [
    { "pattern": "*.pb", "category": "archivableSession" }
  ]
}
"""

    /// 同一条路径声明为「不确定」：这才是 PRD §5.1 给它的正确处理。
    static let uncertainDeclaredJSON = """
{
  "schemaVersion": 1,
  "id": "user-extension",
  "displayName": "用户扩展工具",
  "roots": [{ "path": "~/.cursor", "role": "toolRoot" }],
  "classification": [
    { "pattern": "*.pb", "category": "uncertain" }
  ]
}
"""

    /// 用户规则把一条自定义路径**加入**受保护集合（抬高保护永远允许）。
    static let userProtectedAdditionJSON = """
{
  "schemaVersion": 1,
  "id": "user-extension",
  "displayName": "用户扩展工具",
  "roots": [{ "path": "~/.codex", "role": "toolRoot" }],
  "classification": [
    { "pattern": "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl", "category": "archivableSession" },
    { "pattern": "custom-secrets/**", "category": "protected" }
  ]
}
"""
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
