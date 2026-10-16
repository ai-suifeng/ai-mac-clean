import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #26：拿**出厂规则**在实测形状的树上跑一遍会话归组，并与同一次深扫**对账**。
///
/// 前面几组用例用出厂规则把每种工具的语义钉细；这一组回答的是另一个问题：
/// 「同一棵树、同一套规则，深扫说可归档的字节 / 文件数，与会话归组给出的
/// 会话之和 + 归不了组的那部分，对不对得上」。对不上就说明有文件被漏掉或凭空多出，
/// 而 M3 要按会话归档、M4 要按清单还原——账对不上，归档就会丢东西。
///
/// 树形照抄 PRD §5.4 / §14 的实测结构：旧结构（`~/.claudebak` 证实的 `file-history/`、
/// `todos/`）、Codex 的 `.zst` 与明文并存 + 扁平 `archived_sessions/` + fork 双 UUID、
/// Cursor 的 `agent-transcripts/<uuid>/subagents/`、Harness 的双横线编码与
/// `session-<uuid>/session.jsonl.zstd`，另加 `*-bak` 干扰目录与指向外部的符号链接。
final class SessionGroupingBundledRuleTests: XCTestCase {

    private let harnessRootSuffix = "Library/Application Support/deepseek-harness-desktop/harness-home"

