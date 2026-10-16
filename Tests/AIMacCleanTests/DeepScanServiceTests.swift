import XCTest

import AIMacCleanDomain
import AIMacCleanRules

/// issue #28：概览页要的「已确认工具 → 深扫报告」这一层接线（`ConfirmedToolScanning`）。
///
/// 钉住四件事：
/// 1. 确认记录里的工具标识映射到**规则**，展示名用规则里的名字（`Claude Code`），
///    不是路径或 id。
/// 2. **同一个工具标识只扫一次**（#31）：两条记录会让规则声明的仅展示根被算两遍，
///    概览页的总占用因此虚高。
/// 3. 没有规则可依的未知工具照常出现，展示名退化成路径，占用落进「不确定」。
/// 4. `standard()` 真的从内置规则目录加载规则——接线断了的话这里会先红。
final class DeepScanServiceTests: XCTestCase {

    private let harnessRootSuffix = "Library/Application Support/deepseek-harness-desktop/harness-home"

    private func record(
        id: String?,
        root: String,
        decision: ToolDecision = .confirmed
    ) -> ConfirmationRecord {
        ConfirmationRecord(
            toolIdentifier: id,
            toolRootPath: root,
            decision: decision,
            signals: .none,
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func service(
        fixture: DeepScanFixture,
        rules: [ToolRule],
        fileSystem: AuditorFileSystem
    ) -> DeepScanService {
        DeepScanService(
            rules: RuleAdmissionReport(usableRules: rules, rejections: []),
            homeDirectory: fixture.rootPath,
            scanner: DeepScanner(fileSystem: fileSystem)
        )
    }

    // MARK: - 映射

    func test确认记录按规则映射出展示名与占用() throws {
        let fixture = try DeepScanFixture(named: "scan-service")
        defer { fixture.remove() }

        try fixture.write(".claude/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 400)
        try fixture.write(".claude/settings.json", bytes: 64)

        let auditor = AuditorFileSystem()
        let report = service(fixture: fixture, rules: try admittedBundledRules(), fileSystem: auditor)
            .scan([record(id: "claude-code", root: fixture.rootPath + "/.claude")])

        XCTAssertEqual(report.toolReports.map(\.toolID), ["claude-code"])
        let claude = try XCTUnwrap(report.toolReports.first)
        XCTAssertEqual(claude.displayName, "Claude Code", "展示名来自规则，不是 id 也不是路径")
        XCTAssertEqual(claude.toolRootPath, fixture.rootPath + "/.claude")
        XCTAssertEqual(claude.archivableOccupancy, Occupancy(bytes: 400, fileCount: 1))
        XCTAssertEqual(claude.category(.protected)?.occupancy, Occupancy(bytes: 64, fileCount: 1))
        XCTAssertEqual(auditor.writeAttempts, [], "概览读的这条路同样零写入：\n\(auditor.writeSummary)")
    }

    // MARK: - 同一工具标识只扫一次（#31）

    func test同一个工具标识的两条确认记录只产生一份报告() throws {
        let fixture = try DeepScanFixture(named: "scan-service-dedupe")
        defer { fixture.remove() }

        // 主根的会话 + 仅展示根的大块数据（PRD §14.1 的 Cursor 形状）。
        let session = ".cursor/projects/-Users-x-a/agent-transcripts/33333333-3333-3333-3333-333333333333"
        try fixture.write(session + "/44444444-4444-4444-4444-444444444444.jsonl", bytes: 700)
        try fixture.write("Library/Application Support/Cursor/User/blob.bin", bytes: 4_000)

        let declaredRoot = fixture.rootPath + "/.cursor"
        let backupRoot = fixture.rootPath + "/.cursor-backup"
        let report = service(fixture: fixture, rules: try admittedBundledRules(), fileSystem: AuditorFileSystem())
            .scan([
                // 记录顺序刻意把「备份根」放在前面：去重不能靠输入顺序碰运气。
                record(id: "cursor", root: backupRoot),
                record(id: "cursor", root: declaredRoot),
            ])

        XCTAssertEqual(report.toolReports.count, 1, "同一工具标识只该有一份报告")
        let cursor = try XCTUnwrap(report.toolReports.first)
        XCTAssertEqual(cursor.toolRootPath, declaredRoot, "规则声明的工具根优先于其它同 id 的记录")
        XCTAssertEqual(
            cursor.displayOnlyOccupancy,
            Occupancy(bytes: 4_000, fileCount: 1),
            "仅展示根只算一次：重复报告会把这块算两遍，总占用因此虚高"
        )
    }

    func test两条都不是声明根时只保留字典序最小的一条() throws {
        let fixture = try DeepScanFixture(named: "scan-service-dedupe-fallback")
        defer { fixture.remove() }

        try fixture.write(".claude-b/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 10)
        try fixture.write(".claude-a/projects/-Users-x-a/22222222-2222-2222-2222-222222222222.jsonl", bytes: 20)

        let report = service(fixture: fixture, rules: try admittedBundledRules(), fileSystem: AuditorFileSystem())
            .scan([
                record(id: "claude-code", root: fixture.rootPath + "/.claude-b"),
                record(id: "claude-code", root: fixture.rootPath + "/.claude-a"),
            ])

        XCTAssertEqual(report.toolReports.map(\.toolRootPath), [fixture.rootPath + "/.claude-a"])
    }

    // MARK: - 未知工具

    func test未知工具按路径落进不确定且不匹配任何规则() throws {
        let fixture = try DeepScanFixture(named: "scan-service-unknown")
        defer { fixture.remove() }

        try fixture.write(".mystery/sessions/2026/10/14/rollout-2026-10-14T10-00-00.jsonl", bytes: 100)

        let report = service(fixture: fixture, rules: try admittedBundledRules(), fileSystem: AuditorFileSystem())
            .scan([record(id: nil, root: fixture.rootPath + "/.mystery")])

        let mystery = try XCTUnwrap(report.toolReports.first)
        XCTAssertEqual(mystery.toolRootPath, fixture.rootPath + "/.mystery")
        XCTAssertEqual(mystery.displayName, "~/.mystery", "未知工具没有规则名，展示路径")
        XCTAssertEqual(mystery.occupancy.bytes, 100)
        XCTAssertEqual(
            mystery.categoryLines.map(\.occupancy.bytes),
            [0, 0, 0, 100],
            "规则一条都没声明到它：全部落进不确定，绝不默认算可归档"
        )
    }

    // MARK: - 生产接线

    func test标准接线从内置规则目录加载规则() throws {
        let fixture = try DeepScanFixture(named: "scan-service-standard")
        defer { fixture.remove() }

        try fixture.write(harnessRootSuffix + "/sessions/--Users-x-a--/session-66666666-6666-6666-6666-666666666666/session.jsonl.zstd", bytes: 150)

        let standard = DeepScanService.standard(
            homeDirectory: fixture.rootPath,
            ruleDirectory: BuiltInRuleResources.directory,
            fileSystem: AuditorFileSystem()
        )
        let report = standard.scan([
            record(id: "deepseek-harness", root: fixture.rootPath + "/" + harnessRootSuffix),
        ])

        XCTAssertEqual(report.toolReports.first?.displayName, "DeepSeek Harness")
        XCTAssertEqual(report.archivableOccupancy, Occupancy(bytes: 150, fileCount: 1))
    }
}
