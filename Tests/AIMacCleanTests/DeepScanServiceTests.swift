import Foundation
import XCTest

import AIMacCleanDomain

/// Seam：深扫的**接线**（issue #27 的入口）。
///
/// `DeepScanner` 只管「给定已确认工具与规则，算出占用」；「已确认工具从哪来、规则从哪来」
/// 是这一层的事。这里钉住三件事：
///
/// 1. **同一台工具只扫一次**：确认存储以工具根路径为键，但规则标识才是「一台工具」。
///    同一条规则被确认出两条记录时必须去重——否则规则声明的**仅展示根**（issue #31 的
///    Cursor AppSupport 14G）会被算两遍，占用直接翻倍。
/// 2. 去重后的顺序**不随存储的遍历顺序变**（结果必须是确定的）。
/// 3. 没有可用规则时给出问题，**不返回 0 B 的假占用**（那会让用户以为工具是空的）。
final class DeepScanServiceTests: XCTestCase {

    // MARK: - 去重

    func test按工具标识去重且结果与输入顺序无关() {
        let normalized = ConfirmedTool.normalized([
            ConfirmedTool(id: "cursor", displayName: "Cursor", toolRootPath: "/Users/example/.cursor-alt"),
            ConfirmedTool(id: "codex", displayName: "Codex", toolRootPath: "/Users/example/.codex"),
            ConfirmedTool(id: "cursor", displayName: "Cursor", toolRootPath: "/Users/example/.cursor"),
        ])

        XCTAssertEqual(normalized.map(\.id), ["codex", "cursor"], "每个工具标识只留一条")
        XCTAssertEqual(
            normalized.map(\.toolRootPath),
            ["/Users/example/.codex", "/Users/example/.cursor"],
            "同一标识有多条记录时取路径字典序最小的那条：不随确认存储的遍历顺序变"
        )
    }

    // MARK: - 端到端：同一台工具被确认两次，占用不得翻倍

    func test同一工具被重复确认时仅展示根不会算两遍() throws {
        let fixture = try DeepScanFixture(named: "deep-scan-service-dedup")
        defer { fixture.remove() }

        let cursor = try fixture.tool(
            id: "cursor",
            displayName: "Cursor",
            relativeRoot: ".cursor",
            displayOnlyRelativeRoots: ["Library/Application Support/Cursor"],
            classificationJSON: [
                "{\"pattern\": \"projects/**\", \"category\": \"archivableSession\"}",
                "{\"pattern\": \"User/**\", \"category\": \"uncertain\"}",
            ]
        )
        try fixture.write(".cursor/projects/p/a.jsonl", bytes: 1000)
        try fixture.write("Library/Application Support/Cursor/User/state.bin", bytes: 14_000)

        // 规则目录：把夹具规则原样落成规则文件。服务从目录加载，与出厂接线同一条路。
        let ruleDirectory = try fixture.makeDirectory("rules")
        try JSONEncoder().encode(cursor.rule).write(to: ruleDirectory.appendingPathComponent("cursor.json"))

        // 同一台工具被确认两次：两条记录、两个工具根路径（存储以路径为键，这是它允许的）。
        let storeDirectory = try TemporaryDirectoryFixture(named: "deep-scan-service-dedup-store")
        let store = JSONConfirmationStore(applicationSupportRoot: storeDirectory.url)
        let decidedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.decide(
            toolIdentifier: "cursor", toolRootPath: cursor.rootPath,
            decision: .confirmed, signals: .none, decidedAt: decidedAt
        )
        try store.decide(
            toolIdentifier: "cursor", toolRootPath: cursor.rootPath + "-alt",
            decision: .confirmed, signals: .none, decidedAt: decidedAt
        )

        let run = DeepScanService(
            configuration: .init(homeDirectory: fixture.rootPath, ruleDirectory: ruleDirectory),
            store: store
        ).run()

        XCTAssertEqual(run.issues, [])
        XCTAssertEqual(run.report.toolReports.map(\.toolID), ["cursor"], "同一台工具只扫一次")
        XCTAssertEqual(
            run.report.totalOccupancy, Occupancy(bytes: 15_000, fileCount: 2),
            "占用是单次扫描的值：仅展示根（14G 这类）被算两遍就是翻倍"
        )
        XCTAssertEqual(
            run.report.toolReport(id: "cursor")?.displayOnlyOccupancy,
            Occupancy(bytes: 14_000, fileCount: 1)
        )
    }

    // MARK: - 没有可用规则时不假装工具有多小

    func test没有可用规则时给出问题且不返回零占用() throws {
        let fixture = try DeepScanFixture(named: "deep-scan-service-no-rules")
        defer { fixture.remove() }

        let storeDirectory = try TemporaryDirectoryFixture(named: "deep-scan-service-no-rules-store")
        let store = JSONConfirmationStore(applicationSupportRoot: storeDirectory.url)
        try store.decide(
            toolIdentifier: "cursor", toolRootPath: fixture.rootPath + "/.cursor",
            decision: .confirmed, signals: .none, decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let run = DeepScanService(
            configuration: .init(homeDirectory: fixture.rootPath, ruleDirectory: nil),
            store: store
        ).run()

        XCTAssertEqual(run.issues, [.noRulesLoaded])
        XCTAssertTrue(
            run.report.toolReports.isEmpty,
            "没有规则就没有可判定的分类：宁可不显示，也不给一排 0 B"
        )
    }
}
