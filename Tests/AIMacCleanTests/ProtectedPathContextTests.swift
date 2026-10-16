import Foundation

import XCTest

@testable import AIMacCleanRules

/// issue #29：受保护判定的**扫描期快照**（`ProtectedPathContext`）。
///
/// 深扫要在 5 万文件上**逐文件**做受保护判定。走原来的逐次入口
/// `BuiltInProtectedPaths.protection(forPath:underToolRoot:homeDirectory:listing:)` 时，
/// 每次判定都要重新解析工具根与主目录的符号链接、重新展开受保护目录——本机实测
/// （见 issue #29 评论）这一项占满了深扫 132 秒里的大头，而且与「这条路径是否受保护」
/// 毫无关系：同一棵树的这些信息在一次扫描期间根本不变。
///
/// 快照把不变的那部分算一次，但**不改变任何判定结论**。本组用例把这句话钉死：
/// 同一棵树上的每一条路径，新旧两条入口给出的结论必须逐字段相同；同时断言
/// 「判定次数增长不再带来磁盘读取增长」——这是快照存在的理由本身。
final class ProtectedPathContextTests: XCTestCase {

    // MARK: - 夹具：一棵形状照抄真实主目录的树

    private struct Tree {
        let home: ProtectedPathTestSupport.FakeHome
        let fixture: TemporaryDirectoryFixture

        var codexRoot: String { home.codexRoot.resolvingSymlinksInPath().path }
        var homeDirectory: String { home.homeDirectory }
    }

    private func makeTree(_ name: String) throws -> Tree {
        let fixture = try TemporaryDirectoryFixture(named: name)
        let home = try ProtectedPathTestSupport.FakeHome.make(named: name, fixture: fixture)

        // PRD §14.5 的真实形状：`~/.codex/skills` → `~/.agents/skills`。
        try ProtectedPathTestSupport.createFile(
            named: "SKILL.md",
            in: home.root.appendingPathComponent(".agents/skills")
        )
        try ProtectedPathTestSupport.createSymbolicLink(
            named: "skills",
            in: home.codexRoot,
            pointingTo: home.root.appendingPathComponent(".agents/skills")
        )
        // 工具根之外的媒体库：不受任何内置条目保护。
        try ProtectedPathTestSupport.createFile(
            named: "movie.bin",
            in: home.root.appendingPathComponent("movies")
        )
        // 工具根之内的文件、目录、以及一条指向外部媒体库的链接。
        try ProtectedPathTestSupport.createFile(named: "auth.json", in: home.codexRoot)
        try ProtectedPathTestSupport.createFile(named: "config.toml", in: home.codexRoot)
        try ProtectedPathTestSupport.createFile(named: "app.sqlite", in: home.codexRoot)
        try ProtectedPathTestSupport.createFile(
            named: "rollout-1.jsonl",
            in: home.codexRoot.appendingPathComponent("sessions/2026/10/15")
        )
        try ProtectedPathTestSupport.createFile(
            named: "stale.jsonl",
            in: home.codexRoot.appendingPathComponent(".tmp/shard-000")
        )
        try ProtectedPathTestSupport.createSymbolicLink(
            named: "link-out",
            in: home.codexRoot,
            pointingTo: home.root.appendingPathComponent("movies")
        )
        return Tree(home: home, fixture: fixture)
    }

    /// 树上要被判定的路径：工具根下外、受保护、不确定、链接目标、外部位置都要有。
    private func probePaths(_ tree: Tree) -> [String] {
        let codex = tree.home.codexRoot
        let paths = [
            tree.home.claudeRoot.path,
            tree.home.cursorRoot.path,
            tree.home.harnessRoot.path,
            codex.path,
            codex.appendingPathComponent("auth.json").path,
            codex.appendingPathComponent("config.toml").path,
            codex.appendingPathComponent("app.sqlite").path,
            codex.appendingPathComponent("sessions").path,
            codex.appendingPathComponent("sessions/2026/10/15/rollout-1.jsonl").path,
            codex.appendingPathComponent(".tmp/shard-000/stale.jsonl").path,
            codex.appendingPathComponent("skills").path,
            codex.appendingPathComponent("skills/SKILL.md").path,
            codex.appendingPathComponent("link-out").path,
            codex.appendingPathComponent("link-out/movie.bin").path,
            tree.home.root.appendingPathComponent("movies").path,
            tree.home.root.appendingPathComponent("movies/movie.bin").path,
            tree.home.root.appendingPathComponent(".agents/skills").path,
            tree.home.root.appendingPathComponent(".agents/skills/SKILL.md").path,
            tree.home.root.appendingPathComponent(".claude.json").path,
            tree.home.root.appendingPathComponent("没有这个路径/nope.bin").path,
        ]
        return paths
    }

    // MARK: - 结论必须逐字段相同

    func test快照与逐次判定对同一棵树的结论逐字段相同() throws {
        let tree = try makeTree("context-parity")
        defer { tree.fixture.remove() }

        let context = ProtectedPathContext(
            toolRoot: tree.home.codexRoot.path,
            homeDirectory: tree.homeDirectory,
            listing: RealProtectedPathDirectoryListing()
        )

        for path in probePaths(tree) {
            let legacy = BuiltInProtectedPaths.protection(
                forPath: path,
                underToolRoot: tree.home.codexRoot.path,
                homeDirectory: tree.homeDirectory,
                listing: RealProtectedPathDirectoryListing()
            )
            XCTAssertEqual(
                context.protection(forPath: path),
                legacy,
                "快照判定必须与逐次判定逐字段相同：\(path)"
            )
            XCTAssertEqual(
                context.protection(forPath: path, resolvedPath: context.resolvedPath(forPath: path)),
                legacy,
                "显式给出已解析路径时也必须同结论：\(path)"
            )
        }
    }

