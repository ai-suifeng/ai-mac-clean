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

    // MARK: - Claude Code：旧结构的关联数据（验收 1、6）

    /// `~/.claudebak` 证实的旧结构：`file-history/<会话UUID>/…` 与
    /// `todos/<会话UUID>-agent-<另一个UUID>.json` 都按**会话 UUID** 级联到同一个会话。
    func testClaude旧结构的fileHistory与todos按会话UUID级联() throws {
        let fixture = try DeepScanFixture(named: "session-claude-legacy")
        defer { fixture.remove() }

        let sessionID = "33333333-3333-3333-3333-333333333333"
        try fixture.write(".claude/projects/-Users-x-a/\(sessionID).jsonl", bytes: 400)
        try fixture.write(".claude/file-history/\(sessionID)/9f2b@v1", bytes: 50)
        try fixture.write(".claude/file-history/\(sessionID)/9f2b@v2", bytes: 60)
        try fixture.write(".claude/todos/\(sessionID)-agent-\(sessionID).json", bytes: 20)

        let report = try group(fixture, tools: [claudeTool(fixture)])
        let tool = try XCTUnwrap(report.toolReport(id: "claude-code"))

        XCTAssertEqual(tool.unmatched, [])
        XCTAssertEqual(tool.sessions.count, 1)
        let session = try XCTUnwrap(tool.sessions.first)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.occupancy, Occupancy(bytes: 530, fileCount: 4))
        XCTAssertEqual(session.files.map(\.relativePath), [
            "file-history/\(sessionID)/9f2b@v1",
            "file-history/\(sessionID)/9f2b@v2",
            "projects/-Users-x-a/\(sessionID).jsonl",
            "todos/\(sessionID)-agent-\(sessionID).json",
        ])
        XCTAssertEqual(session.files.map(\.role),
                       [.associatedData, .associatedData, .mainTranscript, .associatedData])
        XCTAssertEqual(session.files.map(\.pattern), [
            "file-history/<uuid>/**",
            "file-history/<uuid>/**",
            "projects/<encodedPath>/<uuid>.jsonl",
            "todos/<uuid>-agent-<uuid>.json",
        ])
    }

    /// 新版 `~/.claude` 实测没有 `file-history/`、`todos/`、`statsig/`：
    /// 缺失时静默跳过，既不报错、也不产生「未归组」噪音，而且**根本不去列举**它。
    func test规则声明的旧结构目录缺失时静默跳过() throws {
        let fixture = try DeepScanFixture(named: "session-claude-new-shape")
        defer { fixture.remove() }

        let sessionID = "44444444-4444-4444-4444-444444444444"
        try fixture.write(".claude/projects/-Users-x-a/\(sessionID).jsonl", bytes: 128)

        let recorder = RecordingDiscoveryFileSystem()
        let report = SessionGrouper(fileSystem: recorder).group(
            tools: [claudeTool(fixture)],
            rules: try admittedBundledRules(),
            homeDirectory: fixture.rootPath
        )

        let tool = try XCTUnwrap(report.toolReport(id: "claude-code"))
        XCTAssertEqual(tool.sessions.count, 1)
        XCTAssertEqual(tool.sessions.first?.occupancy, Occupancy(bytes: 128, fileCount: 1))
        XCTAssertEqual(tool.unmatched, [])
        XCTAssertEqual(tool.unreadable, [], "路径不存在不是「读不到」，不该进读不到清单")
        XCTAssertEqual(
            recorder.touched(underOrEqual: fixture.rootPath + "/.claude/file-history"), [],
            "缺失的旧结构目录连列举都不该发生"
        )
        XCTAssertEqual(recorder.writeAttempts, [], "会话归组全程零写入：\n\(recorder.writeSummary)")
    }

    /// 转录已不在、只剩关联数据：不能猜、也不能丢——如实列为「找不到对应会话」。
    func test孤悬的关联数据如实呈现为未归组() throws {
        let fixture = try DeepScanFixture(named: "session-orphan-associated")
        defer { fixture.remove() }

        let ghost = "55555555-5555-5555-5555-555555555555"
        try fixture.write(".claude/file-history/\(ghost)/9f2b@v1", bytes: 30)
        try fixture.write(".claude/todos/\(ghost)-agent-\(ghost).json", bytes: 12)

        let report = try group(fixture, tools: [claudeTool(fixture)])
        let tool = try XCTUnwrap(report.toolReport(id: "claude-code"))

        XCTAssertEqual(tool.sessions, [])
        XCTAssertEqual(tool.unmatched.map(\.gap), [
            .sessionNotFound(sessionID: ghost),
            .sessionNotFound(sessionID: ghost),
        ])
        XCTAssertEqual(tool.unmatched.map(\.relativePath), [
            "file-history/\(ghost)/9f2b@v1",
            "todos/\(ghost)-agent-\(ghost).json",
        ])
        XCTAssertEqual(tool.unmatchedOccupancy, Occupancy(bytes: 42, fileCount: 2))
        XCTAssertEqual(tool.archivableOccupancy, Occupancy(bytes: 42, fileCount: 2),
                       "归不进会话的可归档文件仍然算在这台工具的可归档占用里")
    }

    // MARK: - 同级转录的归属：保守取值

    /// `agent-*.jsonl` 文件名里没有会话 UUID，只能按「与主转录同目录」关联。
    /// 同一目录下有多份主转录时归属无法确定：**不猜**，如实列出候选。
    func test同一目录下多份主转录时子代理转录不猜归属() throws {
        let fixture = try DeepScanFixture(named: "session-ambiguous-sibling")
        defer { fixture.remove() }

        let first = "66666666-6666-6666-6666-666666666666"
        let second = "77777777-7777-7777-7777-777777777777"
        try fixture.write(".claude/projects/-Users-x-a/\(first).jsonl", bytes: 100)
        try fixture.write(".claude/projects/-Users-x-a/\(second).jsonl", bytes: 200)
        try fixture.write(".claude/projects/-Users-x-a/agent-a86b373.jsonl", bytes: 10)

        let report = try group(fixture, tools: [claudeTool(fixture)])
        let tool = try XCTUnwrap(report.toolReport(id: "claude-code"))

        XCTAssertEqual(tool.sessions.map(\.id), [first, second])
        XCTAssertEqual(tool.sessions.map(\.occupancy), [
            Occupancy(bytes: 100, fileCount: 1),
            Occupancy(bytes: 200, fileCount: 1),
        ], "存疑的同级转录不得并进任何一个会话")
        XCTAssertEqual(tool.unmatched.map(\.gap), [
            .ambiguousMainTranscript(directory: "projects/-Users-x-a", candidates: [first, second]),
        ])
    }

    /// 目录里只有子代理转录、主转录已经不在：同样是「归不了组」，如实呈现。
    func test没有主转录时子代理转录如实呈现为未归组() throws {
        let fixture = try DeepScanFixture(named: "session-sibling-without-main")
        defer { fixture.remove() }

        try fixture.write(".claude/projects/-Users-x-a/agent-a86b373.jsonl", bytes: 10)

        let report = try group(fixture, tools: [claudeTool(fixture)])
        let tool = try XCTUnwrap(report.toolReport(id: "claude-code"))

        XCTAssertEqual(tool.sessions, [])
        XCTAssertEqual(tool.unmatched.map(\.gap), [
            .noMainTranscript(directory: "projects/-Users-x-a"),
        ])
        XCTAssertEqual(tool.unmatched.first?.pattern, "projects/<encodedPath>/agent-<uuid>.jsonl")
    }

    // MARK: - Codex CLI（验收 2）

    /// 明文 `.jsonl` 与自带压缩的 `.jsonl.zst` 都要识别（实测 792 个文件里 771 个是 `.zst`），
    /// 扁平的 `archived_sessions/` 也要识别；`.zst` **只按扩展名认，绝不解码**——
    /// 夹具里那份 `.zst` 的内容根本不是一个合法的 zstd 流，识别与它无关。
    func testCodex识别明文与zst并识别扁平archivedSessions() throws {
        let fixture = try DeepScanFixture(named: "session-codex")
        defer { fixture.remove() }

        let archived = "0199f45a-e697-7243-a7fb-a441b54cb42e"
        let compressed = "0199f45c-29dc-7fc1-9228-9662f09ed7b2"
        let plain = "0199f461-1111-2222-3333-444455556666"
        try fixture.write(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-\(compressed).jsonl.zst",
            text: "这不是一个合法的 zstd 流"
        )
        try fixture.write(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T10-00-00-\(plain).jsonl",
            bytes: 512
        )
        try fixture.write(
            ".codex/archived_sessions/rollout-2026-10-13T00-00-00-\(archived).jsonl.zst",
            bytes: 256
        )
        // 规则声明的缓存与受保护项都不进会话。
        try fixture.write(".codex/.tmp/stale.dat", bytes: 128)
        try fixture.write(".codex/auth.json", bytes: 32)

        let recorder = RecordingDiscoveryFileSystem()
        let report = SessionGrouper(fileSystem: recorder).group(
            tools: [codexTool(fixture)],
            rules: try admittedBundledRules(),
            homeDirectory: fixture.rootPath
        )

        let tool = try XCTUnwrap(report.toolReport(id: "codex-cli"))
        XCTAssertEqual(tool.sessions.map(\.id), [archived, compressed, plain].sorted())
        XCTAssertEqual(tool.unmatched, [])

        let compressedSession = try XCTUnwrap(tool.session(id: compressed))
        XCTAssertEqual(compressedSession.occupancy,
                       Occupancy(bytes: Int64(Data("这不是一个合法的 zstd 流".utf8).count), fileCount: 1),
                       "`.zst` 按扩展名识别、按原始（压缩后）字节数计，不解码")
        XCTAssertEqual(compressedSession.files.map(\.role), [.mainTranscript])

        XCTAssertEqual(tool.session(id: plain)?.occupancy, Occupancy(bytes: 512, fileCount: 1))
        XCTAssertEqual(tool.session(id: archived)?.occupancy, Occupancy(bytes: 256, fileCount: 1))
        XCTAssertEqual(
            tool.session(id: archived)?.project,
            .declaredInFileField(fieldPath: "session_meta.payload.cwd"),
            "Codex 的项目路径在文件内字段：本阶段不读文件内容，如实说明而没有值"
        )

        XCTAssertFalse(
            recorder.accesses.contains { access in
                if case .header = access { return true }
                return false
            },
            "会话归组只读元数据：一次文件内容都不许读（`.zst` 更不许解码）"
        )
    }

    /// fork 会话的文件名含两个 UUID，规则已声明「文件名不是稳定 ID，一个逻辑会话可能跨
    /// 多个文件」。本层选择的语义是：**取文件名里第一个 UUID 形状的记号**（fork 形态下即
    /// 父 UUID）。于是 fork 出来的文件与它派生自的那份转录归到同一个逻辑会话——这条断言
    /// 就是那条语义的钉子。
    func testCodex的fork文件与它派生自的转录归为同一个会话() throws {
        let fixture = try DeepScanFixture(named: "session-codex-fork")
        defer { fixture.remove() }

        let parent = "019a1946-b9bb-7063-918d-534c8605c3ef"
        let fork = "019a1946-e589-7463-9921-23a854f7cc1c"
        try fixture.write(
            ".codex/sessions/2026/10/25/rollout-2026-10-25T10-50-56-\(parent).jsonl.zst",
            bytes: 1000
        )
        try fixture.write(
            ".codex/sessions/2026/10/25/rollout-2026-10-25T10-51-08-\(parent)_\(fork).jsonl.zst",
            bytes: 400
        )

        let report = try group(fixture, tools: [codexTool(fixture)])
        let tool = try XCTUnwrap(report.toolReport(id: "codex-cli"))

        XCTAssertEqual(tool.sessions.count, 1, "fork 与它派生自的转录是同一个逻辑会话")
        let session = try XCTUnwrap(tool.sessions.first)
        XCTAssertEqual(session.id, parent, "会话 ID 取文件名里第一个 UUID（fork 链的根）")
        XCTAssertEqual(session.occupancy, Occupancy(bytes: 1400, fileCount: 2))
        XCTAssertEqual(session.files.map(\.role), [.mainTranscript, .mainTranscript])
        XCTAssertEqual(session.files.map(\.pattern), [
            "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]",
            "sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>-<uuid:parent>_<uuid:fork>.jsonl[.zst]",
        ])
    }

    /// 同一个逻辑会话既可能在 `sessions/` 里，也可能已经被工具自己搬去扁平的
    /// `archived_sessions/`。按会话 UUID 归并（而不是按目录或文件名），
    /// 因此同一份会话不会因为换了存放位置就分裂成两个。
    func testCodex同一会话UUID在sessions与archivedSessions里归并为一个() throws {
        let fixture = try DeepScanFixture(named: "session-codex-relocated")
        defer { fixture.remove() }

        let sessionID = "019ac812-776b-73d3-ad2f-66d3463ec010"
        try fixture.write(
            ".codex/sessions/2026/11/28/rollout-2026-11-28T09-27-24-\(sessionID).jsonl.zst",
            bytes: 100
        )
        try fixture.write(
            ".codex/archived_sessions/rollout-2026-11-28T09-27-24-\(sessionID).jsonl.zst",
            bytes: 200
        )

        let report = try group(fixture, tools: [codexTool(fixture)])
        let tool = try XCTUnwrap(report.toolReport(id: "codex-cli"))

        XCTAssertEqual(tool.sessions.count, 1)
        XCTAssertEqual(tool.sessions.first?.occupancy, Occupancy(bytes: 300, fileCount: 2))
        XCTAssertEqual(tool.sessions.first?.files.map(\.relativePath), [
            "archived_sessions/rollout-2026-11-28T09-27-24-\(sessionID).jsonl.zst",
            "sessions/2026/11/28/rollout-2026-11-28T09-27-24-\(sessionID).jsonl.zst",
        ])
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

    private func codexTool(_ fixture: DeepScanFixture) -> ConfirmedTool {
        ConfirmedTool(
            id: "codex-cli",
            displayName: "Codex CLI",
            toolRootPath: fixture.rootPath + "/.codex"
        )
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
