import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #18：浅扫口径改为**规则驱动**，安装检测作为发现入口。
///
/// 这一组用例只断言**外部可观察行为**，但多了一样前几组没有的东西：
/// 用 `RecordingDiscoveryFileSystem` 把「访问了哪些路径」也变成可观察的。
/// 候选列表只能证明「没有多报」，证明不了「没有多看」——而这次要换掉的正是
/// 「多看」那一半。
final class RuleDrivenScanTests: XCTestCase {

    // MARK: - 旧扫描位（PRD §4.2 改造前的那份通用清单）

    /// 改造前的通用扫描位置里，**与任何已知 AI 工具无关**的那几个。
    ///
    /// 刻意不含 `~/Library/Application Support` 与 `~/.local/share`：
    /// DeepSeek Harness 的工具根与 OpenCode 的数据根就住在那里（PRD §14.5、§5.4）。
    private static let irrelevantOldScanLocations = [
        "Library/Containers",
        "Library/Caches",
        "Library/Logs",
        "Library/Group Containers",
        ".cache",
        ".config",
    ]

    // MARK: - 验收 1：不再枚举通用位置

    /// **验收 1**：一个塞满无关目录的假主目录，跑一次发现，这些目录**一个都没有被访问**。
    ///
    /// 旧口径下 `ScanRoot.standard` 会把上面六个位置逐个列举一遍（本机实测合计约 1,400 个
    /// 一级目录，`~/Library/Containers` 一处就 728 个），而这层枚举几乎不产生任何候选——
    /// 准入要求「命中规则声明的工具根」，那些目录本来就没有规则声明它们。
    func test塞满无关目录的假主目录里那些无关目录一个都没有被访问() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        try seedNoise(in: fixture, perLocation: 60)
        try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-18/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")

        let recorder = RecordingDiscoveryFileSystem()
        let result = ToolDiscoverer(
            rules: try admittedBundledRules(),
            fileSystem: recorder,
            homeDirectory: fixture.homePath
        ).discover()

        // 候选该有的仍然有。
        XCTAssertEqual(
            result.candidates.map(\.displayPath), ["~/.claude"],
            "规则声明的工具根照常被发现：\(result.candidates.map(\.displayPath))"
        )

        // 关键断言：那六个位置**连目录本身都没有被列举过**。
        for location in Self.irrelevantOldScanLocations {
            let path = fixture.homePath + "/" + location
            XCTAssertEqual(
                recorder.touched(underOrEqual: path), [],
                "\(location) 下没有任何规则声明的工具根，一次发现就不该碰它。实际访问：\n\(recorder.summary)"
            )
        }

