import XCTest

@testable import AIMacCleanRules
import AIMacCleanCore

/// 内置受保护清单（issue #9，PRD §5.4 / §8.1 / §14.5）。
///
/// Seam：Rules 层的公开查询 API（`BuiltInProtectedPaths`）。
/// 断言只落在「某路径是否受保护 / 命中哪条内置规则」这一外部可观察行为上，
/// 不断言清单内部的数据结构形状。
///
/// 所有输入都写在临时目录（PRD §13 第 3 条），真实 `~/.claude`、`~/.codex`、
/// `~/.cursor` 与 DeepSeek Harness 的真实目录绝不参与。
final class BuiltInProtectedPathsTests: XCTestCase {

    /// 建出一棵与真实主目录同构的临时目录树。
    private func makeHome(_ name: String) throws -> (ProtectedPathTestSupport.FakeHome, TemporaryDirectoryFixture) {
        let fixture = try TemporaryDirectoryFixture(named: name)
        return (try ProtectedPathTestSupport.FakeHome.make(named: name, fixture: fixture), fixture)
    }

    private func isProtected(
        _ path: URL,
        under root: URL,
        home: ProtectedPathTestSupport.FakeHome
    ) -> Bool {
        BuiltInProtectedPaths.isProtected(
            path.resolvingSymlinksInPath().path,
            underToolRoot: root.resolvingSymlinksInPath().path,
            homeDirectory: home.homeDirectory
        )
    }

    // MARK: - slice 1：工具根 + 相对路径

    func test工具根下的settingsJSON被判为受保护() throws {
        let (home, fixture) = try makeHome("claude-settings")
        defer { fixture.remove() }

        let settings = try ProtectedPathTestSupport.createFile(named: "settings.json", in: home.claudeRoot)

        XCTAssertTrue(isProtected(settings, under: home.claudeRoot, home: home))
    }

    // MARK: - slice 2：四个工具的受保护清单（PRD §5.4）

    func testClaudeCode的配置技能命令与插件目录受保护() throws {
        let (home, fixture) = try makeHome("claude-protected")
        defer { fixture.remove() }

        let protectedPaths = [
            "settings.json",
            "settings.local.json",
            "mcp.json",
            "history.jsonl",
            "skills/我的技能/SKILL.md",
            "commands/提交.md",
            "agents/reviewer.md",
            "plugins/marketplace/plugin.json",
            "shell-snapshots/snapshot-zsh-1700000000000-ab12cd.sh",
        ]

        for relative in protectedPaths {
            let url = home.claudeRoot.appendingPathComponent(relative)
            try ProtectedPathTestSupport.createFile(named: url.lastPathComponent, in: url.deletingLastPathComponent())
            XCTAssertTrue(
                isProtected(url, under: home.claudeRoot, home: home),
                "Claude Code 的受保护路径应被判为受保护：\(relative)"
            )
        }
    }

    func testCodex的配置凭证提示词与SQLite受保护() throws {
        let (home, fixture) = try makeHome("codex-protected")
        defer { fixture.remove() }

        let protectedPaths = [
            "config.toml",
            "config.toml.bak",
            "auth.json",
            "prompts/常用.md",
            "state.sqlite",
            "nested/dir/other.sqlite",
        ]

        for relative in protectedPaths {
            let url = home.codexRoot.appendingPathComponent(relative)
            try ProtectedPathTestSupport.createFile(named: url.lastPathComponent, in: url.deletingLastPathComponent())
            XCTAssertTrue(
                isProtected(url, under: home.codexRoot, home: home),
                "Codex 的受保护路径应被判为受保护：\(relative)"
            )
        }
    }

    func testCursor的扩展插件工作树技能与MCP配置受保护() throws {
        let (home, fixture) = try makeHome("cursor-protected")
        defer { fixture.remove() }

        let protectedPaths = [
            "extensions/ms-python.python",
            "plugins/my-plugin/index.js",
            "worktrees/feature-x/src",
            "skills/shared/SKILL.md",
            "skills-personal/SKILL.md",
            "mcp.json",
            "hooks.json",
        ]

        for relative in protectedPaths {
            let url = home.cursorRoot.appendingPathComponent(relative)
            try ProtectedPathTestSupport.createFile(named: url.lastPathComponent, in: url.deletingLastPathComponent())
            XCTAssertTrue(
                isProtected(url, under: home.cursorRoot, home: home),
                "Cursor 的受保护路径应被判为受保护：\(relative)"
            )
        }
    }

