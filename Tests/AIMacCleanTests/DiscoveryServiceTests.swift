import Foundation
import XCTest

import AIMacCleanDomain

/// issue #16 的生产接线：规则目录 → 规则集准入 → 外部佐证采集 → 浅扫。
///
/// 全部输入（主目录、规则目录、词表、应用目录、PATH）都指向临时目录：
/// 这一层测试只证明**接线顺序**正确，绝不碰真实数据目录（PRD §13 第 3 条）。
final class DiscoveryServiceTests: XCTestCase {

    private var home: DiscoveryFixture!

    override func setUpWithError() throws {
        home = try DiscoveryFixture()
    }

    override func tearDown() {
        home?.home.remove()
    }

    // MARK: - 规则资源缺失要吵起来，而不是假装机器上没装工具

    func test规则目录不存在时给出可读问题而不是静默的空列表() {
        let service = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: home.home.url.appendingPathComponent("根本没有这个目录", isDirectory: true)
            )
        )

        let run = service.run()

        XCTAssertEqual(run.issues, [.noRulesLoaded])
        XCTAssertEqual(run.result.candidates, [])
    }

    // MARK: - 规则 → 准入 → 浅扫

    func test从规则目录加载规则并在实测形状上发现候选() throws {
        let ruleDirectory = try writeRules([RuleFixtures.claudeCodeJSON])
        try home.makeFile(".claude/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory
            )
        ).run()

        XCTAssertEqual(run.issues, [])
        XCTAssertEqual(run.result.candidates.map(\.toolRootPath), [home.homePath + "/.claude"])
    }

    func test规则全部未通过准入时说明原因且候选为空() throws {
        // 把一条会被保护单调性拒绝的规则（把 auth.json 判成可归档）放进目录：
        // 候选必然为空，但界面必须知道这是配置问题，而不是「你机器上没装工具」。
        let ruleDirectory = try writeRules([downgradedClaudeCodeJSON])
        try home.makeFile(".claude/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory
            )
        ).run()

        XCTAssertEqual(run.issues, [.noUsableRules(rejectedCount: 1)])
        XCTAssertEqual(run.result.candidates, [])
    }

    // MARK: - 外部佐证必须真的被采集（User Story 10）

    func test同名应用与PATH命令被采集为外部佐证因此判为高置信度() throws {
        let ruleDirectory = try writeRules([RuleFixtures.claudeCodeJSON])
        // 文件头不带规则声明的字段特征：这一档只可能由**采集到的** App / 命令撑起来。
        try home.makeFile(
            ".claude/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: "{\"note\":\"没有规则声明的字段特征\"}\n"
        )
        try home.writeFile("Applications/Claude.app/Contents/Info.plist", contents: "<plist/>")
        let binDirectory = try home.home.makeDirectory("bin")
        try writeExecutable(named: "claude", in: binDirectory)

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory,
                applicationDirectories: [home.homePath + "/Applications"],
                commandSearchPaths: [binDirectory.path]
            )
        ).run()

        let candidate = try XCTUnwrap(run.result.candidates.first)
        XCTAssertEqual(
            candidate.confidence,
            .high,
            "同名 App 与 PATH 命令都必须真的被采集，否则「高置信度」永远不会出现"
        )
        XCTAssertEqual(
            candidate.signals.externalCorroborations,
            [.application("Claude"), .command("claude")]
        )
    }

    func test没有佐证来源时只按结构指纹判为中置信度() throws {
        let ruleDirectory = try writeRules([RuleFixtures.claudeCodeJSON])
        try home.makeFile(
            ".claude/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: "{\"note\":\"没有规则声明的字段特征\"}\n"
        )

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory,
                applicationDirectories: [],
                commandSearchPaths: []
            )
        ).run()

        XCTAssertEqual(run.result.candidates.first?.confidence, .medium)
    }

    // MARK: - 词表

    func test没有用户词表时用内置默认词表做降权() throws {
        // 生产环境绝大多数用户不会自己写词表文件；旧快照因此必须在**默认**情况下就被降权，
        // 否则负向名单等于形同虚设（PRD A1）。
        let snapshotRule = RuleFixtures.claudeCodeJSON
            .replacingOccurrences(of: "\"~/.claude\"", with: "\"~/.claudebak\"")
        let ruleDirectory = try writeRules([snapshotRule])
        try home.makeFile(".claudebak/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory,
                hintsFileURL: nil
            )
        ).run()

        let candidate = try XCTUnwrap(run.result.candidates.first)
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertTrue(candidate.isSuspicious)
    }

    func test用户词表覆盖内置默认词表() throws {
        // 用户写了词表就以用户的为准（词表是可更新配置，`docs/discovery-hints.md`）。
        let ruleDirectory = try writeRules([RuleFixtures.claudeCodeJSON])
        // 文件头不带规则声明的字段特征：置信度只可能被词表影响。
        try home.makeFile(
            ".claude/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: "{\"note\":\"没有规则声明的字段特征\"}\n"
        )
        let hintsPath = try home.writeHintsFile(
            #"{ "schemaVersion": 1, "negativeNamePatterns": ["*never-matches*"] }"#
        )

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory,
                hintsFileURL: URL(fileURLWithPath: hintsPath)
            )
        ).run()

        XCTAssertEqual(run.issues, [])
        XCTAssertEqual(run.result.candidates.first?.confidence, .medium)
    }

    func test词表文件不存在不算错误() throws {
        let ruleDirectory = try writeRules([RuleFixtures.claudeCodeJSON])
        try home.makeFile(
            ".claude/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: "{\"note\":\"没有规则声明的字段特征\"}\n"
        )
        let missing = home.home.url.appendingPathComponent("不存在.json", isDirectory: false)

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory,
                hintsFileURL: missing
            )
        ).run()

        XCTAssertEqual(run.issues, [], "词表是可选配置，文件不在不算错误")
        XCTAssertEqual(run.result.candidates.count, 1)
    }

    func test词表格式不对时说明原因但发现继续() throws {
        let ruleDirectory = try writeRules([RuleFixtures.claudeCodeJSON])
        try home.makeFile(".claude/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        let hintsPath = try home.writeHintsFile("{ 这不是 JSON")

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory,
                hintsFileURL: URL(fileURLWithPath: hintsPath)
            )
        ).run()

        XCTAssertEqual(run.issues.count, 1)
        guard case .hintsUnavailable = run.issues[0] else {
            return XCTFail("词表读不出来必须单独报出来，实际：\(run.issues)")
        }
        XCTAssertEqual(run.result.candidates.count, 1, "词表坏了不该让整个发现停摆")
    }

    func test词表里的负向名单真的参与降权() throws {
        // 实测：`~/.claudebak` 是 `~/.claude` 的旧快照，内部确实是会话形状。
        let snapshotRule = RuleFixtures.claudeCodeJSON
            .replacingOccurrences(of: "\"~/.claude\"", with: "\"~/.claudebak\"")
        let ruleDirectory = try writeRules([snapshotRule])
        try home.makeFile(".claudebak/projects/-Users-xiaowei-amc-wt-16/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        let hintsPath = try home.writeHintsFile(
            """
            { "schemaVersion": 1, "nameKeywords": { "claude-code": ["claude"] },
              "negativeNamePatterns": ["*bak*"] }
            """
        )

        let run = DiscoveryService(
            configuration: .init(
                homeDirectory: home.homePath,
                ruleDirectory: ruleDirectory,
                hintsFileURL: URL(fileURLWithPath: hintsPath)
            )
        ).run()

        let candidate = try XCTUnwrap(run.result.candidates.first)
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertTrue(candidate.isSuspicious)
    }

    // MARK: - 标准入口的接线（不跑真实扫描，只看配置）

    func test标准入口指向系统应用目录与PATH() {
        let service = DiscoveryService.standard(
            homeDirectory: "/Users/example",
            ruleDirectory: nil,
            hintsFileURL: nil,
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"]
        )

        XCTAssertEqual(
            service.configuration.applicationDirectories,
            ["/Applications", "/Users/example/Applications"]
        )
        XCTAssertEqual(service.configuration.commandSearchPaths, ["/usr/local/bin", "/opt/homebrew/bin"])
    }

    // MARK: - 辅助

    /// 一条试图把内置受保护条目（`settings*.json`）降级为可归档的规则。
    private var downgradedClaudeCodeJSON: String {
        RuleFixtures.claudeCodeJSON.replacingOccurrences(
            of: #"{ "pattern": "settings*.json", "category": "protected" }"#,
            with: #"{ "pattern": "settings*.json", "category": "archivableSession" }"#
        )
    }

    private func writeRules(_ ruleJSON: [String]) throws -> URL {
        let directory = try home.home.makeDirectory("rules-\(UUID().uuidString)")
        for (index, json) in ruleJSON.enumerated() {
            let file = directory.appendingPathComponent("rule-\(index).json", isDirectory: false)
            try Data(json.utf8).write(to: file, options: .atomic)
        }
        return directory
    }

    private func writeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
