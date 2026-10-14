import XCTest

import AIMacCleanCore
@testable import AIMacCleanRules

/// issue #15：内置规则文件（spec #7 User Stories 20–26）。
///
/// 断言落点只有两个 seam，都不经发现流程：
///
/// - **规则资源**：规则文件是 bundle 资源，用真实加载器 `RuleLoader.loadRules(inDirectory:)`
///   一次读全；新增工具 = 新增一个规则文件，不改代码（User Story 20）。
/// - **规则集准入**：读进来的全部规则过 `RuleSetAdmission.admit`，零拒绝（User Story 29），
///   再用准入结果的类别查询断言实测形状（PRD §5.4 / §14.5）。
///
/// 所有目录树都建在临时目录里，真实 AI 工具数据目录绝不参与（PRD §13 第 3 条、issue #14 护栏）。
final class BundledToolRuleTests: XCTestCase {

    private var fixture: TemporaryDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try TemporaryDirectoryFixture(named: "bundled-rules")
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    // MARK: - 规则资源

    /// 内置规则文件的目录（bundle 资源，由 SwiftPM 的 `resources` 打进包）。
    private func bundledRuleDirectory() throws -> URL {
        let directory = try XCTUnwrap(
            BuiltInRuleResources.directory,
            "内置规则应当以 bundle 资源的形式存在，而不是写死在代码里（User Story 20）。"
        )
        return directory
    }

    /// 用真实加载器读全部内置规则。
    private func loadBundledRules() throws -> (rules: [ToolRule], report: RuleAdmissionReport) {
        let directory = try bundledRuleDirectory()
        let load = RuleLoader.loadRules(inDirectory: directory)
        XCTAssertEqual(load.diagnostics.map(\.errorDescription), [],
                       "内置规则文件必须全部读得进来。")
        let home = try makeHome()
        let report = RuleSetAdmission.admit(rules: load.rules, homeDirectory: home)
        return (load.rules, report)
    }

    /// 临时主目录；规则里的 `~/` 都相对它展开。
    private func makeHome(_ name: String = "home") throws -> String {
        try fixture.makeDirectory(name).resolvingSymlinksInPath().path
    }

    // MARK: Slice 1：规则文件是 bundle 资源，一次读全

    func test内置规则目录是bundle资源目录() throws {
        let directory = try bundledRuleDirectory()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      "规则文件应当随包分发：\(directory.path)")
        XCTAssertTrue(isDirectory.boolValue)