    func testDeepSeekHarness的配置凭证存储与档案目录受保护() throws {
        let (home, fixture) = try makeHome("harness-protected")
        defer { fixture.remove() }

        let protectedPaths = [
            "settings.yaml",
            ".credentials.yaml",
            "storages/cache.json",
            "profiles/default/profile.json",
        ]

        for relative in protectedPaths {
            let url = home.harnessRoot.appendingPathComponent(relative)
            try ProtectedPathTestSupport.createFile(named: url.lastPathComponent, in: url.deletingLastPathComponent())
            XCTAssertTrue(
                isProtected(url, under: home.harnessRoot, home: home),
                "DeepSeek Harness 的受保护路径应被判为受保护：\(relative)"
            )
        }
    }

    func test位于工具根之外的全局状态文件受保护() throws {
        let (home, fixture) = try makeHome("home-scope")
        defer { fixture.remove() }

        for name in [".claude.json", ".codex-global-state.json"] {
            let url = try ProtectedPathTestSupport.createFile(named: name, in: home.root)
            XCTAssertTrue(
                isProtected(url, under: home.claudeRoot, home: home),
                "工具根之外的全局状态文件应被判为受保护：\(name)"
            )
        }

        // `~/.agents/skills` 是 `~/.codex/skills` 与 `~/.opencode/skills` 的真实目标（PRD §14.5）。
        let skill = try ProtectedPathTestSupport.createFile(
            named: "SKILL.md",
            in: home.toolRoot(".agents/skills/我的技能")
        )
        XCTAssertTrue(isProtected(skill, under: home.claudeRoot, home: home))
    }

    func test未知位置的凭证类文件名被保守判为受保护() throws {
        let (home, fixture) = try makeHome("unknown-tool")
        defer { fixture.remove() }

        let unknownRoot = try ProtectedPathTestSupport.createDirectory(named: "some-new-ai-tool", in: home.root)

        for name in [
            "auth.json",
            "auth-token.json",
            "oauth_creds.json",
            "app_credentials.json",
            "config.json",
            "settings.toml",
            "history.jsonl",
            "run.log",
            "my_token.json",
            "client-secret.json",
        ] {
            let url = try ProtectedPathTestSupport.createFile(named: name, in: unknownRoot)
            XCTAssertTrue(
                isProtected(url, under: unknownRoot, home: home),
                "未知工具的凭证类文件名应被判为受保护：\(name)"
            )
        }
    }

    func test命中结果指明属于哪个工具的受保护清单() throws {
        let (home, fixture) = try makeHome("which-tool")
        defer { fixture.remove() }

        let auth = try ProtectedPathTestSupport.createFile(named: "auth.json", in: home.codexRoot)
        let settings = try ProtectedPathTestSupport.createFile(named: "settings.json", in: home.claudeRoot)
        let hooks = try ProtectedPathTestSupport.createFile(named: "hooks.json", in: home.cursorRoot)

        let identify: (URL, URL) -> String? = { path, root in
            BuiltInProtectedPaths.protectingTool(
                forPath: path.resolvingSymlinksInPath().path,
                underToolRoot: root.resolvingSymlinksInPath().path,
                homeDirectory: home.homeDirectory
            )
        }

        XCTAssertEqual(identify(auth, home.codexRoot), "codex-cli")
        XCTAssertEqual(identify(settings, home.claudeRoot), "claude-code")
        XCTAssertEqual(identify(hooks, home.cursorRoot), "cursor")
    }

