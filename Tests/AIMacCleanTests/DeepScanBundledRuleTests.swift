import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #23：拿**出厂规则**在夹具树上跑一遍深扫。
///
/// 前面几组用例都用合成规则，把判定语义钉得很细；这一组回答的是另一个问题：
/// 「出厂规则 + 真实形状的目录树，深扫给出的四类对不对」。它同时是 `.zst` / `.zstd`
/// 只认扩展名、`archived_sessions/` 扁平存放、`agent-transcripts/` 一并归可归档这些
/// 实测结论（PRD §5.4 / §14）的回归点。
///
/// 树形照抄 PRD §14，另加 `*-bak` 干扰目录与指向外部的符号链接。
final class DeepScanBundledRuleTests: XCTestCase {

    private let harnessRootSuffix = "Library/Application Support/deepseek-harness-desktop/harness-home"

    func test出厂规则在实测形状的树上给出正确的四类() throws {
        let fixture = try DeepScanFixture(named: "bundled-rules")
        defer { fixture.remove() }

        let rules = try admittedBundledRules()
        let byID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // MARK: Claude Code（`~/.claude`）
        try fixture.write("claude/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 400)
        try fixture.write("claude/projects/-Users-x-a/agent-22222222-2222-2222-2222-222222222222.jsonl", bytes: 100)
        try fixture.write("claude/skills/我的技能/SKILL.md", bytes: 1000)
        try fixture.write("claude/settings.json", bytes: 64)
        // 规则未声明的形态完全像会话的路径：必须落进不确定（验收 2 的关键断言在真实规则上也成立）。
        try fixture.write("claude/sessions/2026/10/14/rollout-2026-10-14T10-00-00.jsonl", bytes: 8192)
        // `*-bak` 干扰目录：不因为名字像 `~/.claude` 就被当成工具。
        try fixture.write("claude-bak/projects/-Users-x-a/99999999-9999-9999-9999-999999999999.jsonl", bytes: 4096)

        // MARK: Codex CLI（`~/.codex`）
        try fixture.write("codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28.jsonl.zst", bytes: 2048)
        try fixture.write("codex/sessions/2026/10/14/rollout-2026-10-14T10-00-00.jsonl", bytes: 512)
        try fixture.write("codex/archived_sessions/rollout-2026-10-13T00-00-00.jsonl.zst", bytes: 256)
        try fixture.write("codex/.tmp/stale.dat", bytes: 128)
        try fixture.write("codex/auth.json", bytes: 32)

        // MARK: Cursor（`~/.cursor`）
        let session = "cursor/projects/-Users-x-a/agent-transcripts/33333333-3333-3333-3333-333333333333"
        try fixture.write(session + "/44444444-4444-4444-4444-444444444444.jsonl", bytes: 700)
        try fixture.write(session + "/subagents/55555555-5555-5555-5555-555555555555.jsonl", bytes: 300)
        try fixture.write("cursor/assets/未实测.bin", bytes: 64)

        // MARK: DeepSeek Harness
        try fixture.write(harnessRootSuffix + "/sessions/--Users-x-a--/session-66666666-6666-6666-6666-666666666666/session.jsonl.zstd", bytes: 150)
        try fixture.write(harnessRootSuffix + "/settings.yaml", bytes: 20)

        // MARK: 指向工具根之外的符号链接
        try fixture.write("外部数据/big.bin", bytes: 1_000_000)
        try fixture.makeSymbolicLink("codex/external", to: fixture.root.appendingPathComponent("外部数据").path)

        let tools = [
            ConfirmedTool(id: "claude-code", displayName: "Claude Code", toolRootPath: fixture.rootPath + "/claude"),
            ConfirmedTool(id: "codex-cli", displayName: "Codex CLI", toolRootPath: fixture.rootPath + "/codex"),
            ConfirmedTool(id: "cursor", displayName: "Cursor", toolRootPath: fixture.rootPath + "/cursor"),
            ConfirmedTool(
                id: "deepseek-harness",
                displayName: "DeepSeek Harness",
                toolRootPath: fixture.rootPath + "/" + harnessRootSuffix
            ),
        ]

        let auditor = AuditorFileSystem()
        let scan = DeepScanner(fileSystem: auditor).scan(
            tools: tools,
            rules: rules,
            homeDirectory: fixture.rootPath
        )

        // 每台工具都在结果里，一个都没漏。
        XCTAssertEqual(scan.toolReports.map(\.toolID),
                       ["claude-code", "codex-cli", "cursor", "deepseek-harness"])

        // MARK: Claude Code
        let claude = try XCTUnwrap(scan.toolReport(id: "claude-code"))
        XCTAssertEqual(
            claude.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 500, fileCount: 2),
            "主转录 + 旧版 agent 子代理转录都算可归档；`sessions/` 那条未声明的不许混进来"
        )
        XCTAssertEqual(claude.category(.protected)?.occupancy, Occupancy(bytes: 1064, fileCount: 2))
        XCTAssertEqual(
            claude.category(.uncertain)?.summaries.map(\.subpath),
            ["sessions"],
            "规则没声明的 `sessions/…jsonl` 落进不确定（PRD §5.4 的实测结构里 Claude 没有 sessions/）"
        )
        XCTAssertEqual(claude.occupancy.bytes, 500 + 1064 + 8192)

        // MARK: Codex CLI
        let codex = try XCTUnwrap(scan.toolReport(id: "codex-cli"))
        XCTAssertEqual(
            codex.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 2048 + 512 + 256, fileCount: 3),
            "`.zst` 与明文并存、扁平 `archived_sessions/` 都要认（PRD §5.4）"
        )
        XCTAssertEqual(codex.category(.cacheAndLog)?.occupancy, Occupancy(bytes: 128, fileCount: 1))
        XCTAssertEqual(
            codex.category(.protected)?.occupancy,
            Occupancy(bytes: 32, fileCount: 1),
            "`auth.json` 靠内置凭证清单判定，不靠规则"
        )
        // 外部链接：既不进占用，也不被读。
        XCTAssertEqual(codex.unfollowedLinks.map(\.relativePath), ["external"])
        XCTAssertEqual(codex.unfollowedLinks.first?.isInsideToolRoot, false)
        XCTAssertEqual(auditor.writeAttempts, [], "深扫全程零写入：\n\(auditor.writeSummary)")

