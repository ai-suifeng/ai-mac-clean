import Foundation

import AIMacCleanDomain

/// 分类明细页用例的夹具（issue #27）。
///
/// 明细页的验收在**视图模型层**：给一份固定深扫结果，断言界面上的每一行。
/// 因此这里的夹具**不碰磁盘**——它直接拼出 `ToolScanReport`，
/// 形状照抄 PRD §14.1 的 Claude Code 实况（`~/.claude` 277M，其中 247M `plugins/`
/// 与 23M `skills/` 是受保护，可归档仅 404K）。
///
/// 字节数一律取 MiB / KiB 的整数倍：`ByteSizeFormatter` 走 1024 进制，
/// 整数倍的展示文案是稳定字面量（`247 MB`），断言才不用重算一遍格式。
enum ClassificationDetailFixture {

    // MARK: - 尺寸

    static func bytes(_ mib: Int64) -> Int64 { mib * 1024 * 1024 }
    static func kib(_ kib: Int64) -> Int64 { kib * 1024 }

    /// PRD §14.1 的 Claude Code 形状：受保护 97.5%、可归档 404K（0.14%）。
    enum ClaudeCode {
        static let totalBytes = bytes(277)
        static let protectedBytes = bytes(270)   // plugins 247M + skills 23M
        static let archivableBytes = kib(404)
        static let cacheBytes = bytes(6)
        static let uncertainBytes = totalBytes - protectedBytes - archivableBytes - cacheBytes
    }

    // MARK: - 拼装

    static func summary(
        _ subpath: String,
        bytes: Int64,
        files: Int,
        pattern: String? = nil,
        protectionReason: String? = nil,
        provenance: CategoryProvenance = .declaredPath("projects/**")
    ) -> CategorySummary {
        CategorySummary(
            subpath: subpath,
            pattern: pattern,
            protectionReason: protectionReason,
            provenance: provenance,
            occupancy: Occupancy(bytes: bytes, fileCount: files)
        )
    }

    static func category(
        _ category: DataCategory,
        bytes: Int64,
        files: Int,
        holdingDirectories: Int = 1,
        summaries: [CategorySummary] = []
    ) -> CategoryOccupancy {
        CategoryOccupancy(
            category: category,
            occupancy: Occupancy(bytes: bytes, fileCount: files),
            holdingDirectoryCount: holdingDirectories,
            summaries: summaries
        )
    }

    /// 一台工具的深扫报告。
    ///
    /// `occupancy` 与 `roots` 由 `categories` + `displayOnlyRoots` 推出，
    /// 与 `DeepScanner` 的不变式一致（总占用 = 各根之和 = 四类之和）。
    static func report(
        toolID: String = "claude-code",
        displayName: String = "Claude Code",
        toolRootPath: String = "/Users/example/.claude",
        categories: [CategoryOccupancy],
        displayOnlyBytes: Int64? = nil,
        displayOnlyPath: String = "/Users/example/Library/Application Support/Cursor",
        holdingDirectoryCount: Int = 8,
        unreadable: [UnreadableEntry] = [],
        unfollowedLinks: [UnfollowedLink] = []
    ) -> ToolScanReport {
        let toolRoot = Occupancy.sum(categories.map(\.occupancy))
        var roots = [ToolRootOccupancy(path: toolRootPath, role: .toolRoot, occupancy: toolRoot)]
        if let displayOnlyBytes {
            roots.append(
                ToolRootOccupancy(
                    path: displayOnlyPath,
                    role: .displayOnly,
                    occupancy: Occupancy(bytes: displayOnlyBytes, fileCount: 1)
                )
            )
        }
        return ToolScanReport(
            toolID: toolID,
            displayName: displayName,
            toolRootPath: toolRootPath,
            occupancy: Occupancy.sum(roots.map(\.occupancy)),
            categories: categories,
            roots: roots,
            holdingDirectoryCount: holdingDirectoryCount,
            unreadable: unreadable,
            unfollowedLinks: unfollowedLinks
        )
    }

    /// 一台只有「可归档 + 受保护」两类的工具，用来量可归档占比的阈值。
    static func tool(archivableBytes: Int64, protectedBytes: Int64) -> ToolScanReport {
        report(categories: [
            category(.archivableSession, bytes: archivableBytes, files: 1),
            category(.protected, bytes: protectedBytes, files: 1),
        ])
    }

    /// PRD §14.1 的 Claude Code：四类齐全，受保护是大头。
    static func claudeCode() -> ToolScanReport {
        report(categories: [
            category(
                .protected,
                bytes: ClaudeCode.protectedBytes,
                files: 1234,
                holdingDirectories: 6,
                summaries: [
                    summary(
                        "plugins",
                        bytes: bytes(247),
                        files: 1200,
                        protectionReason: "claude-code/plugins",
                        provenance: .declaredPath("plugins/**")
                    ),
                    summary(
                        "skills",
                        bytes: bytes(23),
                        files: 34,
                        protectionReason: "claude-code/skills",
                        provenance: .declaredPath("skills/**")
                    ),
                ]
            ),
            category(
                .archivableSession,
                bytes: ClaudeCode.archivableBytes,
                files: 4,
                holdingDirectories: 1,
                summaries: [
                    summary("projects", bytes: ClaudeCode.archivableBytes, files: 4, pattern: "projects/**")
                ]
            ),
            category(
                .cacheAndLog,
                bytes: ClaudeCode.cacheBytes,
                files: 12,
                summaries: [
                    summary(
                        "shell-snapshots",
                        bytes: ClaudeCode.cacheBytes,
                        files: 12,
                        pattern: "shell-snapshots/**"
                    )
                ]
            ),
            category(
                .uncertain,
                bytes: ClaudeCode.uncertainBytes,
                files: 3,
                summaries: [
                    summary(
                        "未声明",
                        bytes: ClaudeCode.uncertainBytes,
                        files: 3,
                        provenance: .undeclared
                    )
                ]
            ),
        ])
    }
}