    func test工具根按目录名识别为对应工具() throws {
        XCTAssertEqual(BuiltInProtectedPaths.scope(ofToolRoot: "/Users/example/.claude"), .toolRoot("claude-code"))
        XCTAssertEqual(BuiltInProtectedPaths.scope(ofToolRoot: "/Users/example/.codex"), .toolRoot("codex-cli"))
        XCTAssertEqual(BuiltInProtectedPaths.scope(ofToolRoot: "/Users/example/.cursor"), .toolRoot("cursor"))
        XCTAssertEqual(
            BuiltInProtectedPaths.scope(ofToolRoot: "/Users/example/Library/Application Support/deepseek-harness-desktop/harness-home"),
            .toolRoot("deepseek-harness")
        )
        XCTAssertEqual(BuiltInProtectedPaths.scope(ofToolRoot: "/Users/example/some-new-tool"), .unknownLocation)
    }

    // MARK: - slice 3：会话文件不被误判为受保护

    func test各工具的会话与关联数据不被误判为受保护() throws {
        let (home, fixture) = try makeHome("session-files")
        defer { fixture.remove() }

        let archivable: [(root: URL, relative: String)] = [
            // Claude Code：`projects/<编码路径>/<uuid>.jsonl` 与子代理转录（PRD §5.4）。
            (home.claudeRoot, "projects/-Users-x--my-project/3f1b0a2c-uuid.jsonl"),
            (home.claudeRoot, "projects/-Users-x--my-project/agent-9d8f0a11-uuid.jsonl"),
            // 旧版本结构里的关联数据随会话级联，不属于受保护。
            (home.claudeRoot, "todos/3f1b0a2c-agent-3f1b0a2c.json"),
            (home.claudeRoot, "file-history/3f1b0a2c/9ab@v1"),
            (home.claudeRoot, ".last-cleanup"),
            // Codex：`sessions/YYYY/MM/DD/rollout-*.jsonl[.zst]` 与扁平 `archived_sessions/`。
            (home.codexRoot, "sessions/2026/10/14/rollout-2026-10-14T10-20-30-uuid.jsonl"),
            (home.codexRoot, "sessions/2026/10/14/rollout-2026-10-14T10-20-30-uuid.jsonl.zst"),
            (home.codexRoot, "sessions/2026/10/14/rollout-2026-10-14T10-20-30-uuidA_uuidB.jsonl.zst"),
            (home.codexRoot, "archived_sessions/rollout-2026-10-01T09-00-00-uuid.jsonl.zst"),
            // Cursor：一个会话跨主转录 + 子代理多个文件。
            (home.cursorRoot, "projects/-Users-x--my-project/agent-transcripts/aaa/bbb.jsonl"),
            (home.cursorRoot, "projects/-Users-x--my-project/subagents/ccc.jsonl"),
            // DeepSeek Harness：一个会话一个 `session.jsonl.zstd`。
            (home.harnessRoot, "sessions/--Users-x--my-project--/session-uuid/session.jsonl.zstd"),
        ]

        for entry in archivable {
            let url = entry.root.appendingPathComponent(entry.relative)
            try ProtectedPathTestSupport.createFile(named: url.lastPathComponent, in: url.deletingLastPathComponent())
            XCTAssertFalse(
                isProtected(url, under: entry.root, home: home),
                "会话数据不应被判为受保护：\(entry.relative)"
            )
        }
    }

    func test另一个工具根下的同名文件不因名字被误判() throws {
        let (home, fixture) = try makeHome("cross-tool")
        defer { fixture.remove() }

        // `config.toml` 是 Codex 的配置，在 Claude Code 根下不因此受保护。
        let configUnderClaude = try ProtectedPathTestSupport.createFile(named: "config.toml", in: home.claudeRoot)
        XCTAssertFalse(isProtected(configUnderClaude, under: home.claudeRoot, home: home))

        // `settings.json` 是 Claude Code 的配置，在 Codex 根下不因此受保护。
        let settingsUnderCodex = try ProtectedPathTestSupport.createFile(named: "settings.json", in: home.codexRoot)
        XCTAssertFalse(isProtected(settingsUnderCodex, under: home.codexRoot, home: home))

        // `mcp.json` 是 Cursor 的设置，在 Codex 根下不因此受保护。
        let mcpUnderCodex = try ProtectedPathTestSupport.createFile(named: "mcp.json", in: home.codexRoot)
        XCTAssertFalse(isProtected(mcpUnderCodex, under: home.codexRoot, home: home))
    }

