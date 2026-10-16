import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #23：受保护判定与零写入。
///
/// 受保护是四类里唯一「禁止归档、禁止移除」的一类（GLOSSARY「受保护」），因此这里
/// 不只看它有没有被算对，还要看它**有没有被碰过**：命中受保护的路径一个字节都不许动。
///
/// 判定本身复用 M1 的 `BuiltInProtectedPaths`（PRD §8.1：内置清单在代码层强制，
/// 规则只能抬高不能降低）；深扫的职责是把它接到每一层目录上，并且**按链接真实目标**判定
/// （`~/.codex/skills → ~/.agents/skills` 形态，PRD §14.5）。
final class DeepScanProtectedPathTests: XCTestCase {

    /// 真实形状（PRD §2.2）的最后一段是 `harness-home`，而 `scope(ofToolRoot:)` 正是按
    /// 最后一段识别已知工具根的，所以用完整路径即可，不需要复刻整棵 `~/Library`。
    private let harnessRootSuffix = "Library/Application Support/deepseek-harness-desktop/harness-home"

    private func makeScanner(_ fileSystem: any DiscoveryFileSystem) -> DeepScanner {
        DeepScanner(fileSystem: fileSystem)
    }

    // MARK: - 验收 2：受保护的配置 / 凭证 / 技能目录算进「受保护」

    func test受保护的技能与凭证目录被算进受保护且总共零写入() throws {
        let fixture = try DeepScanFixture(named: "protected")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: "codex",
            classificationJSON: [
                "{\"pattern\": \"sessions/**\", \"category\": \"archivableSession\"}",
                "{\"pattern\": \"skills/**\", \"category\": \"protected\"}",
            ]
        )
        // 技能：164 个文件（PRD §14.5 的实测数量），规则声明为受保护。
        for index in 0..<164 {
            try fixture.write("codex/skills/skill-\(index)/SKILL.md", bytes: 100)
        }
        // 凭证：`auth.json` 是**纯凭证文件名**，任何位置都保护（内置条目 credential/auth）。
        // 规则**没有**声明它——保护必须来自内置清单，而不是靠规则作者记得写。
        try fixture.write("codex/auth.json", bytes: 900)
        // 可归档：规则声明了。
        try fixture.write("codex/sessions/2026/10/14/rollout-1.jsonl.zst", bytes: 4096)

