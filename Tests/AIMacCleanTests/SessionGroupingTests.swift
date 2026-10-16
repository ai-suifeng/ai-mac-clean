import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// Seam D3：**会话识别与级联**（issue #26）。
///
/// 深扫回答「每个工具占了多少、其中多少可归档」；这一层回答「这些可归档的文件分别属于
/// 哪一个会话」——GLOSSARY 的「会话」是归档与还原的最小单位，一个会话可能由主转录 +
/// 子代理转录 + 关联数据多个文件组成。
///
/// 断言一律走公开入口 `SessionGrouper.group(tools:rules:homeDirectory:)`，
/// 看四件事：会话 ID、项目、原始总字节数 / 文件数、文件清单与各自角色。
/// 树形照抄 PRD §5.4 / §14 的实测结构（`.claudebak` 证实的旧结构、codex 的扁平
/// `archived_sessions/`、cursor 的 `agent-transcripts/<uuid>/subagents/`、
/// harness 的双横线编码），**真实数据目录绝不参与**（issue #14 的护栏在夹具那层拦）。
final class SessionGroupingTests: XCTestCase {

    // MARK: - Claude Code：主转录 + 旧版 agent 子代理（验收 1）

    func testClaude主转录与旧版agent子代理归为同一个会话() throws {
        let fixture = try DeepScanFixture(named: "session-claude")
        defer { fixture.remove() }

        let sessionID = "11111111-1111-1111-1111-111111111111"
        let main = try fixture.write(".claude/projects/-Users-x-a/\(sessionID).jsonl", bytes: 400)
        let agent = try fixture.write(".claude/projects/-Users-x-a/agent-a86b373.jsonl", bytes: 100)
        // 受保护与「不确定」的文件都不属于任何会话，不得混进会话文件清单。
        try fixture.write(".claude/settings.json", bytes: 64)
        try fixture.write(".claude/projects/-Users-x-a/sessions-index.json", bytes: 35)

        let report = try group(fixture, tools: [claudeTool(fixture)])

        let tool = try XCTUnwrap(report.toolReport(id: "claude-code"))
        XCTAssertEqual(tool.sessions.count, 1, "主转录与旧版 agent 子代理必须是同一个会话")
        let session = try XCTUnwrap(tool.sessions.first)

        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.toolID, "claude-code")
        XCTAssertEqual(session.toolDisplayName, "Claude Code")
        XCTAssertEqual(session.occupancy, Occupancy(bytes: 500, fileCount: 2))
        XCTAssertEqual(
            session.project,
            .encodedDirectory(name: "-Users-x-a", scheme: .singleDash),
            "项目按规则声明的编码方案给出**编码目录名**，绝不反向解码（PRD §5.3）"
        )

        XCTAssertEqual(session.files.map(\.role), [.mainTranscript, .subagentTranscript],
                       "文件按相对路径排序，角色各自标明")
        XCTAssertEqual(session.files.map(\.relativePath), [
            "projects/-Users-x-a/\(sessionID).jsonl",
            "projects/-Users-x-a/agent-a86b373.jsonl",
        ])
        XCTAssertEqual(session.files.map(\.path), [main.path, agent.path])
        XCTAssertEqual(session.files.map(\.bytes), [400, 100])
        XCTAssertEqual(session.files.map(\.pattern), [
            "projects/<encodedPath>/<uuid>.jsonl",
            "projects/<encodedPath>/agent-<uuid>.jsonl",
        ])

        XCTAssertEqual(tool.unmatched, [], "这棵树里没有归不了组的可归档文件")
        XCTAssertEqual(tool.archivableOccupancy, Occupancy(bytes: 500, fileCount: 2))
    }

    /// 会话的「最后修改时间」= 其全部文件里最晚的那个（会话最后一次有动静的时刻）。
    func test会话最后修改时间取全部文件里最晚的一个() throws {
        let fixture = try DeepScanFixture(named: "session-mtime")
        defer { fixture.remove() }

        let sessionID = "22222222-2222-2222-2222-222222222222"
        let main = try fixture.write(".claude/projects/-Users-x-a/\(sessionID).jsonl", bytes: 10)
        let agent = try fixture.write(".claude/projects/-Users-x-a/agent-a86b373.jsonl", bytes: 10)

        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_500)
        try setModificationDate(older, at: main)
        try setModificationDate(newer, at: agent)

        let report = try group(fixture, tools: [claudeTool(fixture)])
        let session = try XCTUnwrap(report.toolReport(id: "claude-code")?.sessions.first)

        XCTAssertEqual(session.files.map(\.lastModified), [older, newer])
        XCTAssertEqual(session.lastModified, newer, "取最晚的一个，而不是主转录那一个")
    }

    // MARK: - 夹具与断言助手

    private func group(
        _ fixture: DeepScanFixture,
        tools: [ConfirmedTool]
    ) throws -> SessionGroupingReport {
        SessionGrouper(fileSystem: RealDiscoveryFileSystem()).group(
            tools: tools,
            rules: try admittedBundledRules(),
            homeDirectory: fixture.rootPath
        )
    }

    private func claudeTool(_ fixture: DeepScanFixture) -> ConfirmedTool {
        ConfirmedTool(
            id: "claude-code",
            displayName: "Claude Code",
            toolRootPath: fixture.rootPath + "/.claude"
        )
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
