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

    // MARK: - 验收 2：仅展示根内零个字节可归档

    func test仅展示根内零字节可归档且各按规则落在只展示的三类之一() throws {
        let fixture = try DeepScanFixture(named: "display-only-categories")
        defer { fixture.remove() }

        let cursor = try cursorTool(fixture, classificationJSON: [
            archivable,
            "{\"pattern\": \"Cache/**\", \"category\": \"cacheAndLog\"}",
            "{\"pattern\": \"storages/**\", \"category\": \"protected\"}",
            "{\"pattern\": \"User/**\", \"category\": \"uncertain\"}",
            // 规则（用户可改）把仅展示根里的一条路径声明成可归档：宁可少报，也不许采信。
            "{\"pattern\": \"sessions/**\", \"category\": \"archivableSession\"}",
        ])

        // 主根：正常的可归档会话，不受仅展示根的纪律影响。
        try fixture.write(".cursor/projects/p/a.jsonl", bytes: 1000)

        // 仅展示根（Electron / VSCode 内部存储）：大头 + 缓存 + 受保护 + 未声明。
        let electron = "Library/Application Support/Cursor"
        try fixture.write(electron + "/User/state.bin", bytes: 14_000)
        try fixture.write(electron + "/Cache/blob.bin", bytes: 5000)
        try fixture.write(electron + "/storages/app.bin", bytes: 200)
        try fixture.write(electron + "/sessions/leftover.jsonl", bytes: 700)
        try fixture.write(electron + "/未声明/notes.bin", bytes: 30)

        let report = try XCTUnwrap(
            scan(RecordingDiscoveryFileSystem(), fixture, cursor).toolReport(id: "cursor")
        )

        XCTAssertEqual(
            report.category(.archivableSession)?.occupancy,
            Occupancy(bytes: 1000, fileCount: 1),
            "只有主根里的会话可归档；仅展示根一个字节都不许进来（PRD §2.3、§14.1「Cursor AppSupport 14G、可归档 0」）"
        )
        XCTAssertEqual(
            report.category(.cacheAndLog)?.occupancy,
            Occupancy(bytes: 5000, fileCount: 1),
            "仅展示根内的缓存与日志按规则声明归缓存与日志（只展示、不动）"
        )
        XCTAssertEqual(
            report.category(.protected)?.occupancy,
            Occupancy(bytes: 200, fileCount: 1),
            "规则声明为受保护的部分照旧受保护"
        )
        XCTAssertEqual(
            report.category(.uncertain)?.occupancy,
            Occupancy(bytes: 14_000 + 700 + 30, fileCount: 3),
            "Electron 内部存储归不确定；规则误声明成可归档的那条被压回不确定；未声明的一条也进不确定"
        )
        XCTAssertEqual(
            report.category(.uncertain)?.summaries.map(\.subpath),
            ["User", "sessions", "未声明"],
            "子路径相对**所属根**（仅展示根）给出，字节多的在前"
        )
        XCTAssertEqual(
            report.displayOnlyOccupancy,
            Occupancy(bytes: 14_000 + 5000 + 200 + 700 + 30, fileCount: 5),
            "仅展示根的占用一分不少地进占用，只是一分都不许归档"
        )
        XCTAssertEqual(
            report.occupancy,
            report.toolRootOccupancy + report.displayOnlyOccupancy,
            "总占用 = 主根 + 仅展示根"
        )
    }

    // MARK: - 验收 4：仅展示根缺失时静默跳过

    func test仅展示根缺失时静默跳过且不影响主根() throws {
        let fixture = try DeepScanFixture(named: "display-only-missing")
        defer { fixture.remove() }

        let cursor = try cursorTool(fixture, classificationJSON: [archivable])
        try fixture.write(".cursor/projects/p/a.jsonl", bytes: 1000)
        // 规则声明的仅展示根在这台机器上不存在：没装那个组件，或工具的路径形态变了。
        // 规则命中路径不存在时静默跳过，不得报错（PRD §5.4「规则容忍缺失」）。

        let scan = scan(RecordingDiscoveryFileSystem(), fixture, cursor)
        let report = try XCTUnwrap(scan.toolReport(id: "cursor"))

        XCTAssertEqual(
            report.occupancy,
            Occupancy(bytes: 1000, fileCount: 1),
            "缺失的仅展示根不贡献占用，也一点都不影响主根统计"
        )
        XCTAssertEqual(report.toolRootOccupancy, Occupancy(bytes: 1000, fileCount: 1))
        XCTAssertEqual(report.displayOnlyOccupancy, Occupancy())
        XCTAssertEqual(
            report.roots.map(\.path),
            [cursor.rootPath],
            "缺失的根不是这个工具占用的贡献者，因此不进报告"
        )
        XCTAssertEqual(
            report.unreadable,
            [],
            "缺失不是「读不到」：静默跳过，不往读不到清单里塞一条（PRD §5.4）"
        )
        XCTAssertEqual(report.unfollowedLinks, [])
        XCTAssertEqual(scan.totalOccupancy, Occupancy(bytes: 1000, fileCount: 1))
    }

    // MARK: - 验收 5：访问仍只在规则声明的根内，且全程零写入

    func test访问只落在规则声明的根内且全程零写入() throws {
        let fixture = try DeepScanFixture(named: "display-only-access-range")
        defer { fixture.remove() }

        let cursor = try cursorTool(fixture, classificationJSON: [
            archivable,
            "{\"pattern\": \"User/**\", \"category\": \"uncertain\"}",
        ])
        try fixture.write(".cursor/projects/p/a.jsonl", bytes: 1000)
        try fixture.write("Library/Application Support/Cursor/User/state.bin", bytes: 14_000)

        // 诱饵：既不是主根，也不是规则声明的仅展示根。深扫一个字节都不该碰（issue #18/#19）。
        try fixture.write("诱饵/tool.bin", bytes: 999_999)
        try fixture.write("Library/Application Support/别的应用/x.bin", bytes: 888_888)

        let recorder = RecordingDiscoveryFileSystem()
        let scan = scan(recorder, fixture, cursor)

        let declaredRoots = [cursor.rootPath] + cursor.displayOnlyRootPaths
        let outsideDeclaredRoots = recorder.touchedPaths.filter { path in
            !declaredRoots.contains { root in path == root || path.hasPrefix(root + "/") }
        }
        XCTAssertEqual(
            outsideDeclaredRoots,
            [],
            "访问范围只能落在规则声明的根内：主根 + 规则声明的仅展示根。"
                + "实际碰过的位置：\n\(recorder.summary)"
        )
        XCTAssertEqual(
            scan.totalOccupancy,
            Occupancy(bytes: 15_000, fileCount: 2),
            "诱饵目录既不进占用也不被访问"
        )
        XCTAssertTrue(
            recorder.touched(underOrEqual: fixture.rootPath + "/诱饵").isEmpty,
            "诱饵目录一次都不该被碰"
        )

        // 零写入：`RecordingDiscoveryFileSystem` 的写入口会先记账再真的执行，
        // 因此「记录为空」是「从未试过写」的直接证据，而不是「写失败了」的推断。
        XCTAssertEqual(recorder.writeAttempts, [], "深扫全程零写入：\n\(recorder.writeSummary)")
        XCTAssertEqual(recorder.writeSummary, "零写入（没有任何写尝试）")
    }
}