        let auditor = AuditorFileSystem()
        let scan = try makeScanner(auditor).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(
            report.category(.protected)?.occupancy,
            Occupancy(bytes: 164 * 100 + 900, fileCount: 165),
            "技能 + 凭证都要算进受保护；凭证靠内置清单判定，不靠规则声明"
        )
        XCTAssertEqual(
            report.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 4096, fileCount: 1),
            "受保护的那一堆绝不许混进可归档"
        )
        XCTAssertEqual(
            report.category(.protected)?.summaries.map(\.subpath).sorted(),
            ["auth.json", "skills"],
            "受保护也按子路径给出明细，界面才能说清「这些地方碰不得」"
        )
        XCTAssertEqual(
            report.category(.protected)?.summaries.first { $0.subpath == "auth.json" }?.provenance,
            .undeclared,
            "规则没声明 auth.json——它是内置清单判出来的，不是规则声明的"
        )

        // 验收 3 / 6：全程零写入。受保护的那些路径尤其不能被碰。
        XCTAssertEqual(auditor.writeAttempts, [], "深扫全程零写入，实际：\n\(auditor.writeSummary)")
    }

    // MARK: - 受保护判定按链接真实目标（PRD §8.2 / §14.5）

    /// `~/.codex/skills → ~/.agents/skills` 形态（PRD §14.5）：
    /// 链接的真实目标是内置清单里的受保护目录，因此
    /// **计进受保护**（界面上要能说「这里有一份技能，碰不得」），
    /// 但**进程不跟着链接跑**——目标在工具根之外，工具根的占用里没有它。
    func test指向受保护技能目录的符号链接计进受保护而不混进工具根占用() throws {
        let fixture = try DeepScanFixture(named: "skills-symlink")
        defer { fixture.remove() }

        // `~/.agents/skills`：内置清单里主目录作用域的受保护目录（home/shared-skills）。
        try fixture.write(".agents/skills/shared.md", bytes: 200)

        let harness = try fixture.tool(
            id: "deepseek-harness",
            displayName: "DeepSeek Harness",
            relativeRoot: harnessRootSuffix,
            classificationJSON: [
                "{\"pattern\": \"sessions/**\", \"category\": \"archivableSession\"}",
            ]
        )
        try fixture.write(harnessRootSuffix + "/sessions/project-a/session.jsonl.zstd", bytes: 512)
        // 真实形状：`~/.codex/skills → ~/.agents/skills`（PRD §14.5）。
        try fixture.makeSymbolicLink(
            harnessRootSuffix + "/skills",
            to: fixture.root.appendingPathComponent(".agents/skills").path
        )

        let recorder = RecordingDiscoveryFileSystem()
        let scan = try makeScanner(recorder).scan(
            tools: [fixture.confirmed(harness)],
            rules: [harness.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)

        // 验收 4 的前半：链接目标的 200 字节算进**受保护**，绝不混进可归档。
        XCTAssertEqual(
            report.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 512, fileCount: 1),
            "受保护的技能一个字节都不许混进可归档"
        )
        XCTAssertEqual(
            report.category(.protected)?.occupancy,
            Occupancy(bytes: 200, fileCount: 1),
            "受保护目标计进受保护：界面上要能如实说「这里有一份技能」"
        )
        XCTAssertEqual(report.category(.protected)?.summaries.map(\.subpath), ["skills"])
        XCTAssertEqual(
            report.category(.protected)?.summaries.first?.protectionReason,
            "home/shared-skills",
            "说明它是内置清单判出来的，而不是规则声明的"
        )

        // 验收 4 的后半：链接本身被记下来，并标明它指向工具根之外。
        XCTAssertEqual(report.unfollowedLinks.map(\.relativePath), ["skills"])
        XCTAssertEqual(report.unfollowedLinks.first?.isInsideToolRoot, false)

        // 关键：没有「跟着链接跑」——目标里只读了一层（枚举 + 逐个 stat），
        // 没有继续向更深处递归，也没有把目标当成工具根的一部分去遍历。
        let listedTarget = fixture.root.appendingPathComponent(".agents/skills").path
        XCTAssertEqual(
            recorder.accesses.filter { if case .listed = $0 { return true } else { return false } }
                .map(\.path)
                .filter { $0.hasPrefix(fixture.rootPath + "/.agents") },
            [listedTarget],
            "受保护目标只该被列举一层。实际：\n\(recorder.summary)"
        )
    }

    // MARK: - 规则没声明、但真实目标受保护

    func test规则未声明而真实目标落在受保护目录之下的路径算受保护() throws {
        let fixture = try DeepScanFixture(named: "protected-real-target")
        defer { fixture.remove() }

        // `~/.agents/skills`（主目录作用域的受保护目录，内置条目 home/shared-skills）。
        try fixture.write(".agents/skills/shared.md", bytes: 300)
        try fixture.write(harnessRootSuffix + "/sessions/session.jsonl.zstd", bytes: 8)

        let harness = try fixture.tool(
            id: "deepseek-harness",
            displayName: "DeepSeek Harness",
            relativeRoot: harnessRootSuffix,
            classificationJSON: []
        )
        // 工具根下一个规则**没有**声明的目录，真实目标是 `~/.agents/skills`。
        try fixture.makeSymbolicLink(
            harnessRootSuffix + "/mystery",
            to: fixture.root.appendingPathComponent(".agents/skills").path
        )

        let scan = try makeScanner(RecordingDiscoveryFileSystem()).scan(
            tools: [fixture.confirmed(harness)],
            rules: [harness.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(
            report.category(.protected)?.occupancy,
            Occupancy(bytes: 300, fileCount: 1),
            "真实目标落在受保护目录之下 → 受保护（PRD §8.2 的同一条纪律）"
        )
        XCTAssertEqual(report.category(.protected)?.summaries.map(\.subpath), ["mystery"])
        XCTAssertEqual(
            report.category(.uncertain)?.summaries.map(\.subpath),
            ["sessions"],
            "sessions 没被任何声明覆盖 → 不确定，不许因为规则没写就悄悄算成可归档"
        )
    }

    // MARK: - 指向工具根之外、又不受保护的链接：一个字节都不读

    func test指向工具根之外且不受保护的符号链接既不计占用也不被遍历() throws {
        let fixture = try DeepScanFixture(named: "external-link")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: "codex",
            classificationJSON: [
                "{\"pattern\": \"sessions/**\", \"category\": \"archivableSession\"}",
            ]
        )
        try fixture.write("codex/sessions/rollout-1.jsonl", bytes: 64)
        // 用户自己的媒体库：在工具根之外，也不受任何内置条目保护。
        try fixture.write("movies/巨大的视频.bin", bytes: 100_000)
        try fixture.makeSymbolicLink(
            "codex/sessions/movies",
            to: fixture.root.appendingPathComponent("movies").path
        )

        let recorder = RecordingDiscoveryFileSystem()
        let scan = try makeScanner(recorder).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        let report = try XCTUnwrap(scan.toolReports.first)
        XCTAssertEqual(
            report.occupancy,
            Occupancy(bytes: 64, fileCount: 1),
            "100000 字节是链接目标的，不属于这台工具（PRD §8.2：指向外部目录的链接一律拒绝处理）"
        )
        XCTAssertEqual(report.unfollowedLinks.map(\.relativePath), ["sessions/movies"])
        XCTAssertEqual(report.unfollowedLinks.first?.isInsideToolRoot, false)
        XCTAssertEqual(
            recorder.touched(underOrEqual: fixture.rootPath + "/movies"),
            [],
            "不受保护的外部链接目标一次都不该被访问：\n\(recorder.summary)"
        )
    }

    // MARK: - 受保护判定不去列举主目录（issue #19 的纪律在深扫里继续成立）

    func test受保护判定不列举主目录也不越过工具根() throws {
        let fixture = try DeepScanFixture(named: "protected-no-home-listing")
        defer { fixture.remove() }

        let codex = try fixture.tool(
            id: "codex-cli",
            displayName: "Codex CLI",
            relativeRoot: "codex",
            classificationJSON: [
                "{\"pattern\": \"sessions/**\", \"category\": \"archivableSession\"}",
            ]
        )
        try fixture.write("codex/sessions/rollout-1.jsonl", bytes: 16)
        // 夹具根下摆一个会诱使判定去列举它的位置。
        try fixture.write(".agents/skills/shared.md", bytes: 32)

        let recorder = RecordingDiscoveryFileSystem()
        let scan = try makeScanner(recorder).scan(
            tools: [fixture.confirmed(codex)],
            rules: [codex.rule],
            homeDirectory: fixture.rootPath
        )

        XCTAssertEqual(scan.totalOccupancy, Occupancy(bytes: 16, fileCount: 1))
        XCTAssertFalse(
            recorder.accesses.contains(.listed(fixture.rootPath)),
            "受保护判定不得列举主目录（issue #19）：实际访问\n\(recorder.summary)"
        )
        XCTAssertEqual(
            recorder.touched(underOrEqual: fixture.rootPath + "/.agents"),
            [],
            "`~/.agents/skills` 不在工具根内：深扫不该碰它"
        )
    }
}
