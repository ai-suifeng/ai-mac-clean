import XCTest

import AIMacCleanCore
@testable import AIMacCleanRules

/// Seam R4：加载器（issue #10 的验收「加载器行为」）。
///
/// 断言只落在公开接口 `RuleLoader` 上：读得进、结构合法、缺失容忍、坏文件有可读诊断。
/// 所有文件都写在临时目录里，真实 AI 工具数据目录绝不参与（PRD §13 第 3 条）。
final class RuleLoaderTests: XCTestCase {

    private var fixture: TemporaryDirectoryFixture!

    override func setUpWithError() throws {
        fixture = try TemporaryDirectoryFixture(named: "rule-loader")
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    private func writeRule(_ name: String, _ contents: String) throws -> URL {
        let url = fixture.url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: 单文件加载

    func test从文件加载规则() throws {
        let url = try writeRule("claude-code.json", RuleFixtures.claudeCodeJSON)
        let rule = try RuleLoader.loadRule(at: url)
        XCTAssertEqual(rule.id, "claude-code")
    }

    // MARK: 容忍缺失

    func test声明的路径在磁盘上不存在时加载成功() throws {
        // 工具根目录指向一个不存在的临时路径：加载期不检查存在性。
        let json = """
        {"schemaVersion":1,"id":"ghost","displayName":"Ghost",
         "roots":[{"path":"\(fixture.url.path)/never-created"}]}
        """
        let url = try writeRule("ghost.json", json)

        let rule = try RuleLoader.loadRule(at: url)
        XCTAssertEqual(rule.roots.first?.path, fixture.url.path + "/never-created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path + "/never-created"))
    }

    func test关联数据目录缺失不影响加载() throws {
        // 旧版 Claude Code 才有 file-history/ 与 todos/；新版没有，文件历史内联进转录
        // （PRD §5.4、§14.5）。规则照旧声明二者，磁盘上没有也不该报错。
        let toolRoot = try fixture.makeDirectory("home/.claude")
        try FileManager.default.createDirectory(
            at: toolRoot.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )

        let url = try writeRule("claude-code.json", RuleFixtures.claudeCodeJSON)
        XCTAssertNoThrow(try RuleLoader.loadRule(at: url))

        let report = RuleLoader.loadRules(inDirectory: fixture.url)
        XCTAssertEqual(report.diagnostics, [])
        let declared = try XCTUnwrap(report.rules.first).cascade.map(\.pattern.canonicalString)
        XCTAssertTrue(declared.contains("file-history/<name:sessionID>"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: toolRoot.appendingPathComponent("file-history").path))
    }

    func test规则目录不存在时得到空规则集而不是失败() {
        let missing = fixture.url.appendingPathComponent("no-such-dir", isDirectory: true)
        let report = RuleLoader.loadRules(inDirectory: missing)
        XCTAssertEqual(report.rules, [])
        XCTAssertEqual(report.diagnostics, [])
    }

    // MARK: 可读诊断

    func test非法JSON给出可读诊断而不是崩溃() throws {
        let url = try writeRule("broken.json", "{\"schemaVersion\":1, \"id\": \"x\"")
        XCTAssertThrowsError(try RuleLoader.loadRule(at: url)) { error in
            let loadError = error as? RuleLoadError
            XCTAssertEqual(loadError?.source, url.path)
            let message = loadError?.errorDescription ?? ""
            XCTAssertTrue(message.contains("JSON"), "诊断要说明是 JSON 问题，实际：\(message)")
            XCTAssertTrue(message.contains(url.lastPathComponent))
        }
    }

    func test缺少必填字段给出可读诊断() throws {
        let url = try writeRule("missing-id.json", #"{"schemaVersion":1,"displayName":"X","roots":[]}"#)
        XCTAssertThrowsError(try RuleLoader.loadRule(at: url)) { error in
            guard case let .invalidRule(_, reason)? = error as? RuleLoadError else {
                return XCTFail("应报规则非法，实际：\(error)")
            }
            XCTAssertEqual(reason, .missingRequiredField(field: "id"))
            XCTAssertTrue((error as? RuleLoadError)?.errorDescription?.contains("id") == true)
        }
    }

    func test不支持的版本给出可读诊断() throws {
        let url = try writeRule("future.json", #"{"schemaVersion":99,"id":"x","displayName":"X","roots":[{"path":"/tmp/x"}]}"#)
        XCTAssertThrowsError(try RuleLoader.loadRule(at: url)) { error in
            guard case let .invalidRule(_, reason)? = error as? RuleLoadError else {
                return XCTFail("应报规则非法，实际：\(error)")
            }
            XCTAssertEqual(reason, .unsupportedSchemaVersion(found: 99, supported: 1))
        }
    }

    func test语法错误的路径模式指出是哪个字段() throws {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"/tmp/x"}],
         "classification":[{"pattern":"skills/**/cache","category":"protected"}]}
        """
        let url = try writeRule("bad-pattern.json", json)
        XCTAssertThrowsError(try RuleLoader.loadRule(at: url)) { error in
            guard case let .invalidRule(_, reason)? = error as? RuleLoadError else {
                return XCTFail("应报规则非法，实际：\(error)")
            }
            guard case let .invalidFieldValue(field, _) = reason else {
                return XCTFail("应指出字段问题，实际：\(reason)")
            }
            XCTAssertEqual(field, "pattern")
        }
    }

    func test根目录路径形状非法时报错() throws {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"claude/数据"}]}
        """
        let url = try writeRule("bad-root.json", json)
        XCTAssertThrowsError(try RuleLoader.loadRule(at: url)) { error in
            guard case let .invalidRule(_, reason)? = error as? RuleLoadError,
                  case .invalidFieldValue(let field, _) = reason else {
                return XCTFail("应报字段取值不合法，实际：\(error)")
            }
            XCTAssertEqual(field, "roots.path")
        }
    }

    func test文件不可读时给出可读诊断() throws {
        // 用「拿一个目录当规则文件」来触发读取失败，不依赖权限位。
        let url = fixture.url.appendingPathComponent("a-directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try RuleLoader.loadRule(at: url)) { error in
            guard case .unreadableFile? = error as? RuleLoadError else {
                return XCTFail("应报文件读不了，实际：\(error)")
            }
            XCTAssertTrue((error as? RuleLoadError)?.errorDescription?.contains("a-directory.json") == true)
        }
    }

    // MARK: 批量加载

    func test目录里混入坏文件时好规则仍然加载成功() throws {
        _ = try writeRule("claude-code.json", RuleFixtures.claudeCodeJSON)
        _ = try writeRule("codex-cli.json", RuleFixtures.codexJSON)
        _ = try writeRule("broken.json", "{\"schemaVersion\":1, \"id\"")
        _ = try writeRule("missing-id.json", #"{"schemaVersion":1,"displayName":"X","roots":[{"path":"/tmp/x"}]}"#)

        let report = RuleLoader.loadRules(inDirectory: fixture.url)

        XCTAssertEqual(Set(report.rules.map(\.id)), ["claude-code", "codex-cli"])
        XCTAssertEqual(report.diagnostics.count, 2)
        XCTAssertTrue(report.diagnostics.allSatisfy { !$0.source.isEmpty })
    }

    func test目录加载不跟随符号链接去读规则文件() throws {
        // 只读 *.json；子目录里的同名文件不参与加载。
        try writeRule("claude-code.json", RuleFixtures.claudeCodeJSON)
        let nested = try fixture.makeDirectory("nested")
        try Data(RuleFixtures.codexJSON.utf8).write(to: nested.appendingPathComponent("codex-cli.json"))

        let report = RuleLoader.loadRules(inDirectory: fixture.url)
        XCTAssertEqual(report.rules.map(\.id), ["claude-code"])
    }

    func test诊断按来源路径排序以便界面稳定展示() throws {
        _ = try writeRule("zzz-broken.json", "{\"id\"")
        _ = try writeRule("aaa-broken.json", "{\"id\"")

        let report = RuleLoader.loadRules(inDirectory: fixture.url)
        let sources = report.diagnostics.map(\.source)
        XCTAssertEqual(sources, sources.sorted())
    }

    // MARK: 引擎不含工具名分支

    func test新增工具不需要改引擎代码() throws {
        // 一个从未见过的工具：引擎只按规则文件里的声明读，不认识它的名字。
        let json = """
        {"schemaVersion":1,"id":"brand-new-tool","displayName":"Brand New Tool",
         "roots":[{"path":"/tmp/brand-new"}],
         "structuralFingerprint":{"sessionFilePatterns":["data/<uuid>/<uuid>.jsonl"]},
         "projectPathEncoding":{"scheme":"singleDash"},
         "selfCompressed":false}
        """
        let url = try writeRule("brand-new-tool.json", json)
        let rule = try RuleLoader.loadRule(at: url)

        XCTAssertEqual(rule.id, "brand-new-tool")
        XCTAssertEqual(rule.structuralFingerprint?.sessionFilePatterns.map(\.canonicalString),
                       ["data/<uuid>/<uuid>.jsonl"])
    }
}
