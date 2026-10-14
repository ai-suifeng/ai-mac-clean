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
            rules: try admittedBundledRules(),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.displayPath, "~/.local/share/opencode")
        XCTAssertEqual(candidate.ruleIdentifier, "opencode")
    }

    /// **已记录的偏差**（PRD §13.1）：spec #7 / US2 写的是「浅扫只遍历一级子目录」，
    /// 但规则声明的工具根在扫描根之下**任意深度**都会被补看一次。
    ///
    /// 理由：Harness 的工具根是 `~/Library/Application Support` 的孙子（PRD §14.5），
    /// 只扫一层就永远发现不了它，而「发现非标准位置」是 US7 的要求。
    ///
    /// 这条断言钉住偏差的**成本边界**：补漏只判断声明路径本身存在与否，
    /// 路径不存在就是「没有可看的东西」，不会为了找它去枚举父目录。
    func test扫描深度偏差只判断声明路径存在与否而不去枚举父目录() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 扫描根 `~/Library/Application Support` 的孙子：补漏能捡起来。
        try fixture.makeFile(
            "Library/Application Support/deepseek-harness-desktop/harness-home"
                + "/sessions/--Users-xiaowei-work-amc-wt-12--/session-9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f"
                + "/session.jsonl.zstd",
            contents: ""
        )
        // 同一条规则的**另一个**声明根，路径在磁盘上压根不存在：
        // 补漏对它是「没有可看的东西」，而不是一次失败，更不会去枚举它缺失的父目录。
        let ghostRule = RuleFixtures.harnessJSON
            .replacingOccurrences(
                of: "\"~/Library/Application Support/deepseek-harness-desktop/harness-home\"",
                with: "\"~/Library/Application Support/never-created-desktop/harness-home\""
            )

        let result = ToolDiscoverer(
            rules: try admittedRules([ghostRule]),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(
            result.candidates.map(\.toolRootPath),
            [],
            "声明的工具根在磁盘上不存在时，补漏不产生候选：\(result.candidates.map(\.toolRootPath))"
        )
        XCTAssertTrue(
            result.unreadableDirectories.isEmpty,
            "路径缺失不是读不到，不该被报成权限类问题：\(result.unreadableDirectories)"
        )
    }

    // MARK: - 切片 6：负向名单与干扰项（User Story 5、6、9；PRD A1）

    func test伴生小工具与只有名字像的目录都不进候选() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 实测存在的伴生小工具：`~/.claude-tap`、`~/.codexbar`、`~/.codexhost`、`~/.antigravity_cockpit`。
        try fixture.makeFile(".claude-tap/config.json", contents: "{}")
        try fixture.makeFile(".codexbar/settings.toml", contents: "")
        try fixture.makeFile(".codexhost/notes.md", contents: "")
        try fixture.makeFile(".antigravity_cockpit/state.json", contents: "{}")
        // 只有名字像：连 `claude` 这个词都在名字里。
        try fixture.makeFile("claude-notes/readme.md", contents: "# 笔记")
        // 有结构、但没有任何规则声明过这个工具根：结构指纹也不能凭空造出候选。
        try fixture.makeFile(
            ".codexbar/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: ""
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON, RuleFixtures.codexJSON]),
            hints: DiscoveryHints(
                nameKeywords: ["claude-code": ["claude"], "codex-cli": ["codex"]],
                negativeNamePatterns: ["*bak*", "*backup*", ".claude-*", "*.bar", "*.host"]
            ),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertTrue(
            result.candidates.isEmpty,
            "名字像不等于工具：\(result.candidates.map(\.toolRootPath))"
        )
    }

    func test负向名单把旧快照目录降为低置信度疑似() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 实测：`~/.claudebak` 是 `~/.claude` 的旧快照（798M），内部确实是会话形状。
        // 规则声明了它（用户想看得见它），因此它**会**进候选——但必须是「疑似」，
        // 绝不能是高置信度的工具本身（PRD A1）。
        try fixture.makeFile(".claudebak/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        let snapshotRule = RuleFixtures.claudeCodeJSON
            .replacingOccurrences(of: "\"~/.claude\"", with: "\"~/.claudebak\"")

        let result = ToolDiscoverer(
            rules: try admittedRules([snapshotRule]),
            // 词表按**实测名字**写：PRD §4.3 列的 `*-bak` / `*.bak*` 匹配不到实测的
            // `~/.claudebak`（它结尾是 "bak"，中间没有短横线也没有 ".bak"），
            // 因此覆盖实测形状要写 `*bak*`。
            hints: DiscoveryHints(negativeNamePatterns: ["*bak*", "*backup*"]),
            externalEvidence: ExternalEvidence(applicationNames: ["Claude"]),
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.ruleIdentifier, "claude-code")
        XCTAssertEqual(candidate.confidence, .low, "负向名单里的名字不能是高置信度候选")
        XCTAssertTrue(candidate.isSuspicious)
        XCTAssertEqual(candidate.demotions, [.negativeNamePattern("*bak*")])
        XCTAssertFalse(
            candidate.signals.structuralFingerprints.isEmpty,
            "降权不改变它确实命中结构事实这件事"
        )
    }

    /// 负向名单只比对**扫描器真正判定的那些段**：工具根自身的名字，以及它相对扫描根的路径。
    ///
    /// 它绝不该去比对 `$HOME` **以上**的段：否则一个叫 `…-backup/Users/x` 的主目录
    /// 会把该主目录下每一个候选都降权成疑似——降权理由写在界面上却是
    /// 「命中负向名单 *backup*」，而那条路径本身一点问题都没有。
    func test负向名单不比对主目录以上的路径段() throws {
        let outer = try TemporaryDirectoryFixture(named: "host")
        defer { outer.remove() }

        // 主目录自己的名字里含 `backup`——比 `$HOME` 高一层的路径段。
        let home = try outer.makeDirectory("my-backup-home").path
        try writeTestFile(
            relativePath: "my-backup-home/.claude/projects/-Users-xiaowei-amc-wt-12/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: DiscoveryFixture.sampleTranscriptLine,
            in: outer
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON]),
            hints: DiscoveryHints(negativeNamePatterns: ["*backup*"]),
            homeDirectory: home
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(
            candidate.demotions, [],
            "主目录的名字不是扫描器判定的对象，命中它说明比对范围越过了扫描根：\(candidate.demotions)"
        )
        XCTAssertFalse(candidate.isSuspicious)
        // 结构指纹 + 文件头字段特征 = 高（这里刻意不降权，主目录叫什么与它无关）。
        XCTAssertEqual(candidate.confidence, .high)
    }

    func test名称关键词只影响顺序不影响入列() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // `.claude` 命中结构、`.codex` 也命中结构；关键词只是让命中关键词的排前面。
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: #"{"type":"session_meta","payload":{}}"# + "\n"
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON, RuleFixtures.codexJSON]),
            // 只给 codex 关键词：谁在前由词表决定，但两个候选都得在列。
            hints: DiscoveryHints(nameKeywords: ["codex-cli": ["codex"]]),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(
            result.candidates.map(\.ruleIdentifier),
            ["codex-cli", "claude-code"],
            "命中关键词的排前面；没命中关键词的那个**照样在列**"
        )
    }

    // MARK: - 切片 7：符号链接不跟随、权限错误按目录隔离（User Story 12、14）

    func test指向树外的符号链接既不被遍历也不会把链接目标变成候选() throws {
        let outside = try TemporaryDirectoryFixture(named: "link-target")
        defer { outside.remove() }

        // 树外有完整的 Claude 与 Codex 工具根形状。
        try writeTestFile(
            relativePath: "outside-claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: DiscoveryFixture.sampleTranscriptLine,
            in: outside
        )
        try writeTestFile(
            relativePath: "outside-codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: "",
            in: outside
        )

        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // `.claude` 是真目录，但里面的 projects 指向树外：链接里的会话文件不算结构证据。
        try fixture.makeFile(".claude/settings.json", contents: "{}")
        try fixture.makeSymbolicLink(
            ".claude/projects",
            pointingTo: outside.url.path + "/outside-claude/projects"
        )
        // `.codex` 本身就是指向树外的链接：PRD §14.5 说工具根本身不是链接，
        // 浅扫不跟随符号链接，因此它不进候选，链接目标里的目录也不会被当成候选。
        try fixture.makeSymbolicLink(".codex", pointingTo: outside.url.path + "/outside-codex")
        try fixture.makeSymbolicLink("vendor", pointingTo: outside.url.path + "/outside-codex")

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON, RuleFixtures.codexJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(
            result.candidates.map(\.toolRootPath),
            [fixture.homePath + "/.claude"],
            "指向树外的符号链接既不进候选，也不会把链接目标变成候选"
        )
        let claudeCandidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(
            claudeCandidate.confidence, .low,
            "链接里的会话文件不算结构证据：\(claudeCandidate.signals.structuralFingerprints)"
        )
    }

    func test无权访问的目录被跳过并在结果里说明整体扫描不失败() throws {
        try XCTSkipIf(getuid() == 0, "root 会绕过目录权限，这个用例在 root 下没有意义")

        let fixture = try DiscoveryFixture()
        defer {
            fixture.restoreAccess(toRelativePath: ".codex/sessions")
            fixture.home.remove()
        }

        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: ""
        )
        try fixture.denyAccess(toRelativePath: ".codex/sessions")

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON, RuleFixtures.codexJSON]),
            homeDirectory: fixture.homePath
        ).discover()

        // 整体扫描没失败：可读的那个工具根照常发现。
        XCTAssertTrue(
            result.candidates.contains { $0.toolRootPath == fixture.homePath + "/.claude" },
            "一个目录读不到不应该影响其它目录：\(result.candidates.map(\.toolRootPath))"
        )
        // 读不到的位置逐个说明。
        let unreadable = try XCTUnwrap(
            result.unreadableDirectories.first { $0.path == fixture.homePath + "/.codex/sessions" },
            "读不到的位置必须在结果里说明：\(result.unreadableDirectories)"
        )
        XCTAssertTrue(
            unreadable.description.contains("权限不足"),
            "说明要指名原因，而不是一句看不懂的系统错误：\(unreadable.description)"
        )
    }

    // MARK: - 切片 8：词表来自可更新的配置文件（PRD §4.3）

    func test词表从配置文件读入而不是写死在代码里() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        let path = try fixture.writeHintsFile(
            """
            {
              "schemaVersion": 1,
              "nameKeywords": { "claude-code": ["claude"], "codex-cli": ["codex", "openai"] },
              "negativeNamePatterns": ["*bak*", "*backup*", ".claude-*", ".codexbar", ".codexhost"]
            }
            """
        )

        let hints = try DiscoveryHints.load(from: URL(fileURLWithPath: path))

        XCTAssertEqual(hints.keywords(forRuleIdentifier: "claude-code"), ["claude"])
        XCTAssertEqual(hints.keywords(forRuleIdentifier: "codex-cli"), ["codex", "openai"])
        XCTAssertEqual(
            hints.negativeNamePatterns,
            ["*bak*", "*backup*", ".claude-*", ".codexbar", ".codexhost"]
        )
    }

    func test配置文件里的词表直接参与排序与负向名单() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        let path = try fixture.writeHintsFile(
            """
            {
              "schemaVersion": 1,
              "nameKeywords": { "codex-cli": ["codex"] },
              "negativeNamePatterns": ["*bak*"]
            }
            """
        )

        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: ""
        )
        try fixture.makeFile(
            ".claude-bak/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl"
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([
                RuleFixtures.codexJSON,
                RuleFixtures.claudeCodeJSON.replacingOccurrences(of: "\"~/.claude\"", with: "\"~/.claude-bak\""),
            ]),
            hints: try DiscoveryHints.load(from: URL(fileURLWithPath: path)),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(
            result.candidates.map { "\($0.ruleIdentifier ?? "")/\($0.confidence.rawValue)" },
            ["codex-cli/medium", "claude-code/low"],
            "配置文件里的关键词只管排序，负向名单把 -bak 压到低"
        )
    }

    func test词表文件读不出来时给出可读原因() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        let path = try fixture.writeHintsFile("{ \"schemaVersion\": 99 }")

        XCTAssertThrowsError(try DiscoveryHints.load(from: URL(fileURLWithPath: path))) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                description.contains("词表") && description.contains("schemaVersion"),
                "报错要指名是哪个文件、哪个字段：\(description)"
            )
        }
    }

    // MARK: - 切片 11：用内置规则集扫一遍实测形状的假主目录

    func test内置规则集在实测形状的假主目录上把五个工具根都发现出来() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // Claude Code：单横线编码路径 + 旧版子代理转录，**没有** file-history/、todos/、statsig/。
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/agent-1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl")
        try fixture.makeFile(".claude/skills/review/SKILL.md", contents: "技能")
        // Codex：明文与 .zst 并存 + 扁平 archived_sessions + fork 双 UUID。
        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: #"{"type":"session_meta","payload":{"cwd":"/Users/xiaowei/work"}}"# + "\n"
        )
        try fixture.makeFile(
            ".codex/archived_sessions/rollout-2026-10-02T09-08-28-"
                + "3e4f5a6b-7c8d-9e0f-1a2b-3c4d5e6f7a8b_4f5a6b7c-8d9e-0f1a-2b3c-4d5e6f7a8b9c.jsonl.zst",
            contents: ""
        )
        // Cursor：主转录 + 同级子代理转录。
        try fixture.makeFile(
            ".cursor/projects/-Users-xiaowei-amc-wt-12/agent-transcripts/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f/1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl"
        )
        // DeepSeek Harness：双横线编码路径 + .zstd。
        try fixture.makeFile(
            "Library/Application Support/deepseek-harness-desktop/harness-home"
                + "/sessions/--Users-xiaowei-work-amc-wt-12--/session-9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f"
                + "/session.jsonl.zstd",
            contents: ""
        )
        // OpenCode：非标准位置，规则只声明 `storage` 这个目录形态（PRD §5.3：只做发现）。
        try fixture.makeFile(".local/share/opencode/storage/session.db", contents: "")

        let result = ToolDiscoverer(
            rules: try admittedBundledRules(),
            hints: DiscoveryHints(
                nameKeywords: [
                    "claude-code": ["claude"],
                    "codex-cli": ["codex"],
                    "cursor": ["cursor"],
                    "deepseek-harness": ["deepseek"],
                    "opencode": ["opencode"],
                ],
                negativeNamePatterns: ["*bak*", ".claude-*", ".codexbar"]
            ),
            externalEvidence: ExternalEvidence(applicationNames: ["Claude"], commandNames: ["codex"]),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(
            Set(result.candidates.map { $0.ruleIdentifier ?? "" }),
            ["claude-code", "codex-cli", "cursor", "deepseek-harness", "opencode"],
            "五个实测形状的工具根都要被发现：\(result.candidates.map { ($0.displayPath, $0.ruleIdentifier ?? "") })"
        )

        func candidate(_ identifier: String) throws -> Candidate {
            try XCTUnwrap(result.candidates.first { $0.ruleIdentifier == identifier })
        }

        // Claude：有结构 + 文件头字段 + 同名 App → 高。
        let claude = try candidate("claude-code")
        XCTAssertEqual(claude.displayPath, "~/.claude")
        XCTAssertEqual(claude.confidence, .high)
        XCTAssertTrue(claude.signals.structuralFingerprints.contains("projects/<encodedPath>/<uuid>.jsonl"))
        XCTAssertTrue(claude.signals.structuralFingerprints.contains("projects/<encodedPath>/agent-<uuid>.jsonl"))

        // Codex：fork 文件名与扁平归档目录都命中。
        let codex = try candidate("codex-cli")
        XCTAssertEqual(codex.confidence, .high)
        XCTAssertTrue(
            codex.signals.structuralFingerprints.contains("archived_sessions/rollout-<ISO>-<uuid:parent>_<uuid:fork>.jsonl[.zst]"),
            "fork 会话的文件名含两个 UUID（User Story 26）：\(codex.signals.structuralFingerprints)"
        )

        // Cursor：第 5 层的主转录。
        let cursor = try candidate("cursor")
        XCTAssertEqual(cursor.confidence, .medium, "Cursor 规则没有声明文件头字段，也没有同名命令")
        XCTAssertTrue(
            cursor.signals.structuralFingerprints.contains(
                "projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl"
            )
        )

        // Harness：zstd 会话只按路径与扩展名识别，不解压。
        let harness = try candidate("deepseek-harness")
        XCTAssertEqual(
            harness.displayPath,
            "~/Library/Application Support/deepseek-harness-desktop/harness-home"
        )
        XCTAssertEqual(harness.confidence, .medium)

        // OpenCode：只有目录形态可依，规则不声明可归档形态，因此停在「中」。
        let openCode = try candidate("opencode")
        XCTAssertEqual(openCode.displayPath, "~/.local/share/opencode")
        XCTAssertEqual(openCode.confidence, .medium)

        // 一个候选都没落在夹具树外。
        XCTAssertTrue(result.candidates.allSatisfy { $0.toolRootPath.hasPrefix(fixture.homePath) })
    }

    // MARK: - 切片 10：扫描位置的筛选口径与外部佐证采集

    func test主目录扫描根只看隐藏目录() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 规则声明了 `~/notes`，但 PRD §4.2 的主目录扫描位置是「`~` 下的隐藏目录」。
        try fixture.makeFile("notes/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        let rule = RuleFixtures.claudeCodeJSON.replacingOccurrences(of: "\"~/.claude\"", with: "\"~/notes\"")

        let result = ToolDiscoverer(
            rules: try admittedRules([rule]),
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertTrue(
            result.candidates.isEmpty,
            "主目录下不隐藏的目录不在浅扫位置里：\(result.candidates.map(\.toolRootPath))"
        )
    }

    func test外部佐证从应用目录与命令搜索路径采集() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        let applications = try fixture.makeDirectory("Applications")
        try fixture.makeDirectory("Applications/Claude.app")
        try fixture.makeDirectory("Applications/Codex.app")
        let commands = try fixture.makeDirectory("bin")
        try fixture.writeFile("bin/claude", contents: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commands + "/claude")
        // 不可执行的文件不是命令。
        try fixture.writeFile("bin/codex", contents: "说明文档\n")

        let evidence = ExternalEvidenceCollector.detect(
            applicationDirectories: [applications],
            commandSearchPaths: [commands]
        )

        XCTAssertEqual(evidence.applicationNames, ["Claude", "Codex"])
        XCTAssertEqual(
            evidence.commandNames, ["claude"],
            "PATH 里不可执行的文件不算同名命令（实测 zstd 也不在 /usr/bin）"
        )
    }

    // MARK: - 切片 9：与确认存储对接、受保护判定按链接真实目标

    func test候选的工具根路径直接交给确认存储筛出还要问的候选() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: ""
        )

        let result = ToolDiscoverer(
            rules: try admittedRules([RuleFixtures.claudeCodeJSON, RuleFixtures.codexJSON]),
            homeDirectory: fixture.homePath
        ).discover()
        let codexRoot = fixture.homePath + "/.codex"
        let claudeRoot = fixture.homePath + "/.claude"

        let store = JSONConfirmationStore(applicationSupportRoot: fixture.home.url)
        _ = try store.decide(
            toolIdentifier: "claude-code",
            toolRootPath: claudeRoot,
            decision: .confirmed,
            signals: result.candidates.first { $0.toolRootPath == claudeRoot }?.signals ?? .none,
            decidedAt: Date()
        )

        XCTAssertEqual(
            store.pendingToolRootPaths(amongCandidates: result.candidateToolRootPaths),
            [codexRoot],
            "确认过的候选下次不该再问（PRD §4.1 第 4 步）"
        )
    }

    func test候选的受保护判定走内置清单并按链接的真实目标() throws {
        let realHome = try DiscoveryFixture(named: "real-home")
        defer { realHome.home.remove() }

        // 主目录本身经过一个符号链接：内置清单判定按真实目标走，因此照样认得出来。
        try writeTestFile(
            relativePath: ".claude-credentials-cache/projects/-Users-xiaowei-amc-wt-12/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: DiscoveryFixture.sampleTranscriptLine,
            in: realHome.home
        )
        let linkedHome = realHome.home.url.path + "-link"
        try FileManager.default.createSymbolicLink(atPath: linkedHome, withDestinationPath: realHome.homePath)

        let credentialRule = RuleFixtures.claudeCodeJSON.replacingOccurrences(
            of: "\"~/.claude\"",
            with: "\"~/.claude-credentials-cache\""
        )
        let result = ToolDiscoverer(
            rules: try admittedRules([credentialRule]),
            homeDirectory: linkedHome
        ).discover()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(
            candidate.protection?.ruleIdentifier,
            "credential/credentials",
            "凭证类名字的目录即便被规则声明为工具根，也必须带出受保护标记"
        )
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

/// 内置规则文件（issue #15）过一遍规则集准入（issue #11）。
///
/// 发现器因此可以在**真实出厂规则**上被断言：新增工具 = 新增一个规则文件（User Story 20）。
private func admittedBundledRules() throws -> [ToolRule] {
    let directory = try XCTUnwrap(BuiltInRuleResources.directory, "内置规则应当是 bundle 资源。")
    let load = RuleLoader.loadRules(inDirectory: directory)
    XCTAssertEqual(load.diagnostics.map(\.errorDescription), [], "内置规则必须全部读得进来。")
    let report = RuleSetAdmission.admit(rules: load.rules, homeDirectory: NSTemporaryDirectory())
    XCTAssertTrue(report.rejections.isEmpty, "内置规则不该被准入拒绝：\(report.rejections)")
    return report.usableRules
}

/// 规则夹具先过一遍规则集准入（issue #11）：发现器只消费**已验证可用**的规则集。
private func admittedRules(_ ruleJSON: [String]) throws -> [ToolRule] {
    let rules = try ruleJSON.map { try RuleLoader.loadRule(from: Data($0.utf8), source: "夹具") }
    let report = RuleSetAdmission.admit(rules: rules, homeDirectory: NSTemporaryDirectory())
    XCTAssertTrue(report.rejections.isEmpty, "夹具规则不该被准入拒绝：\(report.rejections)")
    return report.usableRules
}

/// 在任意临时夹具下写文件（树外的夹具也用得上）。
private func writeTestFile(relativePath: String, contents: String, in fixture: TemporaryDirectoryFixture) throws {
    let url = fixture.url.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
