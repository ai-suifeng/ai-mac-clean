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
        capacity: VolumeCapacity = .measured(availableBytes: 137_438_953_472, totalBytes: 1_099_511_627_776),
        language: AppLanguage? = nil
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
            issueSource: StubIssueSource(),
            language: language,
            scheduler: .immediate
        )
        model.load()
        return (model, scanner, fixture)
    }

    private func makeEmptyModel(
        capacity: VolumeCapacity = .measured(availableBytes: 137_438_953_472, totalBytes: 1_099_511_627_776)
    ) throws -> (model: OverviewPageModel, fixture: OverviewPageFixture) {
        let (model, _, fixture) = try makeEmptyModelWithIssues([], capacity: capacity)
        return (model, fixture)
    }

    /// 空状态（没有任何已确认工具）+ 可指定的规则状况。
    private func makeEmptyModelWithIssues(
        _ issues: [DeepScanIssue],
        capacity: VolumeCapacity = .measured(availableBytes: 137_438_953_472, totalBytes: 1_099_511_627_776)
    ) throws -> (model: OverviewPageModel, issueSource: StubIssueSource, fixture: OverviewPageFixture) {
        let fixture = try OverviewPageFixture(named: "overview-empty-issues")
        let issueSource = StubIssueSource(issues)
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: StubOccupancyScanner(report: OverviewFixture.report([])),
            capacityReader: StubCapacityReader(reading: capacity),
            homeDirectory: fixture.homePath,
            issueSource: issueSource,
            scheduler: .immediate
        )
        model.load()
        return (model, issueSource, fixture)
    }

    /// 规则没配上时的概览页：一台已确认工具 + 运行级问题。
    ///
    /// 深扫替身刻意给一份**非零**的假报告：真正的纪律是「运行级问题出现时一个占用数字都不摆」，
    /// 而不是「报告恰好是空的」。模型在有问题时根本不该叫深扫（`scanCount == 0`），
    /// 因此这份报告连被使用的机会都没有。
    private func makeIssueModel(
        issues: [DeepScanIssue],
        language: AppLanguage? = nil
    ) throws -> (
        model: OverviewPageModel,
        scanner: StubOccupancyScanner,
        issueSource: StubIssueSource,
        fixture: OverviewPageFixture
    ) {
        let fixture = try OverviewPageFixture(named: "overview-issues")
        try fixture.confirm(id: "claude-code", root: fixture.toolRoot(".claude"))

        let scanner = StubOccupancyScanner(report: OverviewFixture.report([
            OverviewFixture.toolReport(
                id: "claude-code",
                displayName: "Claude Code",
                toolRootPath: fixture.toolRoot(".claude"),
                bytes: [.archivableSession: 10_485_760],
                fileCounts: [.archivableSession: 3]
            ),
        ]))
        let issueSource = StubIssueSource(issues)
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: scanner,
            capacityReader: StubCapacityReader(reading: .measured(availableBytes: 1_024, totalBytes: 2_048)),
            homeDirectory: fixture.homePath,
            issueSource: issueSource,
            language: language,
            scheduler: .immediate
        )
        model.load()
        return (model, scanner, issueSource, fixture)
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

    /// 概览页的四类分列与分类明细页**同源**：类别名与处理方式都取自本地化目录
    /// （`classification.category.*` / `classification.handling.*`），所以英文界面上
    /// 概览页也必须说英文——此前它读的是领域层里硬编码的中文，英文界面上照样显示中文。
    func test四类分列跟随界面语言取本地化目录() throws {
        let (model, _, fixture) = try makeModel(language: .english)
        defer { fixture.remove() }

        let rows = model.categoryRows
        XCTAssertEqual(
            rows.map(\.title),
            ["Archivable sessions", "Cache & logs", "Protected", "Uncertain"]
        )
        XCTAssertEqual(
            rows.map(\.handling),
            ["Archiving supported", "Shown only, never touched", "Never touched, shown only", "Locked, size shown only"]
        )
        XCTAssertEqual(rows.first?.accessibilityLabel, "Archivable sessions: 1 MB (2 files), Archiving supported")

        // 与明细页共用同一批 key：不是两套文案碰巧长得一样。
        XCTAssertEqual(
            rows.map(\.title),
            DataCategory.displayOrder.map { CategoryCopy.nameText(for: $0, language: .english) }
        )
        XCTAssertEqual(
            rows.map(\.handling),
            DataCategory.displayOrder.map { CategoryCopy.handlingText(for: $0, language: .english) }
        )
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
            issueSource: StubIssueSource(),
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
            issueSource: StubIssueSource(),
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

    // MARK: - 键盘可达

    func test重新扫描有键盘入口() throws {
        // 视图把它挂在「重新扫描」按钮上（⌘R），键盘与鼠标走同一个 `reload()`。
        let (model, _, fixture) = try makeModel()
        defer { fixture.remove() }

        XCTAssertEqual(model.reloadShortcutText, "⌘R")
        XCTAssertEqual(model.reloadTitle, "重新扫描")
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
        XCTAssertTrue(model.issueTexts.isEmpty, "规则好好的：不许把「还没确认工具」报成规则问题")
    }

    // MARK: - 运行级问题：规则没配上时说清原因，不摆 0 B（ticket #32）

    /// 规则没打进包 + 一台已确认工具：必须说「没扫过」，而不是摆一台「0 B」的工具。
    ///
    /// `Bundle.module` 的规则资源漏打包时（issue #15 记录的风险）就是这样：
    /// 候选与占用都会是空的，但那不是用户的机器上没装工具。
    func test规则没加载到时给出提示且一个占用数字都不显示() throws {
        let (model, scanner, issueSource, fixture) = try makeIssueModel(issues: [.noRulesLoaded])
        defer { fixture.remove() }

        XCTAssertEqual(model.issueTexts, [
            "没有加载到任何内置规则文件，因此这些工具还没被扫描过——这里的占用是「未知」，不是 0 B。"
                + "请确认打包时把规则资源一并放进了应用包。",
        ])
        XCTAssertNil(model.totalText, "未扫描 ≠ 占 0 B：宁可什么都不显示")
        XCTAssertNil(model.totalAccessibilityText)
        XCTAssertNil(model.archivableShareText)
        XCTAssertTrue(model.categoryRows.isEmpty)
        XCTAssertTrue(model.toolRows.isEmpty, "任何工具行都会摆出一个「0 B（0 个文件）」")
        XCTAssertNil(model.emptyGuidanceText, "规则没配上时，「先去确认工具」是误导：不是空状态")
        XCTAssertFalse(model.isEmpty, "有已确认工具，这不是空状态")
        XCTAssertEqual(issueSource.issuesCallCount, 1, "先问问题")
        XCTAssertEqual(scanner.scanCount, 0, "没有可判定的分类就不扫：31G 的递归不该为摆一排 0 而跑")
        XCTAssertEqual(scanner.receivedRecords, [])
    }

    /// 规则读到了但一条都没过准入：文案要带上被拒条数，同样不摆占用。
    func test规则全部被拒时提示带上被拒条数且不显示占用() throws {
        let (model, scanner, _, fixture) = try makeIssueModel(issues: [.noUsableRules(rejectedCount: 7)])
        defer { fixture.remove() }

        XCTAssertEqual(model.issueTexts, [
            "加载到 7 条规则，但全部未通过规则集准入（保护单调性校验），因此这些工具还没被扫描过——"
                + "这里的占用是「未知」，不是 0 B。请检查内置规则文件是否被改动。",
        ])
        XCTAssertNil(model.totalText)
        XCTAssertTrue(model.toolRows.isEmpty)
        XCTAssertTrue(model.categoryRows.isEmpty)
        XCTAssertEqual(scanner.scanCount, 0)
    }

    /// 两条问题都要有英文文案：概览页在英文界面上也必须说英文。
    func test运行级问题文案中英文都有且都不显示占用() throws {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let (model, _, _, fixture) = try makeIssueModel(issues: [.noRulesLoaded], language: language)
            defer { fixture.remove() }

            let text = try XCTUnwrap(model.issueTexts.first)
            XCTAssertNotEqual(text, L10n.Key.overviewIssueNoRules.rawValue, "不许把 key 甩给用户")
            XCTAssertNotEqual(text, L10n.Key.overviewIssueRulesRejected.rawValue)
            XCTAssertNil(model.totalText)
            XCTAssertTrue(model.toolRows.isEmpty)
        }

        XCTAssertNotEqual(
            L10n.text(.overviewIssueNoRules, language: .simplifiedChinese),
            L10n.text(.overviewIssueNoRules, language: .english)
        )
        XCTAssertNotEqual(
            L10n.text(.overviewIssueRulesRejected, language: .simplifiedChinese),
            L10n.text(.overviewIssueRulesRejected, language: .english)
        )
    }

    /// 反过来：规则可用、只是还没有任何已确认工具时，照常走空状态引导——
    /// 「空候选」与「规则没配上」必须分得开（验收 2）。
    func test规则正常时没有任何已确认工具仍走空状态引导() throws {
        let (model, issueSource, fixture) = try makeEmptyModelWithIssues([])
        defer { fixture.remove() }

        XCTAssertTrue(model.issueTexts.isEmpty)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNotNil(model.emptyGuidanceText, "规则正常：这句引导是给用户的路")
        XCTAssertEqual(issueSource.issuesCallCount, 1)
    }

    /// 有运行级问题时，即使工具数不为 0 也不许把「先确认工具」那句引导摆出来。
    func test有运行级问题时不再摆空状态引导() throws {
        let fixture = try OverviewPageFixture(named: "overview-issues-no-guidance")
        defer { fixture.remove() }

        let model = OverviewPageModel(
            store: fixture.store,
            scanner: StubOccupancyScanner(report: OverviewFixture.report([])),
            capacityReader: StubCapacityReader(reading: .measured(availableBytes: 1_024, totalBytes: 2_048)),
            homeDirectory: fixture.homePath,
            issueSource: StubIssueSource([.noRulesLoaded]),
            scheduler: .immediate
        )
        model.load()

        XCTAssertNil(model.emptyGuidanceText)
        XCTAssertEqual(model.issueTexts.count, 1)
        XCTAssertNil(model.totalText)
    }

    /// 上一轮数字属于「规则好好的那次」：这次规则失效后不许继续摆着。
    func test重新扫描时规则失效要把上一轮的数字撤下来() throws {
        let fixture = try OverviewPageFixture(named: "overview-issues-after-scan")
        defer { fixture.remove() }
        try fixture.confirm(id: "claude-code", root: fixture.toolRoot(".claude"))

        let scanner = StubOccupancyScanner(report: OverviewFixture.report([
            OverviewFixture.toolReport(
                id: "claude-code",
                displayName: "Claude Code",
                toolRootPath: fixture.toolRoot(".claude"),
                bytes: [.archivableSession: 10_485_760],
                fileCounts: [.archivableSession: 1]
            ),
        ]))
        let issueSource = StubIssueSource()
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: scanner,
            capacityReader: StubCapacityReader(reading: .measured(availableBytes: 1_024, totalBytes: 2_048)),
            homeDirectory: fixture.homePath,
            issueSource: issueSource,
            scheduler: .immediate
        )

        model.load()
        XCTAssertEqual(model.totalText, "总占用：10 MB（1 个文件）", "第一轮：规则好好的，照常显示")
        XCTAssertEqual(scanner.scanCount, 1)

        // 规则资源没了（打包漏了 / 被清理工具删了）：这一轮没有可判定的分类。
        issueSource.reportedIssues = [.noRulesLoaded]
        model.reload()

        XCTAssertNil(model.totalText, "运行级问题出现后，上一轮的数字必须撤下来")
        XCTAssertTrue(model.toolRows.isEmpty)
        XCTAssertEqual(model.issueTexts.count, 1)
        XCTAssertEqual(scanner.scanCount, 1, "第二轮没有规则可依：不该再扫一遍")
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

    // MARK: - 验收 7 / ticket #24：容量读的是「已确认工具所在的卷」

    /// ticket #24 把读数范围钉在「已确认工具所在的卷」：数据在哪个卷上，剩余空间就得读哪个卷。
    /// 此前读的是主目录——工具根与主目录跨卷时，界面会给出另一个卷的数字。
    func test容量读的是已确认工具所在的卷而不是主目录() throws {
        let fixture = try OverviewPageFixture(named: "overview-capacity-volume")
        defer { fixture.remove() }

        // 两台工具：排序后 `.codex` 在前（结果不随确认顺序变）。
        try fixture.confirm(id: "cursor", root: fixture.toolRoot(".cursor"))
        try fixture.confirm(id: "codex-cli", root: fixture.toolRoot(".codex"))

        let reader = RecordingCapacityReader()
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: StubOccupancyScanner(report: OverviewFixture.report([])),
            capacityReader: reader,
            homeDirectory: fixture.homePath,
            issueSource: StubIssueSource(),
            scheduler: .immediate
        )
        model.load()

        XCTAssertEqual(
            reader.requestedPaths,
            [fixture.toolRoot(".codex")],
            "读第一个已确认工具根所在的卷（确定、可复现），而不是主目录"
        )
        XCTAssertNotEqual(reader.requestedPaths.first, fixture.homePath)
    }

    /// 没有已确认工具（空状态）时没有「工具所在的卷」可读：退回主目录，
    /// 空状态下仍然给得出磁盘剩余空间那一行。
    func test没有已确认工具时容量退回主目录() throws {
        let fixture = try OverviewPageFixture(named: "overview-capacity-no-tools")
        defer { fixture.remove() }

        let reader = RecordingCapacityReader()
        let model = OverviewPageModel(
            store: fixture.store,
            scanner: StubOccupancyScanner(report: OverviewFixture.report([])),
            capacityReader: reader,
            homeDirectory: fixture.homePath,
            issueSource: StubIssueSource(),
            scheduler: .immediate
        )
        model.load()

        XCTAssertEqual(reader.requestedPaths, [fixture.homePath], "没有工具时退回主目录")
        XCTAssertTrue(model.isEmpty)
    }
}
