import Foundation
import XCTest

import AIMacCleanDomain
import AIMacCleanRules

/// issue #19 验收 1（本票的核心证据）：**一次发现的全部磁盘访问都落在规则声明的位置上**。
///
/// 允许的只有两类：
/// (a) 规则声明的**工具根**（以及它内部的路径）；
/// (b) 规则声明的**安装路径**本身。
///
/// 别的一律不允许——特别是 `/Applications`、`~/Applications`、PATH 的任何目录与主目录本身
/// **从未被列举**（`listed`）。这是用户两次反馈的那个缺陷的正面证明：
/// 候选列表只能证明「没有多报」，访问记录才能证明「没有多看」。
final class DeclaredPathOnlyTests: XCTestCase {

    /// 旧扫描位里与任何已知 AI 工具无关的那几个（PRD §4.2 改造前那份通用清单）。
    ///
    /// 刻意不含 `~/Library/Application Support` 与 `~/.local/share`：
    /// DeepSeek Harness 与 OpenCode 的工具根就住在那里（PRD §14.5、§5.4）。
    private static let irrelevantLocations = [
        "Library/Containers",
        "Library/Caches",
        "Library/Logs",
        "Library/Group Containers",
        ".cache",
        ".config",
    ]

    func test端到端发现的访问记录只有规则声明的工具根与安装路径() throws {
        let fixture = try DiscoveryFixture(named: "declared-path-only")
        defer { fixture.home.remove() }

        // 五个内置工具各留一点实测形状。
        try fixture.makeFile(
            ".claude/projects/-Users-xiaowei-amc-wt-19/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.jsonl"
        )
        try fixture.makeFile(
            ".codex/sessions/2026/10/14/rollout-2026-10-14T09-08-28-"
                + "1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl",
            contents: #"{"type":"session_meta","payload":{}}"# + "\n"
        )
        try fixture.makeFile(
            ".cursor/projects/-Users-xiaowei-amc-wt-19/agent-transcripts/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f/"
                + "1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f.jsonl"
        )
        try fixture.makeFile(
            "Library/Application Support/deepseek-harness-desktop/harness-home/sessions/"
                + "--Users-xiaowei-work-amc-wt-19--/session-9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f/"
                + "session.jsonl.zstd",
            contents: ""
        )
        try fixture.makeFile(
            ".local/share/opencode/storage/-Users-xiaowei-amc-wt-19/session/message/"
                + "9f8b1a52-0f2e-4b1a-9c3d-1a2b3c4d5e6f.json"
        )

        // 通用位置铺满噪声：旧口径会把这些逐个列一遍（本机实测约 1,400 个一级目录）。
        for location in Self.irrelevantLocations {
            for index in 0..<20 {
                try fixture.makeFile(
                    "\(location)/com.example.vendor\(index)/payload/blob-\(index).bin",
                    contents: "无关数据"
                )
            }
        }

        // 生产接线（`standard`）跑一遍。recorder 套在 confiner **外面**：
        // 树外的访问尝试照样被记录，只是回答「不存在」——本机装了什么不影响这条断言。
        let recorder = RecordingDiscoveryFileSystem(
            wrapping: ConfinedDiscoveryFileSystem(confinedTo: fixture.homePath)
        )
        let service = DiscoveryService.standard(
            homeDirectory: fixture.homePath,
            ruleDirectory: try XCTUnwrap(BuiltInRuleResources.directory),
            hintsFileURL: nil,
            fileSystem: recorder
        )
        let run = service.run()

        XCTAssertEqual(run.issues, [])
        XCTAssertEqual(
            Set(run.result.candidates.map { $0.ruleIdentifier ?? "" }),
            ["claude-code", "codex-cli", "cursor", "deepseek-harness", "opencode"],
            "五个内置工具都要被发现：\(run.result.candidates.map(\.displayPath))"
        )

        // 允许的两类位置，直接由规则文件推出。
        let rules = try bundledRules()
        let allowedRoots = Set(
            rules.flatMap(\.roots)
                .filter { $0.role == .toolRoot }
                .map { expand($0.path, homeDirectory: fixture.homePath) }
        )
        let allowedInstallations = Set(
            rules.flatMap(\.installations)
                .map { expand($0.path, homeDirectory: fixture.homePath) }
        )

        XCTAssertFalse(recorder.accesses.isEmpty, "一次发现必须真的访问过磁盘，否则这条断言没有意义")
        for access in recorder.accesses {
            XCTAssertTrue(
                isAllowed(access.path, roots: allowedRoots, installations: allowedInstallations),
                "一次发现访问了规则没有声明的路径：\(access)。全部访问：\n\(recorder.summary)"
            )
        }

        // 特别断言：通用位置、PATH 目录、安装路径的**父目录**与主目录本身从未被列举。
        let forbiddenListings = [
            "/Applications",
            fixture.homePath + "/Applications",
            fixture.homePath,
            fixture.homePath + "/.local",
            fixture.homePath + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] + Self.irrelevantLocations.map { fixture.homePath + "/" + $0 }

        for directory in forbiddenListings {
            XCTAssertFalse(
                recorder.listedDirectories.contains(directory),
                "\(directory) 不是规则声明的工具根，一次发现都不该列举它：\n\(recorder.summary)"
            )
        }
    }

    // MARK: - 辅助

    private func bundledRules() throws -> [ToolRule] {
        let directory = try XCTUnwrap(BuiltInRuleResources.directory, "内置规则应当是 bundle 资源。")
        let load = RuleLoader.loadRules(inDirectory: directory)
        XCTAssertEqual(load.diagnostics.map(\.errorDescription), [], "内置规则必须全部读得进来。")
        return load.rules
    }

    /// 只允许「声明路径本身、它内部、或规则声明的安装路径本身」。
    private func isAllowed(_ path: String, roots: Set<String>, installations: Set<String>) -> Bool {
        if installations.contains(path) { return true }
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// 与 `ToolDiscoverer` 同一套展开口径：`~/…` 相对主目录，其余原样。
    private func expand(_ declared: String, homeDirectory: String) -> String {
        let prefix = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        let expanded = declared.hasPrefix("~/") ? prefix + String(declared.dropFirst(1)) : declared
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }
}
