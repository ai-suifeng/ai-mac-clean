import XCTest

@testable import AIMacCleanRules

/// Seam R2：规则文件 → 声明式模型（issue #10 的验收「一份覆盖 PRD §5.4 实测形状的规则文件能被加载」）。
///
/// 断言只落在公开接口上：加载出来的规则能表达实测形状、能声明分类与保护路径、
/// 能声明四套项目路径编码，且引擎里没有任何工具名分支。
final class ToolRuleDecodingTests: XCTestCase {

    func test加载覆盖实测形状的规则() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.claudeCodeJSON.utf8))

        XCTAssertEqual(rule.schemaVersion, ToolRule.currentSchemaVersion)
        XCTAssertEqual(rule.id, "claude-code")
        XCTAssertEqual(rule.displayName, "Claude Code")
        XCTAssertEqual(rule.roots, [ToolRoot(path: "~/.claude", role: .toolRoot)])
        XCTAssertFalse(rule.selfCompressed)
    }

    func test结构指纹表达会话路径模式与目录形态() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.claudeCodeJSON.utf8))
        let fingerprint = try XCTUnwrap(rule.structuralFingerprint)

        XCTAssertEqual(
            fingerprint.sessionFilePatterns.map(\.canonicalString),
            ["projects/<encodedPath>/<uuid>.jsonl"]
        )
        XCTAssertEqual(
            fingerprint.projectDirectoryShapes.map(\.canonicalString),
            ["projects/<encodedPath>"]
        )
        XCTAssertEqual(fingerprint.fileHeaderKeys, ["type"])
        XCTAssertEqual(fingerprint.headerByteLimit, 4096)
    }

    func test文件级联关系表达子代理转录与关联数据() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.claudeCodeJSON.utf8))
        XCTAssertEqual(rule.cascade.map(\.kind), [.siblingTranscripts, .sessionKeyedDirectory, .sessionKeyedFile])
        XCTAssertEqual(rule.cascade[0].pattern.canonicalString, "agent-<uuid>.jsonl")
        XCTAssertEqual(rule.cascade[1].pattern.canonicalString, "file-history/<name:sessionID>")
        XCTAssertEqual(rule.cascade[2].pattern.canonicalString, "todos/<name:sessionID>-agent-<name:sessionID>.json")
    }

    func test项目路径编码方案被声明且不依赖逆向解码() throws {
        let single = try ToolRule.decode(from: Data(RuleFixtures.claudeCodeJSON.utf8))
        XCTAssertEqual(single.projectPathEncoding?.scheme, .doubleDash)

        let inFile = try ToolRule.decode(from: Data(RuleFixtures.codexJSON.utf8))
        XCTAssertEqual(inFile.projectPathEncoding?.scheme, .inFileField)
        XCTAssertEqual(inFile.projectPathEncoding?.fieldPath, "session_meta.payload.cwd")

        // 四套方案里至少三种都在枚举里，且都是通用方案名，不含工具名。
        XCTAssertEqual(Set(ProjectPathEncodingScheme.allCases.map(\.rawValue)),
                       ["singleDash", "doubleDash", "inFileField"])
    }

    func test分类映射与受保护路径() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.claudeCodeJSON.utf8))
        let byPattern = Dictionary(uniqueKeysWithValues: rule.classification.map { ($0.pattern.canonicalString, $0.category) })
        XCTAssertEqual(byPattern["projects/<encodedPath>/<uuid>.jsonl"], .archivableSession)
        XCTAssertEqual(byPattern["skills/**"], .protected)
        // `shell-snapshots/**` 与内置受保护条目 `claude-code/shell-snapshots` 重叠，
        // 因此声明为受保护：改判成缓存同样会被规则集准入拒绝。
        XCTAssertEqual(byPattern["shell-snapshots/**"], .protected)
        XCTAssertEqual(byPattern["history.jsonl"], .protected)
    }

    func test自带压缩的声明位() throws {
        let codex = try ToolRule.decode(from: Data(RuleFixtures.codexJSON.utf8))
        XCTAssertTrue(codex.selfCompressed)
    }

    func test会话文件名形态能表达文件名不是稳定ID() throws {
        let plain = try ToolRule.decode(from: Data(RuleFixtures.claudeCodeJSON.utf8))
        XCTAssertEqual(plain.sessionFileNaming?.stableSessionIdentifier, true)

        let forked = try ToolRule.decode(from: Data(RuleFixtures.codexJSON.utf8))
        XCTAssertEqual(forked.sessionFileNaming?.stableSessionIdentifier, false)
        XCTAssertEqual(forked.sessionFileNaming?.sessionIDSource, .fileName)

        let harness = try ToolRule.decode(from: Data(RuleFixtures.harnessJSON.utf8))
        XCTAssertEqual(harness.sessionFileNaming?.sessionIDSource, .parentDirectoryName)
    }

    func testCodex规则表达两种扩展名与扁平归档目录() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.codexJSON.utf8))
        let patterns = try XCTUnwrap(rule.structuralFingerprint).sessionFilePatterns.map(\.canonicalString)
        XCTAssertTrue(patterns.contains("sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl"))
        XCTAssertTrue(patterns.contains("sessions/<date:year>/<date:month>/<date:day>/rollout-<ISO>.jsonl[.zst]"))
        XCTAssertTrue(patterns.contains("archived_sessions/rollout-<ISO>.jsonl.zst"))
    }

    func testCursor规则表达主转录与子代理转录的级联() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.cursorJSON.utf8))
        let fingerprint = try XCTUnwrap(rule.structuralFingerprint)
        XCTAssertEqual(
            fingerprint.sessionFilePatterns.map(\.canonicalString),
            ["projects/<encodedPath>/agent-transcripts/<uuid>/<uuid>.jsonl"]
        )
        XCTAssertEqual(rule.cascade.map(\.pattern.canonicalString),
                       ["subagents/*.jsonl"])
    }

    func testHarness规则表达应用支持目录下的工具根与单文件会话() throws {
        let rule = try ToolRule.decode(from: Data(RuleFixtures.harnessJSON.utf8))
        XCTAssertEqual(rule.roots, [
            ToolRoot(path: "~/Library/Application Support/deepseek-harness-desktop/harness-home", role: .toolRoot),
            ToolRoot(path: "~/Library/Application Support/@deepseek-ai/dsh-desktop", role: .displayOnly),
        ])
        XCTAssertEqual(
            rule.structuralFingerprint?.sessionFilePatterns.map(\.canonicalString),
            ["sessions/<encodedPath>/session-<uuid>/session.jsonl.zstd"]
        )
    }

    func test未知字段被忽略以便规则文件向前兼容() throws {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"~/.x"}],
         "futureField":{"nested":true}}
        """
        let rule = try ToolRule.decode(from: Data(json.utf8))
        XCTAssertEqual(rule.id, "x")
        XCTAssertEqual(rule.roots, [ToolRoot(path: "~/.x", role: .toolRoot)])
    }

    func test可选字段可省略并取保守默认值() throws {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"/tmp/x"}]}
        """
        let rule = try ToolRule.decode(from: Data(json.utf8))
        XCTAssertNil(rule.structuralFingerprint)
        XCTAssertNil(rule.projectPathEncoding)
        XCTAssertNil(rule.sessionFileNaming)
        XCTAssertEqual(rule.cascade, [])
        XCTAssertEqual(rule.classification, [])
        XCTAssertFalse(rule.selfCompressed)
    }

    // MARK: - 安装路径声明（issue #19）

    /// **安装路径声明**：规则声明「这个工具装在哪」。`kind` 只有两种含义——
    /// App 包与可执行文件——因为安装佐证只分这两类。
    func test安装路径声明被解析为路径与种类() throws {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"~/.x"}],
         "installations":[
           {"path":"/Applications/X.app","kind":"appBundle"},
           {"path":"~/.local/bin/x","kind":"executable"}
         ]}
        """
        let rule = try ToolRule.decode(from: Data(json.utf8))

        XCTAssertEqual(rule.installations, [
            DeclaredInstallation(path: "/Applications/X.app", kind: .appBundle),
            DeclaredInstallation(path: "~/.local/bin/x", kind: .executable),
        ])
    }

    /// 省略 `installations` = 这个工具没有已知安装位置。**一条都不查**：
    /// 宁可没有安装佐证停在「中」，也不在代码里替它猜一个通用位置（issue #19）。
    func test省略安装路径声明时一条都不声明() throws {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"~/.x"}]}
        """
        let rule = try ToolRule.decode(from: Data(json.utf8))

        XCTAssertEqual(rule.installations, [])
    }

    /// 安装路径与工具根一样必须锚定：`~/…` 或绝对路径，别的写法一律拒绝。
    func test安装路径必须锚定主目录或绝对路径() {
        for bad in [".claude/bin/claude", "bin/claude", "~/"] {
            let json = """
            {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"~/.x"}],
             "installations":[{"path":"\(bad)","kind":"executable"}]}
            """
            XCTAssertThrowsError(try ToolRule.decode(from: Data(json.utf8)), "\(bad) 不该被接受") { error in
                XCTAssertTrue(
                    "\(error)".contains("installations"),
                    "报错要指出是哪个字段，实际：\(error)"
                )
            }
        }
    }

    /// 种类是封闭枚举：读不懂的种类必须报错，而不是静默当成别的东西。
    func test安装路径种类未知时拒绝() {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"~/.x"}],
         "installations":[{"path":"/opt/homebrew/bin/x","kind":"symlink"}]}
        """
        XCTAssertThrowsError(try ToolRule.decode(from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("symlink"), "实际：\(error)")
        }
    }

    /// `appBundle` 声称的是 App 包，路径就必须指向 `.app`——
    /// 否则「同名 App 装在这儿」这条佐证是句说不通的话。
    func testappBundle声明的路径必须以app结尾() {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"~/.x"}],
         "installations":[{"path":"/Applications/X","kind":"appBundle"}]}
        """
        XCTAssertThrowsError(try ToolRule.decode(from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains(".app"), "实际：\(error)")
        }
    }

    /// 同一工具重复声明同一路径没有意义，只会让「一条声明一次访问」的次数对不上，因此拒绝。
    func test同一工具重复声明同一安装路径时拒绝() {
        let json = """
        {"schemaVersion":1,"id":"x","displayName":"X","roots":[{"path":"~/.x"}],
         "installations":[
           {"path":"/opt/homebrew/bin/x","kind":"executable"},
           {"path":"/opt/homebrew/bin/x","kind":"executable"}
         ]}
        """
        XCTAssertThrowsError(try ToolRule.decode(from: Data(json.utf8))) { error in
            XCTAssertTrue("\(error)".contains("重复"), "实际：\(error)")
        }
    }
}