    func test出厂规则在实测形状的树上归组并与深扫逐字节对账() throws {
        let fixture = try DeepScanFixture(named: "session-bundled-rules")
        defer { fixture.remove() }

        let rules = try admittedBundledRules()

        // MARK: Claude Code（`~/.claude`：新版没有 file-history/todos，旧版有）
        let claudeLegacyID = "11111111-1111-1111-1111-111111111111"
        let claudeSecondID = "22222222-2222-2222-2222-222222222222"
        try fixture.write(".claude/projects/-Users-x-a/\(claudeLegacyID).jsonl", bytes: 400)
        try fixture.write(".claude/projects/-Users-x-a/agent-a86b373.jsonl", bytes: 100)
        try fixture.write(".claude/file-history/\(claudeLegacyID)/9f2b@v1", bytes: 50)
        try fixture.write(".claude/todos/\(claudeLegacyID)-agent-\(claudeLegacyID).json", bytes: 20)
        try fixture.write(".claude/projects/-Users-x-b/\(claudeSecondID).jsonl", bytes: 300)
        try fixture.write(".claude/projects/-Users-x-a/sessions-index.json", bytes: 35)
        try fixture.write(".claude/skills/我的技能/SKILL.md", bytes: 1000)
        try fixture.write(".claude/settings.json", bytes: 64)
        try fixture.write("claude-bak/projects/-Users-x-a/99999999-9999-9999-9999-999999999999.jsonl", bytes: 4096)

        // MARK: Codex CLI（`~/.codex`）
        let codexForkRootID = "0199f45a-e697-7243-a7fb-a441b54cb42e"
        let codexForkChildID = "0199f45c-29dc-7fc1-9228-9662f09ed7b2"
        let codexPlainID = "0199f461-1111-2222-3333-444455556666"
        let codexArchivedID = "019ac812-776b-73d3-ad2f-66d3463ec010"
        try fixture.write(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-\(codexForkRootID).jsonl.zst",
            bytes: 2048
        )
        try fixture.write(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T10-00-00-\(codexPlainID).jsonl",
            bytes: 512
        )
        try fixture.write(
            ".codex/sessions/2026/10/25/rollout-2026-10-25T10-51-08-\(codexForkRootID)_\(codexForkChildID).jsonl.zst",
            bytes: 400
        )
        try fixture.write(
            ".codex/archived_sessions/rollout-2026-10-13T00-00-00-\(codexArchivedID).jsonl.zst",
            bytes: 256
        )
        try fixture.write(".codex/.tmp/stale.dat", bytes: 128)
        try fixture.write(".codex/auth.json", bytes: 32)
        try fixture.write(".codex/config.toml", bytes: 16)

        // MARK: Cursor（`~/.cursor`）
        let cursorSessionID = "33333333-3333-3333-3333-333333333333"
        let cursorSubagentID = "44444444-4444-4444-4444-444444444444"
        let cursorDirectory = ".cursor/projects/-Users-x-a/agent-transcripts/\(cursorSessionID)"
        try fixture.write("\(cursorDirectory)/\(cursorSessionID).jsonl", bytes: 700)
        try fixture.write("\(cursorDirectory)/subagents/\(cursorSubagentID).jsonl", bytes: 300)
        try fixture.write(".cursor/assets/未实测.bin", bytes: 64)

        // MARK: DeepSeek Harness
        let harnessSessionID = "55555555-5555-5555-5555-555555555555"
        try fixture.write(
            harnessRootSuffix + "/sessions/--Users-x-a--/session-\(harnessSessionID)/session.jsonl.zstd",
            bytes: 150
        )
        try fixture.write(harnessRootSuffix + "/settings.yaml", bytes: 20)

        // MARK: 指向工具根之外的符号链接（两边都不跟随）
        try fixture.write("外部数据/big.bin", bytes: 1_000_000)
        try fixture.makeSymbolicLink(".codex/external", to: fixture.root.appendingPathComponent("外部数据").path)

        let tools = [
            ConfirmedTool(id: "claude-code", displayName: "Claude Code", toolRootPath: fixture.rootPath + "/.claude"),
            ConfirmedTool(id: "codex-cli", displayName: "Codex CLI", toolRootPath: fixture.rootPath + "/.codex"),
            ConfirmedTool(id: "cursor", displayName: "Cursor", toolRootPath: fixture.rootPath + "/.cursor"),
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
        let grouping = SessionGrouper(fileSystem: auditor).group(
            tools: tools,
            rules: rules,
            homeDirectory: fixture.rootPath
        )

        // MARK: 对账：每个工具「会话内 + 归不了组」必须等于深扫的可归档
        XCTAssertEqual(grouping.toolReports.map(\.toolID), scan.toolReports.map(\.toolID))
        for tool in tools {
            let deepScan = try XCTUnwrap(scan.toolReport(id: tool.id))
            let sessions = try XCTUnwrap(grouping.toolReport(id: tool.id))
            XCTAssertEqual(
                sessions.archivableOccupancy,
                deepScan.archivableOccupancy,
                "\(tool.id)：会话内 %@ + 未归组 %@ 与深扫的可归档 %@ 对不上账"
            )
        }
        XCTAssertEqual(grouping.archivableOccupancy, scan.archivableOccupancy)

        // MARK: Claude Code：两个项目各一个会话，旧结构关联数据跟着同一条会话
        let claude = try XCTUnwrap(grouping.toolReport(id: "claude-code"))
        XCTAssertEqual(claude.sessions.map(\.id), [claudeLegacyID, claudeSecondID])
        XCTAssertEqual(claude.session(id: claudeLegacyID)?.occupancy, Occupancy(bytes: 570, fileCount: 4))
        XCTAssertEqual(claude.session(id: claudeLegacyID)?.files.map(\.role),
                       [.associatedData, .mainTranscript, .subagentTranscript, .associatedData])
        XCTAssertEqual(claude.session(id: claudeSecondID)?.occupancy, Occupancy(bytes: 300, fileCount: 1))
        XCTAssertEqual(claude.session(id: claudeSecondID)?.project,
                       .encodedDirectory(name: "-Users-x-b", scheme: .singleDash))
        XCTAssertEqual(claude.unmatched, [])

        // MARK: Codex：fork 与它派生自的转录合成一个会话；`.zst` 与明文、扁平归档都在
        let codex = try XCTUnwrap(grouping.toolReport(id: "codex-cli"))
        XCTAssertEqual(codex.sessions.map(\.id), [codexForkRootID, codexPlainID, codexArchivedID].sorted())
        XCTAssertEqual(codex.session(id: codexForkRootID)?.occupancy, Occupancy(bytes: 2448, fileCount: 2))
        XCTAssertEqual(codex.session(id: codexPlainID)?.occupancy, Occupancy(bytes: 512, fileCount: 1))
        XCTAssertEqual(codex.session(id: codexArchivedID)?.occupancy, Occupancy(bytes: 256, fileCount: 1))
        XCTAssertEqual(codex.unmatched, [])

        // MARK: Cursor 与 Harness
        let cursor = try XCTUnwrap(grouping.toolReport(id: "cursor"))
        XCTAssertEqual(cursor.sessions.map(\.id), [cursorSessionID])
        XCTAssertEqual(cursor.session(id: cursorSessionID)?.occupancy, Occupancy(bytes: 1000, fileCount: 2))
        XCTAssertEqual(cursor.session(id: cursorSessionID)?.files.map(\.role),
                       [.mainTranscript, .subagentTranscript])

        let harness = try XCTUnwrap(grouping.toolReport(id: "deepseek-harness"))
        XCTAssertEqual(harness.sessions.map(\.id), ["session-\(harnessSessionID)"])
        XCTAssertEqual(harness.session(id: "session-\(harnessSessionID)")?.occupancy,
                       Occupancy(bytes: 150, fileCount: 1))

        // MARK: 干扰项
        XCTAssertFalse(
            grouping.sessions.contains { $0.files.contains { $0.relativePath.contains("claude-bak") } },
            "`*-bak` 干扰目录没有任何确认记录，会话归组的入口是已确认工具"
        )
        XCTAssertEqual(
            codex.unfollowedLinks.map(\.relativePath), ["external"],
            "指向工具根之外的链接不参与会话归组"
        )
        XCTAssertEqual(auditor.writeAttempts, [], "会话归组全程零写入：\n\(auditor.writeSummary)")
    }
}
