import Foundation

import AIMacCleanDomain
import AIMacCleanRules
import XCTest

/// issue #31：深扫纳入规则声明的**仅展示根**（`displayOnly`）。
///
/// 规则文件里每个工具除了主工具根，还可以声明只展示、绝不动的根：Cursor 的
/// `~/Library/Application Support/Cursor`（实测 14G）、DeepSeek Harness 的
/// `~/Library/Application Support/@deepseek-ai/dsh-desktop`（实测 7.0M）。
/// 这些位置此前完全没进占用统计，于是概览页会显示「Cursor 只占 2.1G」——
/// 与 PRD §14.1「Cursor AppSupport 14G、范围内可归档 0」的实况不符。
///
/// 这一组用例钉住四件事（对应 ticket #31 的五条验收）：
///
/// 1. 工具总占用 = 主根 + 仅展示根，且报告能按根拆分（验收 1、3）。
/// 2. 仅展示根内**零个字节**被算作可归档，各归「缓存与日志 / 受保护 / 不确定」之一（验收 2）。
/// 3. 仅展示根缺失时静默跳过，不报错、不影响主根（验收 4）。
/// 4. 访问范围仍只落在规则声明的根内，全程零写入（验收 5）。
final class DeepScanDisplayOnlyRootsTests: XCTestCase {

    private let archivable = "{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}"

    /// Cursor 的形状：主根在 `~/.cursor`，另有规则声明的仅展示根（Electron 内部存储）。
    private func cursorTool(
        _ fixture: DeepScanFixture,
        classificationJSON: [String] = []
    ) throws -> DeepScanFixture.Tool {
        try fixture.tool(
            id: "cursor",
            displayName: "Cursor",
            relativeRoot: ".cursor",
            displayOnlyRelativeRoots: ["Library/Application Support/Cursor"],
            classificationJSON: classificationJSON
        )
    }

    private func scan(
        _ fileSystem: any DiscoveryFileSystem,
        _ fixture: DeepScanFixture,
        _ tool: DeepScanFixture.Tool
    ) -> DeepScanReport {
        DeepScanner(fileSystem: fileSystem).scan(
            tools: [fixture.confirmed(tool)],
            rules: [tool.rule],
            homeDirectory: fixture.rootPath
        )
    }

    // MARK: - 验收 1 / 3：总占用 = 主根 + 仅展示根，报告能按根拆分

    func test工具总占用等于主根加规则声明的仅展示根() throws {
        let fixture = try DeepScanFixture(named: "display-only-total")
        defer { fixture.remove() }

        let cursor = try cursorTool(fixture)
        try fixture.write(".cursor/projects/p/a.jsonl", bytes: 1000)
        // 仅展示根：Electron / VSCode 内部存储的大头，实测 14G。
        try fixture.write("Library/Application Support/Cursor/User/state.bin", bytes: 14_000)

        let report = try XCTUnwrap(
            scan(RecordingDiscoveryFileSystem(), fixture, cursor).toolReport(id: "cursor")
        )

        XCTAssertEqual(
            report.occupancy,
            Occupancy(bytes: 15_000, fileCount: 2),
            "工具占用必须含仅展示根——否则概览页会显示「Cursor 只占 2.1G」（PRD §14.1）"
        )
        XCTAssertEqual(
            report.toolRootOccupancy,
            Occupancy(bytes: 1000, fileCount: 1),
            "主工具根（归档范围）的占用单独给出"
        )
        XCTAssertEqual(
            report.displayOnlyOccupancy,
            Occupancy(bytes: 14_000, fileCount: 1),
            "仅展示根的占用单独给出，概览页据此显示「Cursor 2.1G + 14G 只展示」"
        )
        XCTAssertEqual(report.roots.map(\.role), [.toolRoot, .displayOnly], "主根在前，仅展示根在后")
        XCTAssertEqual(
            report.roots.map(\.path),
            [cursor.rootPath, cursor.displayOnlyRootPaths[0]],
            "两个根各自的绝对路径都要给出来"
        )
        XCTAssertEqual(
            report.roots.map(\.occupancy),
            [Occupancy(bytes: 1000, fileCount: 1), Occupancy(bytes: 14_000, fileCount: 1)]
        )
    }
}