        // 规则文件落在本模块的资源 bundle 里，而不是源码目录或二进制里的字符串。
        XCTAssertTrue(directory.path.contains(".bundle"),
                      "规则文件应当随 bundle 资源分发：\(directory.path)")
    }

    func test内置规则覆盖五个工具且全部读得进来() throws {
        let (rules, _) = try loadBundledRules()

        XCTAssertEqual(rules.map(\.id),
                       ["claude-code", "codex-cli", "cursor", "deepseek-harness", "opencode"])
        XCTAssertEqual(rules.map(\.displayName),
                       ["Claude Code", "Codex CLI", "Cursor", "DeepSeek Harness", "OpenCode"])
        XCTAssertEqual(rules.map(\.schemaVersion), [Int](repeating: ToolRule.currentSchemaVersion, count: 5))
    }

    // MARK: Slice 2：全部内置规则通过准入

    func test全部内置规则通过准入且零拒绝() throws {
        let (rules, report) = try loadBundledRules()

        XCTAssertEqual(report.rejections.map(\.description), [],
                       "内置规则本身触发单调性拒绝就是 bug（issue #15 验收）。")
        XCTAssertTrue(report.isFullyAdmitted)
        XCTAssertEqual(report.usableRules.map(\.id), rules.map(\.id))
    }

    func test内置规则准入零警告() throws {
        let (_, report) = try loadBundledRules()

        // 警告 = 「声明的类别与内置受保护清单不一致」。内置规则应当直接与内置保护对齐，
        // 而不是标一个更弱的类别让界面去解释「它其实仍受保护」。
        XCTAssertEqual(report.warnings.map(\.description), [])
    }

    func test受保护声明与内置保护清单一致() throws {
        let home = try makeHome()
        let (_, report) = try loadBundledRules()

        // 每条声明都配一条实测里真实存在的路径（照抄 PRD §5.4）。
        let samples: [(rule: String, root: String, relativePaths: [String])] = [
            ("claude-code", ".claude", ["settings.json", "mcp.json", "history.jsonl",
                                       "skills/foo/SKILL.md", "commands/bar.md",
                                       "agents/baz.md", "plugins/qux/plugin.json",
                                       "shell-snapshots/snapshot-zsh-1700000000000-a1b2c3.sh"]),
            ("codex-cli", ".codex", ["config.toml", "config.toml.bak", "auth.json",
                                     "prompts/a.md", "state.sqlite", "state.sqlite-wal"]),
            ("cursor", ".cursor", ["extensions/ms-vscode.cpptools", "plugins/p",
                                   "worktrees/w", "skills-x/s", "mcp.json", "hooks.json"]),
            ("deepseek-harness",
             "Library/Application Support/deepseek-harness-desktop/harness-home",
             ["settings.yaml", ".credentials.yaml", "storages/s", "profiles/p"]),
        ]

        for sample in samples {
            let toolRoot = (fixture.url.appendingPathComponent(sample.root, isDirectory: true))
                .resolvingSymlinksInPath().path

            for relativePath in sample.relativePaths {
                XCTAssertEqual(report.category(forRelativePath: relativePath, ruleID: sample.rule),
                               .protected,
                               "规则 \(sample.rule) 应把 \(relativePath) 判为受保护。")
                XCTAssertTrue(
                    BuiltInProtectedPaths.isProtected(toolRoot + "/" + relativePath,
                                                      underToolRoot: toolRoot,
                                                      homeDirectory: home),
                    "内置保护清单应覆盖 \(sample.root)/\(relativePath)。"
                )
            }
        }
    }

    // MARK: Slice 3：Claude Code 的新旧两种结构（User Story 22 / 23）

    /// 在临时主目录下建一个工具根，并放入若干文件（只建文件，不写内容）。
    private func makeToolRoot(_ relativePath: String, files: [String]) throws -> URL {
        let root = try fixture.makeDirectory(relativePath)
        for file in files {
            try ProtectedPathTestSupport.createFile(named: file, in: root)
        }
        return root
    }

    /// 工具根下全部文件，相对工具根、以 `/` 分隔。
    private func relativeFiles(under root: URL) throws -> [String] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let path = url.resolvingSymlinksInPath().path
            paths.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
        }
        return paths.sorted()
    }

    /// 一条规则声明的模式是否覆盖某条相对路径。
    private func matches(_ patterns: [PathPattern], _ relativePath: String) -> Bool {
        patterns.contains { PatternMatching.matches($0, relativePath: relativePath) }
    }

    func testClaude新版结构只有转录时被识别为可归档会话() throws {
        // PRD §14.5：新版 `~/.claude` 中 `file-history/`、`todos/`、`statsig/` 均不存在，
        // 文件历史以 `file-history-snapshot` 内联进转录。
        let sessionID = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        let root = try makeToolRoot(".claude", files: [
            "projects/-Users-xiaowei-demo/\(sessionID).jsonl",
        ])
        let (_, report) = try loadBundledRules()
        let rule = try XCTUnwrap(report.usableRule(id: "claude-code"))

        XCTAssertEqual(try relativeFiles(under: root),
                       ["projects/-Users-xiaowei-demo/\(sessionID).jsonl"])
        XCTAssertTrue(matches(rule.structuralFingerprint?.sessionFilePatterns ?? [],
                              "projects/-Users-xiaowei-demo/\(sessionID).jsonl"))
        XCTAssertEqual(report.category(forRelativePath: "projects/-Users-xiaowei-demo/\(sessionID).jsonl",
                                       ruleID: "claude-code"),
                       .archivableSession)
    }

    func testClaude旧版结构的子代理转录与关联数据也被识别() throws {
        // 旧结构由 `~/.claudebak` 证实：存在 `agent-*.jsonl`、`file-history/<会话UUID>/<hash>@vN`、
        // `todos/<会话UUID>-agent-<会话UUID>.json`。
        let sessionID = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        let agentID = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
        let root = try makeToolRoot(".claude", files: [
            "projects/-Users-xiaowei-demo/\(sessionID).jsonl",
            "projects/-Users-xiaowei-demo/agent-\(agentID).jsonl",
            "file-history/\(sessionID)/9f2c1b3a@v1",
            "todos/\(sessionID)-agent-\(agentID).json",
        ])
        let (_, report) = try loadBundledRules()
        let rule = try XCTUnwrap(report.usableRule(id: "claude-code"))
        let transcripts = try XCTUnwrap(rule.structuralFingerprint?.sessionFilePatterns)

        let expected = [
            "projects/-Users-xiaowei-demo/\(sessionID).jsonl",
            "projects/-Users-xiaowei-demo/agent-\(agentID).jsonl",
        ]
        XCTAssertEqual(try relativeFiles(under: root).filter { $0.hasPrefix("projects/") }, expected)

        for path in expected {
            XCTAssertTrue(matches(transcripts, path), "会话文件模式应覆盖 \(path)")
            XCTAssertEqual(report.category(forRelativePath: path, ruleID: "claude-code"),
                           .archivableSession)
        }

        // 关联数据按会话级联，规则里以 `<uuid>` 占位表达（不是具名占位）。
        let cascaded = rule.cascade
        XCTAssertEqual(Set(cascaded.map(\.kind)),
                       [.siblingTranscripts, .sessionKeyedDirectory, .sessionKeyedFile])

        // `siblingTranscripts` 的基准是主转录**所在目录**（docs/rule-format.md），
        // 其余两种基准是工具根目录。
        let sibling = try XCTUnwrap(cascaded.first { $0.kind == .siblingTranscripts }).pattern
        XCTAssertTrue(matches([sibling], "agent-\(agentID).jsonl"))
        let keyedDirectory = try XCTUnwrap(cascaded.first { $0.kind == .sessionKeyedDirectory }).pattern
        XCTAssertTrue(matches([keyedDirectory], "file-history/\(sessionID)"))
        let keyedFile = try XCTUnwrap(cascaded.first { $0.kind == .sessionKeyedFile }).pattern
        XCTAssertTrue(matches([keyedFile], "todos/\(sessionID)-agent-\(agentID).json"))
        XCTAssertEqual(report.category(forRelativePath: "file-history/\(sessionID)", ruleID: "claude-code"),
                       .archivableSession)
        XCTAssertEqual(report.category(forRelativePath: "todos/\(sessionID)-agent-\(agentID).json",
                                       ruleID: "claude-code"),
                       .archivableSession)
    }

    func testClaude旧版关联数据缺失时静默跳过不报错() throws {
        // User Story 22/23：规则声明的路径在磁盘上不存在不是错误。
        // 这里连工具根本身都不建——准入完全走路径形状，不 stat 磁盘。
        let emptyHome = try makeHome("empty-home")
        let (rules, _) = try loadBundledRules()
        let claude = try XCTUnwrap(rules.first { $0.id == "claude-code" })

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: emptyHome + "/.claude",
            isDirectory: nil
        ), "这棵树刻意不创建工具根，用来证明缺失路径被静默跳过。")
        XCTAssertNil(RuleSetAdmission.rejection(forRule: claude, homeDirectory: emptyHome))
        XCTAssertEqual(RuleSetAdmission.warnings(forRule: claude, homeDirectory: emptyHome), [])

        // 新版（无关联数据目录）与旧版（有）的声明集合一致，不需要两套规则。
        let declared = claude.cascade.map(\.pattern.canonicalString)
        XCTAssertEqual(declared, [
            "agent-<uuid>.jsonl",
            "file-history/<uuid>",
            "todos/<uuid>-agent-<uuid>.json",
        ])
    }

    // MARK: Slice 4：Codex 的三种会话形态（User Story 24 / 25 / 26）

    func testCodex的三种会话形态都被表达() throws {
        // PRD §14.5 实测：771 个 `.zst`、21 个明文 `.jsonl`；
        // `archived_sessions/` 扁平存放、没有年月日嵌套；fork 文件名含两个 UUID。
        let root = try makeToolRoot(".codex", files: [
            "sessions/2025/10/01/rollout-2025-10-01t09-08-28-3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d.jsonl.zst",
            "sessions/2025/10/02/rollout-2025-10-02t11-22-33-7c8d9e0f-1a2b-4c3d-8e5f-6a7b8c9d0e1f.jsonl",
            "archived_sessions/rollout-2025-09-30t08-00-00-9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d.jsonl.zst",
            "sessions/2025/10/03/rollout-2025-10-03t12-00-00-3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
                + "_9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d.jsonl.zst",
        ])
        let (_, report) = try loadBundledRules()
        let rule = try XCTUnwrap(report.usableRule(id: "codex-cli"))
        let transcripts = try XCTUnwrap(rule.structuralFingerprint?.sessionFilePatterns)

        for path in try relativeFiles(under: root) {
            XCTAssertTrue(matches(transcripts, path), "Codex 会话文件模式应覆盖 \(path)")
            XCTAssertEqual(report.category(forRelativePath: path, ruleID: "codex-cli"),
                           .archivableSession,
                           "\(path) 应判为可归档会话。")
        }

        // 年月日嵌套形态与扁平形态是两种不同的目录形状，不能只声明其中一种。
        XCTAssertEqual(rule.structuralFingerprint?.sessionDirectoryShapes.map(\.canonicalString),
                       ["sessions/<date:year>", "archived_sessions"])
    }

    func testCodex声明自带压缩且文件名不是稳定会话标识() throws {
        let (_, report) = try loadBundledRules()
        let rule = try XCTUnwrap(report.usableRule(id: "codex-cli"))

        // `.zst` 是 Codex 自己压的：归档走 store，不再重压缩（ADR-0001）。
        XCTAssertTrue(rule.selfCompressed)

        // fork 会话文件名含两个 UUID，一个逻辑会话跨多个文件（User Story 26）。
        let naming = try XCTUnwrap(rule.sessionFileNaming)
        XCTAssertFalse(naming.stableSessionIdentifier)
        XCTAssertEqual(naming.sessionIDSource, .fileName)
    }

    // MARK: Slice 5：项目路径编码方案（PRD §5.3 / User Story 21）

    func test编码方案逐工具声明且互不混用() throws {
        let (rules, _) = try loadBundledRules()

        var schemes: [String: ProjectPathEncodingScheme] = [:]
        for rule in rules {
            // OpenCode 的项目路径在 `session.directory` **数据库列**里，PRD §5.3 写明
            // 第一期不做；格式里没有「数据库列」这一档，声明成 inFileField 会是一次
            // 凭空捏造（引擎会以为该去读文件头）。因此它不声明编码方案，
            // 取规则格式的保守默认值（docs/rule-format.md）。
            guard rule.id != "opencode" else {
                XCTAssertNil(rule.projectPathEncoding)
                continue
            }

            let encoding = try XCTUnwrap(rule.projectPathEncoding,
                                         "规则 \(rule.id) 应当声明项目路径编码方案（PRD §5.3）。")
            schemes[rule.id] = encoding.scheme

            if encoding.scheme == .inFileField {
                XCTAssertEqual(encoding.fieldPath, "session_meta.payload.cwd",
                               "Codex 的项目路径在文件内字段里（PRD §5.4）。")
            } else {
                XCTAssertNil(encoding.fieldPath)
            }
        }

        // PRD §5.3 的 4 套互不兼容方案里，本阶段覆盖前三种。
        XCTAssertEqual(schemes, [
            "claude-code": .singleDash,
            "codex-cli": .inFileField,
            "cursor": .singleDash,
            "deepseek-harness": .doubleDash,
        ])
    }

    func testClaude编码方案声明了不可无损逆解这一事实() throws {
        let (rules, _) = try loadBundledRules()
        let claude = try XCTUnwrap(rules.first { $0.id == "claude-code" })
        let note = try XCTUnwrap(claude.projectPathEncoding?.note)

        // PRD §5.3：`/Users/x/.claude` → `-Users-xiaowei--claude`，解码有歧义。
        // 规则必须把这件事写下来，否则后续实现会去写一个必然出错的逆向解码。
        XCTAssertTrue(note.contains("不可无损逆解"),
                      "Claude Code 的编码方案备注应当说明它不可无损逆解：\(note)")
    }

    // MARK: Slice 6：Cursor / DeepSeek Harness 格式可表达，OpenCode 只做发现

    func testCursor的主转录与子代理转录跨文件级联() throws {
        let sessionID = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        let turnID = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
        let root = try makeToolRoot(".cursor", files: [
            "projects/-Users-xiaowei-demo/agent-transcripts/\(sessionID)/\(turnID).jsonl",
            "projects/-Users-xiaowei-demo/agent-transcripts/\(sessionID)/subagents/\(turnID).jsonl",
        ])
        let (_, report) = try loadBundledRules()
        let rule = try XCTUnwrap(report.usableRule(id: "cursor"))
        let transcripts = try XCTUnwrap(rule.structuralFingerprint?.sessionFilePatterns)

        for path in try relativeFiles(under: root) {
            XCTAssertTrue(matches(transcripts, path), "Cursor 会话文件模式应覆盖 \(path)")
            XCTAssertEqual(report.category(forRelativePath: path, ruleID: "cursor"),
                           .archivableSession)
        }

        // 一个会话跨主转录 + 子代理多个文件，必须声明同级级联。
        let sibling = try XCTUnwrap(rule.cascade.first { $0.kind == .siblingTranscripts })
        XCTAssertTrue(matches([sibling.pattern], "subagents/\(turnID).jsonl"))

        // `~/Library/Application Support/Cursor` 实测 14G，全是 Electron 内部存储：
        // 声明为 displayOnly，只展示占用，不参与准入与分类。
        let displayOnly = rule.roots.filter { $0.role == .displayOnly }
        XCTAssertEqual(displayOnly.map(\.path), ["~/Library/Application Support/Cursor"])
    }

    func testHarness一个会话一个文件且会话标识在父目录名() throws {
        let sessionID = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        let root = try makeToolRoot(
            "Library/Application Support/deepseek-harness-desktop/harness-home",
            files: ["sessions/--Users-xiaowei-demo--/session-\(sessionID)/session.jsonl.zstd"]
        )
        let (_, report) = try loadBundledRules()
        let rule = try XCTUnwrap(report.usableRule(id: "deepseek-harness"))
        let transcripts = try XCTUnwrap(rule.structuralFingerprint?.sessionFilePatterns)

        let path = "sessions/--Users-xiaowei-demo--/session-\(sessionID)/session.jsonl.zstd"
        XCTAssertEqual(try relativeFiles(under: root), [path])
        XCTAssertTrue(matches(transcripts, path))
        XCTAssertEqual(report.category(forRelativePath: path, ruleID: "deepseek-harness"),
                       .archivableSession)

        let naming = try XCTUnwrap(rule.sessionFileNaming)
        XCTAssertEqual(naming.sessionIDSource, .parentDirectoryName)
        XCTAssertTrue(naming.stableSessionIdentifier)
        XCTAssertTrue(rule.selfCompressed, "Harness 的会话文件本身就是 .zstd。")
    }

    func testOpenCode只做发现不声明任何可归档形态() throws {
        let (rules, _) = try loadBundledRules()
        let openCode = try XCTUnwrap(rules.first { $0.id == "opencode" })

        // 非标准位置：藏在 `~/.local/share/opencode`，不能因为路径不常规就漏掉（User Story 7）。
        XCTAssertEqual(openCode.roots.map(\.path), ["~/.local/share/opencode"])
        XCTAssertEqual(openCode.roots.map(\.role), [.toolRoot])

        // SQLite 私有形态：PRD §5.1 归「不确定」，本阶段仅展示占用，不声明可归档会话。
        XCTAssertEqual(Set(openCode.classification.map(\.category)), [.uncertain])
        XCTAssertEqual(openCode.cascade, [])
        XCTAssertFalse(openCode.selfCompressed)
    }
}