    func test工具根目录本身不算受保护路径() throws {
        let (home, fixture) = try makeHome("root-itself")
        defer { fixture.remove() }

        XCTAssertFalse(isProtected(home.claudeRoot, under: home.claudeRoot, home: home))
    }

    func test路径不存在时判定不报错且不命中() throws {
        let (home, fixture) = try makeHome("missing-path")
        defer { fixture.remove() }

        let missing = home.claudeRoot.appendingPathComponent("projects/never-created/uuid.jsonl")

        XCTAssertFalse(isProtected(missing, under: home.claudeRoot, home: home))
    }

    // MARK: - slice 4：符号链接按真实目标判定（PRD §14.5，验收 A3 / A8）

    func test指向外部技能目录的符号链接受保护() throws {
        let (home, fixture) = try makeHome("skills-symlink")
        defer { fixture.remove() }

        // `~/.codex/skills` → `~/.agents/skills`（PRD §14.5 实测形态）。
        let sharedSkills = try ProtectedPathTestSupport.createDirectory(named: ".agents/skills", in: home.root)
        let sharedFile = try ProtectedPathTestSupport.createFile(named: "SKILL.md", in: sharedSkills.appendingPathComponent("我的技能"))
        try ProtectedPathTestSupport.createSymbolicLink(named: "skills", in: home.codexRoot, pointingTo: sharedSkills)

        // 经链接访问的技能文件受保护。
        let throughLink = home.codexRoot.appendingPathComponent("skills/我的技能/SKILL.md")
        XCTAssertTrue(isProtected(throughLink, under: home.codexRoot, home: home))

        // 链接的真实目标同样受保护（不只是链接本身）。
        XCTAssertTrue(isProtected(sharedFile, under: home.codexRoot, home: home))
    }

    func test真实目标只能靠解析符号链接才判得出受保护() throws {
        let (home, fixture) = try makeHome("real-target-only")
        defer { fixture.remove() }

        // `plugins` 是 Cursor 的受保护目录名，而它的真实目标在工具根之外、
        // 也不匹配任何主目录条目——只有解析符号链接才可能判定为受保护。
        let realDirectory = try ProtectedPathTestSupport.createDirectory(named: "cursor-plugin-marketplace", in: home.root)
        let realFile = try ProtectedPathTestSupport.createFile(named: "plugin.json", in: realDirectory)
        try ProtectedPathTestSupport.createSymbolicLink(named: "plugins", in: home.cursorRoot, pointingTo: realDirectory)

        let match = BuiltInProtectedPaths.protection(
            forPath: realFile.resolvingSymlinksInPath().path,
            underToolRoot: home.cursorRoot.resolvingSymlinksInPath().path,
            homeDirectory: home.homeDirectory
        )

        XCTAssertEqual(match?.matchedVia, .symlinkRealTarget)
        XCTAssertEqual(match?.ruleIdentifier, "cursor/plugins")
    }

    func test真实目标受保护与询问的是哪个工具根无关() throws {
        let (home, fixture) = try makeHome("real-target-floor")
        defer { fixture.remove() }

        let sharedSkills = try ProtectedPathTestSupport.createDirectory(named: ".agents/skills", in: home.root)
        let sharedFile = try ProtectedPathTestSupport.createFile(named: "SKILL.md", in: sharedSkills)
        try ProtectedPathTestSupport.createSymbolicLink(named: "skills", in: home.codexRoot, pointingTo: sharedSkills)

        // 即使从另一个工具根发起询问，同一个真实目标仍然受保护：保护只增不减。
        XCTAssertTrue(isProtected(sharedFile, under: home.cursorRoot, home: home))
    }

    func test指向非受保护外部目录的符号链接不会把目标判为受保护() throws {
        let (home, fixture) = try makeHome("external-link")
        defer { fixture.remove() }

        // 「归档包链接」这类指向外部数据的链接，其真实目标不属于内置受保护目录。
        let external = try ProtectedPathTestSupport.createDirectory(named: "外部数据", in: fixture.url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: external) }

        let externalFile = try ProtectedPathTestSupport.createFile(named: "rollout-uuid.jsonl", in: external)
        try ProtectedPathTestSupport.createSymbolicLink(named: "archive-links", in: home.codexRoot, pointingTo: external)

