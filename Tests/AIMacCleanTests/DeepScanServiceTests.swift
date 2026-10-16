import Foundation
import XCTest

import AIMacCleanDomain
import AIMacCleanRules

/// Seam：深扫的**接线**（issue #27 与 #28 共用的 `DeepScanService`）。
///
/// `DeepScanner` 只管「给定已确认工具与规则，算出占用」；「已确认工具从哪来、规则从哪来」
/// 是这一层的事。两条入口（分类明细页的 `run()`、概览页的 `scan(_:)`）共用同一段核心，
/// 因此这里的用例同时钉住两条路：
///
/// 1. **同一台工具只扫一次**：确认存储以工具根路径为键，但规则标识才是「一台工具」。
///    同一条规则被确认出两条记录时必须去重——否则规则声明的**仅展示根**（issue #31 的
///    Cursor AppSupport 14G）会被算两遍，占用直接翻倍。
/// 2. 去重后的顺序**不随存储的遍历顺序变**（结果必须是确定的）；
///    有规则可依时按「规则声明的工具根优先」，没有声明根时按路径字典序兜底。
/// 3. 没有可用规则时 `run()` 给出问题，**不返回 0 B 的假占用**（那会让用户以为工具是空的）；
///    而 `scan(_:)` 照常给出报告——概览页不该因为规则资源缺失就整页报错。
/// 4. 确认记录里的工具标识映射到**规则**，展示名用规则里的名字（`Claude Code`），
///    不是路径或 id；没有规则可依的未知工具照常出现，展示名退化成路径。
/// 5. `standard()` 真的从内置规则目录加载规则——接线断了的话这里会先红。
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

    // MARK: - 去重（issue #27 的 `ConfirmedTool.normalized`）

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

    // MARK: - 端到端：同一台工具被确认两次，占用不得翻倍（issue #27 的 `run()`）

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

    // MARK: - 没有可用规则时不假装工具有多小（issue #27 的 `run()`）

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

    // MARK: - 映射（issue #28 的 `scan(_:)`）

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

    // MARK: - 概览页入口没有确认存储（review 发现 7）

    /// 概览页入口只注入**已准入的规则**：它的确认记录由调用方逐条传给 `scan(_:)`。
    /// 这里不再用一个「恒为空、被问就抛错」的假存储占位——`run()` 在没有存储时
    /// 如实给出「没有记录」的空报告，而不是假装有一个存储。
    func test概览页入口没有确认存储时run如实给出空报告() throws {
        let rules = RuleSetAdmission.admit(rules: try admittedBundledRules(), homeDirectory: NSTemporaryDirectory())
        let service = DeepScanService(rules: rules, homeDirectory: NSTemporaryDirectory())

        let run = service.run()

        XCTAssertEqual(run.issues, [], "规则可用：不该报「没有规则」")
        XCTAssertTrue(
            run.report.toolReports.isEmpty,
            "没有确认记录就没有工具：不许凭空造出一台，也不许抛出「存储不可读」"
        )
        // 概览页真正用到的入口照常工作：记录由调用方逐条传入，不经过任何存储。
        XCTAssertEqual(
            service.confirmedTools(from: [record(id: "claude-code", root: "/tmp/nowhere/.claude")]).map(\.id),
            ["claude-code"]
        )
    }

    // MARK: - 概览页的运行级问题通道（ticket #32）

    /// 记录「有没有被叫去扫」。取问题的路上**一次扫描都不许发生**。
    private final class ScanCountingScanner: DeepScanning {

        private(set) var scanCount = 0

        func scan(tools: [ConfirmedTool], rules: RuleAdmissionReport, homeDirectory: String) -> DeepScanReport {
            scanCount += 1
            return DeepScanReport(toolReports: [])
        }

        func scan(tools: [ConfirmedTool], rules: [ToolRule], homeDirectory: String) -> DeepScanReport {
            scanCount += 1
            return DeepScanReport(toolReports: [])
        }
    }

    private func emptyStore(
        named name: String
    ) throws -> (store: JSONConfirmationStore, fixture: TemporaryDirectoryFixture) {
        let directory = try TemporaryDirectoryFixture(named: name)
        return (JSONConfirmationStore(applicationSupportRoot: directory.url), directory)
    }

    /// 规则资源没打进包时，概览页要能拿到「没有加载到规则」这条事实——**而不必先扫一遍**。
    ///
    /// `run()` 在规则可用时会跑一次完整深扫：只为了拿问题而调它，等于每次打开概览页
    /// 都把这棵 31G / 数万文件的树扫两遍（概览页要的是报告，报告走 `scan(_:)`）。
    func test规则目录缺失时只取问题不扫盘() throws {
        let fixture = try DeepScanFixture(named: "deep-scan-service-issues-no-rules")
        defer { fixture.remove() }
        let (store, storeDirectory) = try emptyStore(named: "deep-scan-service-issues-no-rules-store")
        defer { storeDirectory.remove() }

        let scanner = ScanCountingScanner()
        let service = DeepScanService(
            configuration: .init(homeDirectory: fixture.rootPath, ruleDirectory: nil),
            store: store,
            scanner: scanner
        )

        XCTAssertEqual(service.issues(), [.noRulesLoaded])
        XCTAssertEqual(scanner.scanCount, 0, "问问题不该扫盘：扫描是另一条入口（scan(_:)）的事")
    }

    /// 规则读到了、但一条都没过准入：给的是「几条被拒」，与「一条都没读到」分开。
    func test规则全部被拒时只取问题并给出被拒条数() throws {
        let fixture = try DeepScanFixture(named: "deep-scan-service-issues-rejected")
        defer { fixture.remove() }
        let (store, storeDirectory) = try emptyStore(named: "deep-scan-service-issues-rejected-store")
        defer { storeDirectory.remove() }

        let ruleDirectory = try fixture.makeDirectory("rules")
        try Data(RuleFixtures.downgradedClaudeCodeJSON.utf8)
            .write(to: ruleDirectory.appendingPathComponent("claude-code.json"))
        try fixture.write(".claude/projects/-Users-x-a/11111111-1111-1111-1111-111111111111.jsonl", bytes: 400)

        let scanner = ScanCountingScanner()
        let service = DeepScanService(
            configuration: .init(homeDirectory: fixture.rootPath, ruleDirectory: ruleDirectory),
            store: store,
            scanner: scanner
        )

        XCTAssertEqual(service.issues(), [.noUsableRules(rejectedCount: 1)])
        XCTAssertEqual(scanner.scanCount, 0, "没有可用规则时更没有理由扫盘")

        // 报告入口照常工作：摆不摆数字由运行级问题决定，不由报告空不空决定。
        _ = service.scan([record(id: "claude-code", root: fixture.rootPath + "/.claude")])
        XCTAssertEqual(scanner.scanCount, 1, "scan(_:) 仍是一条独立的入口")
    }

    /// 规则可用时问题列表为空——「没有问题」与「没问到」必须分得开。
    func test规则可用时只取问题为空且不扫盘() throws {
        let fixture = try DeepScanFixture(named: "deep-scan-service-issues-ok")
        defer { fixture.remove() }
        let (store, storeDirectory) = try emptyStore(named: "deep-scan-service-issues-ok-store")
        defer { storeDirectory.remove() }

        let scanner = ScanCountingScanner()
        let service = DeepScanService(
            configuration: .init(homeDirectory: fixture.rootPath, ruleDirectory: BuiltInRuleResources.directory),
            store: store,
            scanner: scanner
        )

        XCTAssertEqual(service.issues(), [], "内置规则可用：概览页照常展示占用")
        XCTAssertEqual(scanner.scanCount, 0)
    }
}
