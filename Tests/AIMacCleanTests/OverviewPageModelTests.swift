import XCTest

import AIMacCleanDomain
import AIMacCleanRules
import AIMacCleanUI

/// Seam：概览页视图模型（issue #28；PRD §9、§14.1）。
///
/// 注入固定的深扫报告与固定容量，断言界面上要摆出来的**全部文案与数字**。
/// 数字的期望值来自手算的字面量（1 MB = 1_048_576 字节等），不是拿被测代码重算。
final class OverviewPageModelTests: XCTestCase {

    // MARK: - 夹具

    /// 常规两台工具：Claude Code 1.5 MB（可归档 1 MB），Cursor 768 KB（可归档 0，
    /// 其中 512 KB 来自只展示、绝不归档的根）。
    private func makeModel(
        capacity: VolumeCapacity = .measured(availableBytes: 137_438_953_472, totalBytes: 1_099_511_627_776)
    ) throws -> (model: OverviewPageModel, scanner: StubOccupancyScanner, fixture: OverviewPageFixture) {
        let fixture = try OverviewPageFixture(named: "overview-model")
        try fixture.confirm(id: "claude-code", root: fixture.toolRoot(".claude"))
        try fixture.confirm(id: "cursor", root: fixture.toolRoot(".cursor"))

        let report = OverviewFixture.report([
            OverviewFixture.toolReport(
                id: "claude-code",
                displayName: "Claude Code",
                toolRootPath: fixture.toolRoot(".claude"),
                bytes: [.archivableSession: 1_048_576, .protected: 524_288],
                fileCounts: [.archivableSession: 2, .protected: 1]
            ),
            OverviewFixture.toolReport(
                id: "cursor",
                displayName: "Cursor",
                toolRootPath: fixture.toolRoot(".cursor"),
                bytes: [.cacheAndLog: 262_144],
                fileCounts: [.cacheAndLog: 1],
                displayOnlyBytes: 524_288,
                displayOnlyFileCount: 1
            ),
        ])

        let scanner = StubOccupancyScanner(report: report)
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: scanner,
            capacityReader: StubCapacityReader(reading: capacity),
            homeDirectory: fixture.homePath,
            scheduler: .immediate
        )
        model.load()
        return (model, scanner, fixture)
    }

    private func makeEmptyModel(
        capacity: VolumeCapacity = .measured(availableBytes: 137_438_953_472, totalBytes: 1_099_511_627_776)
    ) throws -> (model: OverviewPageModel, fixture: OverviewPageFixture) {
        let fixture = try OverviewPageFixture(named: "overview-empty")
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: StubOccupancyScanner(report: OverviewFixture.report([])),
            capacityReader: StubCapacityReader(reading: capacity),
            homeDirectory: fixture.homePath,
            scheduler: .immediate
        )
        model.load()
        return (model, fixture)
    }

    // MARK: - 验收 1：总占用、四类分列、各工具占用

    func test总占用等于各工具之和() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        // 手算：1.5 MB + 768 KB = 2.25 MB；文件数 3 + 2 = 5。
        XCTAssertEqual(model.totalText, "总占用：2.3 MB（5 个文件）")
        XCTAssertEqual(model.totalAccessibilityText, "总占用 2.3 MB，共 5 个文件")
    }

    func test可归档占比是全体可归档除以全体占用() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        // 手算：1 MB / 2.25 MB = 44.44%。
        XCTAssertEqual(model.archivableShareText, "可归档占比：44.44%（1 MB）")
    }

    func test四类分列齐全且逐类给出占用() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        let rows = model.categoryRows
        XCTAssertEqual(rows.map(\.title), ["可归档会话", "缓存与日志", "受保护", "不确定"])
        XCTAssertEqual(rows.map(\.handling), ["支持归档", "只展示大小，不动", "永不触碰，仅展示", "锁定，仅展示大小"])
        XCTAssertEqual(rows.map(\.occupancyText), [
            "1 MB（2 个文件）",
            "256 KB（1 个文件）",
            "512 KB（1 个文件）",
            "512 KB（1 个文件）",
        ])
        XCTAssertEqual(rows.first?.accessibilityLabel, "可归档会话：1 MB（2 个文件），支持归档")
    }

    func test各工具占用按体积从大到小排列() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        XCTAssertEqual(model.toolRows.map(\.displayName), ["Claude Code", "Cursor"])
        XCTAssertEqual(model.toolRows.map(\.displayPath), ["~/.claude", "~/.cursor"])
        XCTAssertEqual(model.toolRows[0].occupancyText, "1.5 MB（3 个文件）")
        XCTAssertEqual(model.toolRows[1].occupancyText, "768 KB（2 个文件）")
    }

    func test各工具给出可归档占用与占比() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        XCTAssertEqual(model.toolRows[0].archivableText, "可归档 1 MB（66.67%）")
        XCTAssertEqual(model.toolRows[1].archivableText, "可归档 0 B（0%）")
    }

    func test仅展示根如实分列且不进可归档() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        XCTAssertNil(model.toolRows[0].displayOnlyText, "Claude Code 没有仅展示根")
        XCTAssertEqual(model.toolRows[1].displayOnlyText, "其中仅展示（不参与归档）：512 KB")
        XCTAssertEqual(
            model.toolRows[1].archivableText,
            "可归档 0 B（0%）",
            "仅展示根一个字节都不算可归档（PRD §2.3、§14.1）"
        )
    }

    func test辅助功能读得出数字与类别() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        XCTAssertEqual(
            model.toolRows[0].accessibilityLabel,
            "Claude Code，路径 ~/.claude，占用 1.5 MB（3 个文件），可归档 1 MB，占 66.67%"
        )
    }

    // MARK: - 验收 2：未确认的工具不出现

    func test未确认的工具不参与深扫也不出现在统计里() throws {
        let fixture = try OverviewPageFixture(named: "overview-unconfirmed")
        defer { fixture.remove() }

        try fixture.confirm(id: "claude-code", root: fixture.toolRoot(".claude"))
        let scanner = StubOccupancyScanner { records in
            // 报告严格按收到的记录生成：多扫一台就会多出一行，测试因此抓得住。
            OverviewFixture.report(records.map { record in
                OverviewFixture.toolReport(
                    id: record.toolIdentifier ?? record.toolRootPath,
                    toolRootPath: record.toolRootPath,
                    bytes: [.archivableSession: 1_048_576],
                    fileCounts: [.archivableSession: 1]
                )
            })
        }
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: scanner,
            capacityReader: StubCapacityReader(reading: .measured(availableBytes: 1_000, totalBytes: 2_000)),
            homeDirectory: fixture.homePath,
            scheduler: .immediate
        )

        model.load()

        XCTAssertEqual(
            scanner.receivedRecords.map(\.toolRootPath),
            [fixture.toolRoot(".claude")],
            "深扫入口是已确认工具（PRD §4.1 第 4 步），未确认的候选一个都不许进"
        )
        XCTAssertEqual(model.toolRows.map(\.displayName), ["claude-code"])
        XCTAssertEqual(model.toolRows.count, 1)
    }

    // MARK: - 验收 3：极小占比如实标注

    func test占比极小的工具带上如实标注() throws {
        let fixture = try OverviewPageFixture(named: "overview-negligible")
        defer { fixture.remove() }

        try fixture.confirm(id: "claude-code", root: fixture.toolRoot(".claude"))
        try fixture.confirm(id: "codex-cli", root: fixture.toolRoot(".codex"))

        let model = OverviewPageModel(
            store: fixture.store,
            scanner: StubOccupancyScanner(report: OverviewFixture.report([
                // PRD §14.1 的 Claude Code：可归档 0.15%。
                OverviewFixture.toolReport(
                    id: "claude-code",
                    displayName: "Claude Code",
                    toolRootPath: fixture.toolRoot(".claude"),
                    bytes: [.archivableSession: 15, .cacheAndLog: 9_985],
                    fileCounts: [.archivableSession: 1, .cacheAndLog: 1]
                ),
                // 正常占比：一半可归档。
                OverviewFixture.toolReport(
                    id: "codex-cli",
                    displayName: "Codex CLI",
                    toolRootPath: fixture.toolRoot(".codex"),
                    bytes: [.archivableSession: 1_048_576, .protected: 1_048_576],
                    fileCounts: [.archivableSession: 1, .protected: 1]
                ),
            ])),
            capacityReader: StubCapacityReader(reading: .measured(availableBytes: 1_000, totalBytes: 2_000)),
            homeDirectory: fixture.homePath,
            scheduler: .immediate
        )

        model.load()

        let claude = try XCTUnwrap(model.toolRows.first { $0.displayName == "Claude Code" })
        XCTAssertEqual(claude.archivableText, "可归档 15 B（0.15%）")
        XCTAssertEqual(claude.negligibleAnnotation, "可归档占比极小")
        XCTAssertEqual(claude.accessibilityLabel.contains("可归档占比极小"), true, "辅助技术也要能读出这句实话")

        let codex = try XCTUnwrap(model.toolRows.first { $0.displayName == "Codex CLI" })
        XCTAssertNil(codex.negligibleAnnotation, "正常占比不许被标成极小")
        XCTAssertEqual(codex.archivableText, "可归档 1 MB（50%）")
    }

    // MARK: - 验收 4：主按钮不可用并说明原因

    func test开始归档按钮不可用并给出原因() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        XCTAssertFalse(model.archiveButtonIsEnabled, "归档是 M3：本阶段不许给出一个点了没反应的按钮")
        XCTAssertEqual(model.archiveButtonTitle, "开始归档")
        XCTAssertFalse(model.archiveDisabledReason.isEmpty)
        XCTAssertNotEqual(
            model.archiveDisabledReason,
            L10n.Key.overviewArchiveDisabledReason.rawValue,
            "原因文案必须真的存在，不能把 key 甩给用户"
        )
        XCTAssertTrue(model.archiveDisabledReason.contains("归档"))
        XCTAssertTrue(model.archiveDisabledReason.contains("里程碑"))
    }

    func test归档原因文案中英文都有() {
        let zh = L10n.text(.overviewArchiveDisabledReason, language: .simplifiedChinese)
        let en = L10n.text(.overviewArchiveDisabledReason, language: .english)

        XCTAssertFalse(zh.isEmpty)
        XCTAssertFalse(en.isEmpty)
        XCTAssertNotEqual(en, L10n.Key.overviewArchiveDisabledReason.rawValue)
        XCTAssertNotEqual(zh, en)
    }

    // MARK: - 验收 5：空状态

    func test没有已确认工具时引导去发现与确认页而不是显示0() throws {
        let (model, fixture) = try makeEmptyModel()
        defer { fixture.remove() }

        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(
            model.emptyGuidanceText,
            "还没有确认任何工具。先到「发现与确认」页确认你的 AI 工具，这里才会有可统计的占用。"
        )
        XCTAssertNil(model.totalText, "空状态不许显示误导性的 0")
        XCTAssertNil(model.totalAccessibilityText)
        XCTAssertNil(model.archivableShareText, "更不许显示 100% 这种假占比")
        XCTAssertTrue(model.categoryRows.isEmpty)
        XCTAssertTrue(model.toolRows.isEmpty)
    }

    // MARK: - 验收 7：磁盘剩余空间（含未知）

    func test磁盘剩余空间按读数显示() throws {
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        XCTAssertEqual(model.freeSpaceText, "磁盘剩余空间：128 GB（共 1 TB）")
    }

    func test读不到卷时显示未知而不是0() throws {
        let (model, _, fixture) = try makeModel(capacity: .unknown(.volumeUnreadable))
        defer { fixture.remove() }

        XCTAssertEqual(model.freeSpaceText, "磁盘剩余空间未知：读不到这个卷，这里不显示数字。")
        XCTAssertFalse(model.freeSpaceText?.contains("0 B") == true, "未知绝不许退化成 0（那会被读成盘满了）")
    }

    func test系统没报容量时显示未知而不是0() throws {
        let (model, _, fixture) = try makeModel(capacity: .unknown(.capacityNotReported))
        defer { fixture.remove() }

        XCTAssertEqual(model.freeSpaceText, "磁盘剩余空间未知：系统没有报告这个卷的容量，这里不显示数字。")
        XCTAssertFalse(model.freeSpaceText?.contains("0 B") == true)
    }

    func test真的0剩余空间照常显示0() throws {
        // 0 是合法读数（盘确实满了）：如实显示，不被当成未知。
        let (model, _, fixture) = try makeModel(capacity: .measured(availableBytes: 0, totalBytes: 1_099_511_627_776))
        defer { fixture.remove() }

        XCTAssertEqual(model.freeSpaceText, "磁盘剩余空间：0 B（共 1 TB）")
    }
}