        XCTAssertFalse(isProtected(externalFile, under: home.codexRoot, home: home))
    }

    // MARK: - slice 5：清单不可变、保护只增不减（issue #9 硬性约束）

    func test调用方拿到清单副本也改不动内置清单() {
        var localCopy = BuiltInProtectedPaths.rules
        let originalCount = localCopy.count

        localCopy.removeAll()
        localCopy.append(
            BuiltInProtectedRule(
                identifier: "fake/rule",
                scope: .credentialFileName,
                pattern: "*",
                kind: .file
            )
        )

        // 内置清单是编译期常量：外部改动副本不会影响它，也不会影响判定结果。
        XCTAssertEqual(BuiltInProtectedPaths.rules.count, originalCount)
        XCTAssertFalse(BuiltInProtectedPaths.rules.isEmpty)
    }

    func test重复判定结果稳定且与调用顺序无关() throws {
        let (home, fixture) = try makeHome("stability")
        defer { fixture.remove() }

        let protectedFile = try ProtectedPathTestSupport.createFile(named: "auth.json", in: home.codexRoot)
        let archivableFile = try ProtectedPathTestSupport.createFile(
            named: "rollout-uuid.jsonl",
            in: home.codexRoot.appendingPathComponent("sessions/2026/10/14")
        )

        let protectedPath = protectedFile.resolvingSymlinksInPath().path
        let archivablePath = archivableFile.resolvingSymlinksInPath().path
        let root = home.codexRoot.resolvingSymlinksInPath().path

        let firstPass = (
            BuiltInProtectedPaths.isProtected(protectedPath, underToolRoot: root, homeDirectory: home.homeDirectory),
            BuiltInProtectedPaths.isProtected(archivablePath, underToolRoot: root, homeDirectory: home.homeDirectory)
        )

        // 先查一个不命中的路径，再查受保护路径，结果不应因为调用顺序而改变。
        _ = BuiltInProtectedPaths.protection(forPath: archivablePath, underToolRoot: root, homeDirectory: home.homeDirectory)

        let secondPass = (
            BuiltInProtectedPaths.isProtected(protectedPath, underToolRoot: root, homeDirectory: home.homeDirectory),
            BuiltInProtectedPaths.isProtected(archivablePath, underToolRoot: root, homeDirectory: home.homeDirectory)
        )

        XCTAssertEqual(firstPass.0, true)
        XCTAssertEqual(firstPass.1, false)
        XCTAssertEqual(firstPass.0, secondPass.0)
        XCTAssertEqual(firstPass.1, secondPass.1)
    }

    func test内置清单条目都是完整可读的() {
        XCTAssertFalse(BuiltInProtectedPaths.rules.isEmpty)
        XCTAssertEqual(
            Set(BuiltInProtectedPaths.rules.map(\.identifier)).count,
            BuiltInProtectedPaths.rules.count,
            "条目标识必须唯一，报错信息才能指明是哪条规则"
        )
        for rule in BuiltInProtectedPaths.rules {
            XCTAssertFalse(rule.identifier.isEmpty)
            XCTAssertFalse(rule.pattern.isEmpty)
        }
    }

    func test实测的凭证位置全部受保护() throws {
        let (home, fixture) = try makeHome("credentials")
        defer { fixture.remove() }

        // PRD §14.5 实测列出的凭证位置：不得读取、不得归档。
        let credentialFiles: [(owner: String, file: String)] = [
            ("codex-cli", "auth.json"),
            ("codex-cli", "oauth_creds.json"),
            ("codex-cli", "oauth_creds.json"),
            ("codex-cli", "oauth_creds.json"),
            ("deepseek-harness", ".credentials.yaml"),
        ]
        let credentialRoots: [URL] = [
            home.codexRoot,
            home.toolRoot(".gemini"),
            home.toolRoot(".qwen"),
            home.toolRoot(".iflow"),
            home.harnessRoot,
        ]

        for (root, entry) in zip(credentialRoots, credentialFiles) {
            let url = try ProtectedPathTestSupport.createFile(named: entry.file, in: root)
            XCTAssertTrue(
                isProtected(url, under: root, home: home),
                "凭证文件必须受保护：\(entry.file)（PRD §14.5）"
            )
        }
    }

}
