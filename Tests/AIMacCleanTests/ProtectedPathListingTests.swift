import Foundation
import XCTest

import AIMacCleanRules

/// issue #19 验收 3：受保护判定**不再列举主目录**，判定结果一字不变。
///
/// 判定要为受保护目录条目做通配展开。展开本身允许——**但只允许发生在规则声明的
/// 工具根内部**：`~/.codex/skills → ~/.agents/skills` 这类链接靠工具根内的展开就能
/// 认出真实目标；把 `homeDirectory` 当成展开根（旧实现）等于每次判定都把用户主目录
/// 列一遍，那正是要清掉的第二个通用位置扫描。
final class ProtectedPathListingTests: XCTestCase {

    func test主目录作用域的受保护条目判定不变且不列举主目录() throws {
        let fixture = try TemporaryDirectoryFixture(named: "protected-listing")
        defer { fixture.remove() }
        let home = try ProtectedPathTestSupport.FakeHome.make(named: "protected-listing", fixture: fixture)

        // 命中主目录条目的状态文件。
        let claudeState = try ProtectedPathTestSupport.createFile(named: ".claude.json", in: home.root)
        // 命中工具根条目的凭证。
        let codexAuth = try ProtectedPathTestSupport.createFile(named: "auth.json", in: home.codexRoot)
        // 共享技能目录，与 `~/.codex/skills` → `~/.agents/skills` 的链接。
        let sharedSkills = try ProtectedPathTestSupport.createDirectory(named: ".agents/skills", in: home.root)
        let sharedFile = try ProtectedPathTestSupport.createFile(named: "SKILL.md", in: sharedSkills)
        try ProtectedPathTestSupport.createSymbolicLink(named: "skills", in: home.codexRoot, pointingTo: sharedSkills)
        // 一条**只能靠工具根内展开**才认得出的真实目标（Cursor 的 `plugins` 形态）：
        // 它保证这次判定真的走到了展开那一步，否则「没有列举主目录」是句空话。
        let realPlugins = try ProtectedPathTestSupport.createDirectory(named: "cursor-plugin-marketplace", in: home.root)
        let realPluginFile = try ProtectedPathTestSupport.createFile(named: "plugin.json", in: realPlugins)
        try ProtectedPathTestSupport.createSymbolicLink(named: "plugins", in: home.cursorRoot, pointingTo: realPlugins)

        let listing = RecordingProtectedPathDirectoryListing()

        func protection(_ path: URL, under root: URL) -> ProtectedMatch? {
            BuiltInProtectedPaths.protection(
                forPath: path.resolvingSymlinksInPath().path,
                underToolRoot: root.resolvingSymlinksInPath().path,
                homeDirectory: home.homeDirectory,
                listing: listing
            )
        }

        // 判定结果不变（PRD §5.4 / §14.5、验收 A3 / A8）。
        XCTAssertEqual(
            protection(claudeState, under: home.claudeRoot)?.ruleIdentifier,
            "home/claude-state"
        )
        XCTAssertEqual(
            protection(codexAuth, under: home.codexRoot)?.ruleIdentifier,
            "codex-cli/auth"
        )
        XCTAssertEqual(
            protection(
                home.codexRoot.appendingPathComponent("skills/我的技能/SKILL.md"),
                under: home.codexRoot
            )?.ruleIdentifier,
            "codex-cli/skills"
        )
        XCTAssertEqual(
            protection(sharedFile, under: home.cursorRoot)?.ruleIdentifier,
            "home/shared-skills",
            "`~/.codex/skills` 的真实目标 `~/.agents/skills` 本身也要受保护（验收 A3 / A8）"
        )
        XCTAssertEqual(
            protection(realPluginFile, under: home.cursorRoot)?.ruleIdentifier,
            "cursor/plugins"
        )
        XCTAssertEqual(
            protection(realPluginFile, under: home.cursorRoot)?.matchedVia,
            .symlinkRealTarget
        )

        // 关键断言：展开确实发生过，而它只列举了规则声明的工具根。
        XCTAssertFalse(
            listing.listedDirectories.isEmpty,
            "这条用例必须真的触发过一次通配展开，否则断言没有意义"
        )

        let toolRoots = [
            ".claude",
            ".codex",
            ".cursor",
            "Library/Application Support/deepseek-harness-desktop/harness-home",
        ].map { home.homeDirectory + "/" + $0 }

        for directory in listing.listedDirectories {
            XCTAssertTrue(
                toolRoots.contains { directory == $0 || directory.hasPrefix($0 + "/") },
                "\(directory) 不在任何规则声明的工具根之内，受保护判定不该列举它：\(listing.listedDirectories)"
            )
        }

        // 特别是主目录与 `~/.agents`：一次都不许列举。
        for forbidden in [
            home.homeDirectory,
            home.root.path,
            home.homeDirectory + "/.agents",
            home.root.appendingPathComponent(".agents").path,
        ] {
            XCTAssertFalse(
                listing.listedDirectories.contains(forbidden),
                "\(forbidden) 不是规则声明的工具根，受保护判定不该列举它：\(listing.listedDirectories)"
            )
        }
    }
}
