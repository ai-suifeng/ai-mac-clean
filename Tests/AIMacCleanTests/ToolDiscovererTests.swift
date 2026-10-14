import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// Seam 1 — 发现管线（issue #12 / spec #7 §发现管线）。
///
/// 断言只落在**外部可观察行为**上：哪些目录进了候选、置信度多少、哪些目录被跳过并说明。
/// 不断言打分权重、不断言遍历顺序、不断言内部数据结构形状。
final class ToolDiscovererTests: XCTestCase {

    // MARK: - 切片 1：空结果不是错误（User Story 13）

    func test空目录树返回空候选列表且不报错() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        let discoverer = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            homeDirectory: fixture.homePath
        )

        let result = discoverer.discover(scanRoots: ScanRoot.standard(forHomeDirectory: fixture.homePath))

        XCTAssertTrue(result.candidates.isEmpty, "没装任何 AI 工具时应给出空列表，而不是报错或塞进噪声目录")
        XCTAssertTrue(result.unreadableDirectories.isEmpty)
    }
    // MARK: - 切片 2：结构指纹才准入（User Story 8、9）

    func test命中结构指纹的工具根进候选而名字像没结构的目录不进候选() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 实测形状：`projects/<单横线编码路径>/<uuid>.jsonl`，另有旧版子代理转录 `agent-*.jsonl`。
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/agent-1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl")
        // 名字里含 claude，但没有任何结构（PRD A1 的反面教材）。
        try fixture.makeFile("claude-something/readme.md", contents: "# 不是工具数据")

        let discoverer = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            homeDirectory: fixture.homePath
        )

        let result = discoverer.discover()

        XCTAssertEqual(result.candidates.map(\.toolRootPath), [fixture.homePath + "/.claude"])
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.ruleIdentifier, "claude-code")
        XCTAssertTrue(
            candidate.signals.structuralFingerprints.contains("projects/<encodedPath>/<uuid>.jsonl"),
            "准入依据必须是结构指纹，实际命中：\(candidate.signals.structuralFingerprints)"
        )
    }
    // MARK: - 切片 4：Codex 实测形状（User Story 24、25、26）

    func testCodex的明文与zst并存且扁平归档目录与fork双UUID都被识别() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 实测：792 个文件里 771 个已是 .zst，仅 21 个是明文 .jsonl——两种并存。
        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: #"{"type":"session_meta","payload":{"cwd":"/Users/xiaowei/work"}}"# + "\n"
        )
        try fixture.makeFile(
            ".codex/sessions/2026/10/13/rollout-2026-10-13T09-08-28-"
                + "1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl.zst",
            contents: ""
        )
        // 实测：archived_sessions 扁平存放，没有年月日嵌套。
        try fixture.makeFile(
            ".codex/archived_sessions/rollout-2026-10-01T09-08-28-"
                + "2d3e4f5a-6b7c-8d9e-0f1a-2b3c4d5e6f7a.jsonl.zst",
            contents: ""
        )
        // 实测：fork 出来的会话文件名里含两个 UUID。
        try fixture.makeFile(
            ".codex/archived_sessions/rollout-2026-10-02T09-08-28-"
                + "3e4f5a6b-7c8d-9e0f-1a2b-3c4d5e6f7a8b_4f5a6b7c-8d9e-0f1a-2b3c-4d5e6f7a8b9c.jsonl.zst",
            contents: ""
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.codexJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.ruleIdentifier, "codex-cli")
        XCTAssertEqual(
            Set(candidate.signals.structuralFingerprints),
            [
                "sessions/<date:year>",
                "archived_sessions",
                "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl",
                "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]",
                "archived_sessions/rollout-<ISO>.jsonl.zst",
            ],
            "明文、.zst、扁平 archived_sessions 与 fork 双 UUID 文件名都要被识别"
        )
        XCTAssertEqual(
            candidate.signals.externalCorroborations,
            [.contentFeature("会话文件开头含字段 type、payload")],
            "只有明文会话文件会被读文件头；.zst 本阶段不解压（spec #7 §Out of Scope）"
        )
    }

    // MARK: - 切片 5：Cursor / Harness / 非标准位置（User Story 7）

    func testCursor的主转录与同级子代理转录都被识别() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        try fixture.makeFile(
            ".cursor/projects/-Users-xiaowei-amc-wt-12/agent-transcripts/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f/1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl"
        )
        try fixture.makeFile(
            ".cursor/projects/-Users-xiaowei-amc-wt-12/agent-transcripts/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f/subagents/2d3e4f5a-6b7c-8d9e-0f1a-2b3c4d5e6f7a.jsonl"
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.cursorJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.displayPath, "~/.cursor")
        XCTAssertTrue(
            candidate.signals.structuralFingerprints.contains("projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl"),
            "实测形状在第 5 层：\(candidate.signals.structuralFingerprints)"
        )
    }

    func testHarness的双横线编码路径与zstd会话被识别() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 实测：`sessions/<双横线编码路径>/session-<uuid>/session.jsonl.zstd`，一个会话一个文件。
        try fixture.makeFile(
            "Library/Application Support/deepseek-harness-desktop/harness-home"
                + "/sessions/--Users-xiaowei-work-amc-wt-12--/session-9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f"
                + "/session.jsonl.zstd",
            contents: ""
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.harnessJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(
            candidate.displayPath,
            "~/Library/Application Support/deepseek-harness-desktop/harness-home"
        )
        XCTAssertTrue(
            candidate.signals.structuralFingerprints.contains("sessions/<encodedPath>/session-<uuid>/session.jsonl.zstd"),
            "zstd 会话只按扩展名识别，不解压：\(candidate.signals.structuralFingerprints)"
        )
    }

    func test非标准位置的opencode数据也能被发现() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        try fixture.makeFile(
            ".local/share/opencode/storage/-Users-xiaowei-amc-wt-12/session/message/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.json"
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([DiscoveryFixture.openCodeJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.displayPath, "~/.local/share/opencode")
        XCTAssertEqual(candidate.ruleIdentifier, "opencode")
    }

    // MARK: - 切片 3：置信度三档（spec #7 §置信度模型）

    func test只有结构指纹没有佐证判为中置信度() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // Cursor 形态（实测）：`projects/<编码路径>/agent-transcripts/<uuid>/<uuid>.jsonl`。
        // 这条规则没声明 fileHeaderKeys，因此除了结构指纹没有别的证据可用。
        try fixture.makeFile(
            ".cursor/projects/-Users-xiaowei-amc-wt-12/agent-transcripts/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f/1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl"
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.cursorJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(result.candidates.map(\.confidence), [.medium])
        XCTAssertFalse(try XCTUnwrap(result.candidates.first).isSuspicious)
    }

    func test结构指纹加同名应用佐证判为高置信度() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            hints: DiscoveryHints(nameKeywords: ["claude-code": ["claude"]]),
            externalEvidence: ExternalEvidence(applicationNames: ["Claude"]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.confidence, .high)
        XCTAssertEqual(candidate.signals.nameMatches, ["claude"])
        XCTAssertTrue(
            candidate.signals.externalCorroborations.contains(.application("Claude")),
            "同名应用必须记为外部佐证，实际：\(candidate.signals.externalCorroborations)"
        )
    }

    func test路径命令也作为外部佐证() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            hints: DiscoveryHints(nameKeywords: ["claude-code": ["claude"]]),
            externalEvidence: ExternalEvidence(commandNames: ["claude", "rg"]),
            homeDirectory: fixture.homePath
        ).discover()

        let corroborations = try XCTUnwrap(result.candidates.first).signals.externalCorroborations
        XCTAssertTrue(
            corroborations.contains(.command("claude")),
            "PATH 中的同名命令必须记为外部佐证，实际：\(corroborations)"
        )
        XCTAssertFalse(corroborations.contains(.command("rg")), "无关命令不构成佐证")
    }

    func test会话文件开头的字段特征作为佐证但不超出文件头上限() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 字段特征出现在文件头上限（4096 字节）之后：为了判断而读完整个文件是被明确禁止的，
        // 因此这个特征**不算**证据，候选停留在「中」。
        let filler = String(repeating: "x", count: 8_000)
        try fixture.makeFile(
            ".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: filler + "\n" + DiscoveryFixture.sampleTranscriptLine
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.confidence, .medium)
        XCTAssertTrue(candidate.signals.externalCorroborations.isEmpty)
    }

    func test只有位置像没有结构证据的候选标为低置信度疑似() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 工具装了但会话记录被清空：位置确实是声明过的工具根，却没有任何结构证据。
        try fixture.makeFile(".claude/settings.json", contents: "{}")

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertTrue(candidate.isSuspicious, "纯名称/位置命中的候选必须标为「疑似」并默认折叠（User Story 4）")
        XCTAssertEqual(candidate.demotions, [.missingStructuralFingerprint])
    }

    func test高置信度排在低置信度前面且关键词只影响顺序() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // `.codex` 有结构；`.claude` 只剩配置。
        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl.zst",
            contents: ""
        )
        try fixture.makeFile(".claude/settings.json", contents: "{}")

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON, RuleFixtures.codexJSON]),
            hints: DiscoveryHints(
                nameKeywords: ["claude-code": ["claude"], "codex-cli": ["codex"]],
                negativeNamePatterns: []
            ),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(
            result.candidates.map { "\($0.ruleIdentifier ?? "")/\($0.confidence.rawValue)" },
            ["codex-cli/medium", "claude-code/low"]
        )
    }
}

// MARK: - 辅助

/// 规则夹具先过一遍规则集准入（issue #11）：发现器只消费**已验证可用**的规则集。
private func admittedRules(_ ruleJSON: [String]) throws -> [ToolRule] {
    let rules = try ruleJSON.map { try RuleLoader.loadRule(from: Data($0.utf8), source: "夹具") }
    let report = RuleSetAdmission.admit(rules: rules, homeDirectory: NSTemporaryDirectory())
    XCTAssertTrue(report.rejections.isEmpty, "夹具规则不该被准入拒绝：\(report.rejections)")
    return report.usableRules
}