        // 主目录本身也不再被列举（旧的隐藏目录扫描位）。
        XCTAssertFalse(
            recorder.accesses.contains(.listed(fixture.homePath)),
            "主目录不是扫描位：浅扫由规则驱动，不是把 `~` 列一遍。实际访问：\n\(recorder.summary)"
        )
    }

    // MARK: - 验收 5：访问次数与声明的工具根数量成正比

    /// **验收 5**：一次发现对文件系统的访问次数，与规则声明的工具根数量成正比——
    /// 与磁盘上无关目录的数量**无关**。
    ///
    /// 证明方式是把这句话做成一次对照：两棵假主目录树，除了「有没有那 360 个无关目录」
    /// 之外完全一样，跑两次发现，两次的访问记录必须**逐条相同**。
    /// 旧口径下这两次的访问量会差出 360 次以上——那正是要换掉的行为。
    func test访问次数与无关目录的数量无关只与声明的工具根成正比() throws {
        struct Run {
            let accesses: [RecordingDiscoveryFileSystem.Access]
            let summary: String
        }

        func record(noisePerLocation: Int) throws -> Run {
            let fixture = try DiscoveryFixture(named: "drive-\(noisePerLocation)")
            defer { fixture.home.remove() }

            try seedNoise(in: fixture, perLocation: noisePerLocation)
            try fixture.makeFile(".claude/projects/-Users-xiaowei-amc-wt-18/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl")
            try fixture.makeFile(
                ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                    + "1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl",
                contents: ""
            )

            let recorder = RecordingDiscoveryFileSystem()
            let result = ToolDiscoverer(
                rules: try admittedBundledRules(),
                fileSystem: recorder,
                homeDirectory: fixture.homePath
            ).discover()
            XCTAssertEqual(result.candidates.count, 2, "对照两次跑的候选应当相同")
            return Run(
                accesses: recorder.abbreviating(fixture.homePath),
                summary: recorder.summary.replacingOccurrences(of: fixture.homePath, with: "~")
            )
        }

        let clean = try record(noisePerLocation: 0)
        let noisy = try record(noisePerLocation: 60)

        XCTAssertFalse(clean.accesses.isEmpty, "对照本身必须真的访问过磁盘，否则这条断言没有意义")
        XCTAssertEqual(
            noisy.accesses.count, clean.accesses.count,
            "多了 \(6 * 60) 个无关目录不该多出任何一次访问。"
                + "干净树 \(clean.accesses.count) 次：\n\(clean.summary)；"
                + "噪声树 \(noisy.accesses.count) 次：\n\(noisy.summary)"
        )
        XCTAssertEqual(
            noisy.accesses, clean.accesses,
            "两次的访问必须逐条相同，而不只是次数相同。噪声树：\n\(noisy.summary)"
        )
    }

    /// **验收 5（换个说法）**：被列举的目录一定落在某条规则声明的工具根之内。
    ///
    /// 这条比任何数字上界都硬：它说的是「浅扫的下潜范围」本身，
    /// 而不是「大概只下了几层」。
    func test被列举的目录一定落在规则声明的工具根之内() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        try seedNoise(in: fixture, perLocation: 10)
        try fixture.makeFile(
            "Library/Application Support/deepseek-harness-desktop/harness-home"
                + "/sessions/--Users-xiaowei-work-amc-wt-18--/session-9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f"
                + "/session.jsonl.zstd",
            contents: ""
        )
        try fixture.makeFile(
            ".local/share/opencode/storage/-Users-xiaowei-amc-wt-18/session/message/"
                + "1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.json"
        )

        let recorder = RecordingDiscoveryFileSystem()
        let result = ToolDiscoverer(
            rules: try admittedBundledRules(),
            fileSystem: recorder,
            homeDirectory: fixture.homePath
        ).discover()

        XCTAssertEqual(
            Set(result.candidates.map { $0.ruleIdentifier ?? "" }),
            ["deepseek-harness", "opencode"],
            "孙子目录里的 Harness 与非标准位置的 OpenCode 照常被发现"
        )

        let toolRoots = try declaredToolRootPaths(homeDirectory: fixture.homePath)
        for directory in recorder.listedDirectories {
            XCTAssertTrue(
                toolRoots.contains { directory == $0 || directory.hasPrefix($0 + "/") },
                "\(directory) 不在任何规则声明的工具根之内，不该被列举。列举记录：\n\(recorder.summary)"
            )
        }
    }

    // MARK: - 验收 4：未安装工具的数据不被漏掉

    /// **验收 4**：完全没有安装证据的工具，其工具根若存在且命中结构指纹，仍然进候选。
    ///
    /// 「装了就给高，卸载了但数据还在仍应被发现，只是拿不到安装佐证」
    /// ——这一条锁住的是**保守的那一半**：安装检测是入口与排序依据，不是硬过滤器。
    /// 卸载了工具、磁盘上会话还在，正是这个产品最该帮用户发现的场景。
    func test没有任何安装证据的工具其数据目录仍然进候选() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.home.remove() }

        // 会话文件开头不带规则声明的字段特征（`fileHeaderKeys`），因此这一档
        // 只可能被**安装检测**撑起来——它缺席，就该停在「中」。
        try fixture.makeFile(
            ".claude/projects/-Users-xiaowei-amc-wt-18/9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl",
            contents: "{\"note\":\"没有规则声明的字段特征\"}\n"
        )

        // 没有任何安装来源：外部佐证一律为空。
        let result = ToolDiscoverer(
            rules: try admittedBundledRules(),
            externalEvidence: .none,
            homeDirectory: fixture.homePath
        ).discover()

        let candidate = try XCTUnwrap(
            result.candidates.first,
            "卸载了工具但数据还在时，候选必须仍然出现：\(result.candidates.map(\.displayPath))"
        )
        XCTAssertEqual(candidate.displayPath, "~/.claude")
        XCTAssertEqual(
            candidate.confidence, .medium,
            "拿不到安装佐证时停在「中」，而不是被踢出候选列表"
        )
    }

    // MARK: - 辅助

    /// 在旧扫描位上铺 `perLocation` 个无关目录，每个都放一个文件，看起来像个真的应用容器。
    private func seedNoise(in fixture: DiscoveryFixture, perLocation: Int) throws {
        for location in Self.irrelevantOldScanLocations {
            for index in 0..<perLocation {
                try fixture.makeFile(
                    "\(location)/com.example.vendor\(index)/Library/Caches/blob-\(index).bin",
                    contents: "无关数据"
                )
            }
        }
    }

    /// 内置规则声明的全部工具根绝对路径（只认 `role == toolRoot`）。
    private func declaredToolRootPaths(homeDirectory: String) throws -> [String] {
        let directory = try XCTUnwrap(BuiltInRuleResources.directory, "内置规则应当是 bundle 资源。")
        let load = RuleLoader.loadRules(inDirectory: directory)
        XCTAssertEqual(load.diagnostics.map(\.errorDescription), [], "内置规则必须全部读得进来。")

        let prefix = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        var seen: Set<String> = []
        return load.rules.flatMap(\.roots).compactMap { root -> String? in
            guard root.role == .toolRoot else { return nil }
            let path = root.path.hasPrefix("~/") ? prefix + String(root.path.dropFirst(1)) : root.path
            return seen.insert(path).inserted ? path : nil
        }
    }
}