        // MARK: Cursor
        let cursor = try XCTUnwrap(scan.toolReport(id: "cursor"))
        XCTAssertEqual(
            cursor.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 1000, fileCount: 2),
            "主转录与同会话的 subagents 转录都归可归档（一个会话跨多个文件）"
        )
        XCTAssertEqual(
            cursor.category(.uncertain)?.occupancy,
            Occupancy(bytes: 64, fileCount: 1),
            "`assets/` 在规则里保守归入不确定（PRD §5.4：形态未实测）"
        )

        // MARK: DeepSeek Harness
        let harness = try XCTUnwrap(scan.toolReport(id: "deepseek-harness"))
        XCTAssertEqual(harness.category(.archivableSession)?.occupancy, Occupancy(bytes: 150, fileCount: 1))
        XCTAssertEqual(harness.category(.protected)?.occupancy, Occupancy(bytes: 20, fileCount: 1))

        // MARK: 总账与干扰目录
        XCTAssertEqual(scan.totalOccupancy, Occupancy(
            bytes: Occupancy.sum(scan.toolReports.map(\.occupancy)).bytes,
            fileCount: Occupancy.sum(scan.toolReports.map(\.occupancy)).fileCount
        ))
        XCTAssertFalse(
            scan.toolReports.contains { $0.toolRootPath.contains("claude-bak") },
            "`*-bak` 干扰目录没有任何确认记录，深扫入口是已确认工具，它不该被扫"
        )
    }

    /// 用户确认过、但出厂规则里没有对应规则的工具（未来新增的工具）：
    /// 深扫不能把它静默丢掉，也不能因为「没有规则」就把它算成可归档。
    /// 它照常出现在结果里，内容一律落进**不确定**（最保守的那一类）。
    func test没有对应规则的工具照常出现在结果里且内容全落进不确定() throws {
        let fixture = try DeepScanFixture(named: "bundled-unknown-tool")
        defer { fixture.remove() }

        // 用户确认过、但出厂规则里没有（未来新增的工具）：深扫不能把它静默丢掉。
        try fixture.write("mystery-tool/whatever.jsonl", bytes: 100)
        let ghost = ConfirmedTool(
            id: "mystery-tool",
            displayName: "神秘工具",
            toolRootPath: fixture.rootPath + "/mystery-tool"
        )

        let scan = DeepScanner(fileSystem: RealDiscoveryFileSystem()).scan(
            tools: [ghost],
            rules: try admittedBundledRules(),
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReport(id: "mystery-tool"))
        XCTAssertEqual(report.toolRootPath, fixture.rootPath + "/mystery-tool")
        XCTAssertEqual(report.occupancy, Occupancy(bytes: 100, fileCount: 1), "工具不能被静默丢掉")
        XCTAssertEqual(
            report.category(.archivableSession),
            nil,
            "没有规则声明就没有可归档——这条是本票最要紧的纪律"
        )
        XCTAssertEqual(report.category(.uncertain)?.occupancy, Occupancy(bytes: 100, fileCount: 1))
        XCTAssertEqual(report.category(.uncertain)?.summaries.first?.provenance, .undeclared)
    }
}