    func test至少有一条受保护路径与一条不受保护路径否则这组用例没有意义() throws {
        let tree = try makeTree("context-sanity")
        defer { tree.fixture.remove() }

        let context = ProtectedPathContext(
            toolRoot: tree.home.codexRoot.path,
            homeDirectory: tree.homeDirectory
        )
        let verdicts = probePaths(tree).map { context.protection(forPath: $0) }

        XCTAssertTrue(verdicts.contains { $0 != nil }, "对照组：必须真的有路径被判为受保护")
        XCTAssertTrue(verdicts.contains { $0 == nil }, "对照组：必须真的有路径不被判为受保护")
        XCTAssertEqual(
            context.protection(forPath: tree.home.codexRoot.appendingPathComponent("skills").path)?.ruleIdentifier,
            "codex-cli/skills",
            "链接位置命中内置条目（第 1 步）"
        )
        XCTAssertEqual(
            context.protection(forPath: tree.home.root.appendingPathComponent(".agents/skills").path)?.ruleIdentifier,
            "home/shared-skills",
            "链接真实目标本身也受保护（PRD §14.5）"
        )
    }

    // MARK: - 第 6 步（真实目标落在受保护目录之下）在快照里只展开一次

    /// 主目录**之外**的共享技能目录：这里第 6 步是唯一能判出受保护的入口——
    /// 真实目标既不相对工具根、也不相对主目录，只可能被「受保护目录的真实路径」覆盖。
    /// 快照把这一步的展开提前到扫描开始，本用例保证提前算不改变结论。
    func test真实目标在主目录之外时仍按受保护目录判定() throws {
        let fixture = try TemporaryDirectoryFixture(named: "context-outside-home")
        defer { fixture.remove() }

        let root = fixture.url
        let home = root.appendingPathComponent("home")
        let codexRoot = home.appendingPathComponent(".codex")
        let sharedSkills = root.appendingPathComponent("shared-apps/skills")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try ProtectedPathTestSupport.createFile(named: "SKILL.md", in: sharedSkills)
        try ProtectedPathTestSupport.createSymbolicLink(
            named: "skills",
            in: codexRoot,
            pointingTo: sharedSkills
        )

        let context = ProtectedPathContext(
            toolRoot: codexRoot.path,
            homeDirectory: home.path
        )

        for path in [
            sharedSkills.path,
            sharedSkills.appendingPathComponent("SKILL.md").path,
            codexRoot.appendingPathComponent("skills/SKILL.md").path,
        ] {
            let legacy = BuiltInProtectedPaths.protection(
                forPath: path,
                underToolRoot: codexRoot.path,
                homeDirectory: home.path,
                listing: RealProtectedPathDirectoryListing()
            )
            XCTAssertEqual(context.protection(forPath: path), legacy, "第 6 步的判定不能被快照改动：\(path)")
        }

        XCTAssertEqual(
            context.protection(forPath: sharedSkills.appendingPathComponent("SKILL.md").path)?.matchedVia,
            .symlinkRealTarget,
            "主目录之外的受保护目录目标必须由第 6 步判出"
        )
        XCTAssertEqual(
            context.protection(forPath: sharedSkills.appendingPathComponent("SKILL.md").path)?.ruleIdentifier,
            "codex-cli/skills"
        )
    }

    // MARK: - 快照存在的理由：判定次数增长不再带来磁盘读取增长

    func test批量判定时目录展开只做一次而不随判定次数增长() throws {
        let tree = try makeTree("context-listing-bound")
        defer { tree.fixture.remove() }

        let paths = probePaths(tree)
        // 只跑 8 轮：逐次判定一侧每次都真的读盘（约 2ms/次），轮数再多只是让测试变慢，
        // 而「随判定次数线性增长」与「一次展开后不再增长」的对比 8 轮已经足够清楚。
        let repetitions = 8

        let legacyListing = RecordingProtectedPathDirectoryListing()
        for _ in 0..<repetitions {
            for path in paths {
                _ = BuiltInProtectedPaths.protection(
                    forPath: path,
                    underToolRoot: tree.home.codexRoot.path,
                    homeDirectory: tree.homeDirectory,
                    listing: legacyListing
                )
            }
        }

        let contextListing = RecordingProtectedPathDirectoryListing()
        let context = ProtectedPathContext(
            toolRoot: tree.home.codexRoot.path,
            homeDirectory: tree.homeDirectory,
            listing: contextListing
        )
        for _ in 0..<repetitions {
            for path in paths {
                _ = context.protection(forPath: path)
            }
        }

        XCTAssertGreaterThan(
            legacyListing.listedDirectories.count,
            contextListing.listedDirectories.count,
            "逐次判定必须真的比快照读得多，否则这条断言没有对照"
        )
        XCTAssertLessThanOrEqual(
            contextListing.listedDirectories.count,
            64,
            "快照的目录展开必须是一次性的：判定 \(paths.count * repetitions) 次也不该让列举次数跟着涨"
        )
        XCTAssertGreaterThan(
            legacyListing.listedDirectories.count,
            paths.count,
            "逐次判定会随判定次数线性读取磁盘——这正是深扫 5 万文件时慢的原因"
        )
    }
}
