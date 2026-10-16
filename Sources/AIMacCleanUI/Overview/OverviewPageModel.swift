import Combine
import Foundation

import AIMacCleanDomain

/// 概览页的视图模型（issue #28；PRD §9、§14.1）。
///
/// 页面里所有会出错或需要判断的状态都在这里：扫描中、空状态、占比极小的标注、
/// 容量未知、归档按钮为什么不可用。视图只做渲染与转发，因此这一层可以在没有窗口的情况下测。
///
/// ## 诚实展示的五条纪律
///
/// 1. **只有已确认的工具进统计**（PRD §4.1 第 4 步）：输入是 `ConfirmationStore.confirmedTools`，
///    候选列表里的东西一个都不会被算进来。
/// 2. **不显示本阶段拿不出来的数字**：没有压缩节省、没有「搬迁腾出」（属 M3，PRD §6.3/§9）；
///    容量读不到时显示「未知」，绝不显示 0（0 会被读成「盘满了」）。
/// 3. **收益低就如实说**：可归档占比极小的工具带上「可归档占比极小」，不用大字号暗示收益
///    （PRD §9；§14.1 的 Claude Code 是 0.15%）。
/// 4. **空状态给路**：规则好好的、只是没有任何已确认工具时引导去「发现与确认」页，
///    而不是摆一排误导性的 0。
/// 5. **「没扫过」不是「占 0 B」**（ticket #32）：规则资源没打进包（issue #15 记录的
///    `Bundle.module` 打包风险）或规则全被准入拒绝时，页面收到的是**运行级问题**
///    （`DeepScanIssue`），这时说清原因，一个占用数字都不摆——连扫都不扫。
public final class OverviewPageModel: ObservableObject {

    /// 界面读的那一份状态。
    @Published public private(set) var state: OverviewPageState

    private let store: ConfirmationStore
    private let scanner: any ConfirmedToolScanning

    /// 运行级问题的出处（ticket #32）。
    ///
    /// 与 `scanner` 是**组合**关系，不是二选一：`DeepScanService` 同时是这两条协议，
    /// 生产接线把同一个实例喂给两个参数。报告走 `scan(_:)`（分类明细页不用它），
    /// 问题走 `issues()`（分类明细页走自己的 `run()`）。
    private let issueSource: any DeepScanSource

    private let capacityReader: any VolumeCapacityReading
    private let homeDirectory: String

    /// 界面语言；`nil` 落到 `L10n` 的基准语言（简体中文）。
    ///
    /// 与分类明细页同一条接线：文案不在视图里硬编码，也不在模型里写死中文——
    /// 四类的名称与处理方式走 `CategoryCopy`（本地化目录），其余文案走 `L10n`。
    private let language: AppLanguage?

    /// 「扫描」与「更新状态」分别跑在哪条线程上（复用 issue #21 的调度点）。
    private let scheduler: DiscoveryScheduler

    /// `state.report` 对应的那批已确认工具根（排序后）。用来判断「工具集合有没有变」。
    private var reportToolRootPaths: [String] = []

    /// - Parameters:
    ///   - store: 确认存储。只读 `confirmedTools`——候选不参与概览。
    ///   - scanner: 深扫入口（生产用 `DeepScanService`，测试给固定报告）。
    ///   - capacityReader: 卷容量读数（生产用 `SystemVolumeCapacityReader`，测试给固定值）。
    ///   - homeDirectory: 路径缩写用；没有已确认工具时也是容量读数的那个卷。
    ///   - language: 界面语言；`nil` 跟随 `L10n` 的默认（取不到时落到简体中文）。
    ///   - issueSource: 运行级问题的出处（规则没载入 / 全被拒绝）。生产与 `scanner`
    ///     是同一个 `DeepScanService`。
    ///   - scheduler: 扫描跑在哪条线程上。默认同步（测试确定），生产用 `.background()`。
    public init(
        store: ConfirmationStore,
        scanner: any ConfirmedToolScanning,
        capacityReader: any VolumeCapacityReading,
        homeDirectory: String,
        issueSource: any DeepScanSource,
        language: AppLanguage? = nil,
        scheduler: DiscoveryScheduler = .immediate
    ) {
        self.store = store
        self.scanner = scanner
        self.capacityReader = capacityReader
        self.homeDirectory = homeDirectory
        self.issueSource = issueSource
        self.language = language
        self.scheduler = scheduler
        self.state = OverviewPageState()
    }

    /// 应用启动时用的入口：本机确认存储 + 内置规则深扫 + 系统卷容量读数。
    ///
    /// - Parameters:
    ///   - scanner: 省略时按 `homeDirectory` 建一个标准的 `DeepScanService`。
    ///   - issueSource: 省略时用同一个 `DeepScanService`（两条入口收敛在同一个类型上，
    ///     因此「规则配上了没有」与「报告是从哪来的」不可能分叉）。
    ///   - language: 界面语言，透到四类分列与全部固定文案。
    public static func standard(
        store: ConfirmationStore = JSONConfirmationStore.standard(),
        scanner: (any ConfirmedToolScanning)? = nil,
        issueSource: (any DeepScanSource)? = nil,
        capacityReader: any VolumeCapacityReading = SystemVolumeCapacityReader(),
        homeDirectory: String = NSHomeDirectory(),
        language: AppLanguage? = nil
    ) -> OverviewPageModel {
        // 两条入口共用同一个实例（`DeepScanService` 同时是 `DeepScanSource` 与
        // `ConfirmedToolScanning`）：这样「规则配上了没有」与「报告是从哪来的」
        // 不可能分叉——它们本来就是同一次装配的两面。
        let service = DeepScanService.standard(homeDirectory: homeDirectory)
        return OverviewPageModel(
            store: store,
            scanner: scanner ?? service,
            capacityReader: capacityReader,
            homeDirectory: homeDirectory,
            issueSource: issueSource ?? service,
            language: language,
            // 生产：深扫本机实测约 31G / 数万文件，跑在后台，界面不被冻住（issue #21）。
            scheduler: .background()
        )
    }

    // MARK: - 生命周期

    /// 跑一次深扫并铺开状态。视图出现时调用；重复调用等价于重新扫描。
    ///
    /// **扫描不在调用线程上跑**（issue #21）。扫描期间**不清空已有结果**：
    /// 上一轮的数字原样留在界面上，用户点「重新扫描」不会看到页面先空一下（验收 6）。
    /// 扫描进行中重复调用直接忽略，不排队第二次扫描。
    ///
    /// **运行级问题存在时根本不扫**（ticket #32）：先问 `issueSource`，没有可用规则就
    /// 直接带着问题收工——没有可判定的分类时，扫出来的数字一个都解释不了。
    public func load() {
        guard !state.isScanning else { return }

        // 只扫已确认的工具，且这一轮要扫的就是这一刻的记录。
        let records = store.confirmedTools
        let toolRootPaths = Self.sortedToolRootPaths(records)

        // 已确认工具变了时，`state.report` 里的数字对应的是**上一批**工具：
        // 留着它会在扫描期间摆出一个属于别人的 0（「刚确认了工具，概览还是 0」）。
        // 工具集合没变（普通的重新扫描）则原样保留，页面不会空一下（验收 6）。
        if toolRootPaths != reportToolRootPaths {
            state.report = nil
        }

        state.isScanning = true
        state.confirmedToolCount = records.count

        scheduler.runScan { [weak self] in
            guard let self else { return }
            // 运行级问题先问，而且要**先于**扫描（ticket #32）：规则资源没配上时
            // 根本没有可判定的分类，扫出来的每个数字都无从解释——那就不扫。
            // 本机实测 31G / 数万文件的递归不该为了在界面上摆一排 0 而跑一遍。
            let issues = self.issueSource.issues()
            let report = issues.isEmpty ? self.scanner.scan(records) : nil
            // 容量与深扫在同一段后台工作里读：界面线程上只剩「换状态」。
            //
            // 读的是**已确认工具所在的卷**（ticket #24）：数据在哪个卷上，剩余空间就得读哪个卷，
            // 否则工具根与主目录跨卷时界面会给另一个卷的数字。第一个已确认工具根（排序后，
            // 结果确定）就是那个卷；没有已确认工具时退回主目录——空状态下仍要给得出这一行。
            let capacityPath = toolRootPaths.first ?? self.homeDirectory
            let capacity = self.capacityReader.capacity(ofVolumeContaining: capacityPath)
            self.scheduler.runOnMain { [weak self] in
                guard let self else { return }
                self.state.issues = issues
                // 有运行级问题时报告一律为 `nil`：上一轮的数字属于「规则好好的那次」，
                // 这一轮没有可判定的分类，撤下来比继续摆着诚实（ticket #32）。
                self.state.report = report
                self.state.capacity = capacity
                self.state.hasLoaded = true
                self.state.isScanning = false
                self.reportToolRootPaths = toolRootPaths
            }
        }
    }

    /// 「重新扫描」按钮。
    public func reload() {
        load()
    }

    // MARK: - 运行级问题（ticket #32）

    /// 这次运行的运行级问题的可读说明：规则没载入、规则全被准入拒绝。
    ///
    /// 空数组表示规则好好的、占用照常展示。非空时页面**一个占用数字都不摆**——
    /// 「这些工具没被扫过」与「这些工具占 0 B」是两件事，混起来就是假话
    /// （PRD §9 如实展示；issue #15 记录的打包风险会让这种情况真实发生）。
    ///
    /// 逐条可读的说明由 `DeepScanIssue` 的两个情形各给一条文案，与分类明细页同一条纪律：
    /// 问题要说出来，而不是把它变成一排 0。
    public var issueTexts: [String] {
        state.issues.map { issue in
            switch issue {
            case .noRulesLoaded:
                return L10n.text(.overviewIssueNoRules, language: language)
            case let .noUsableRules(rejectedCount):
                return L10n.format(.overviewIssueRulesRejected, ["\(rejectedCount)"], language: language)
            }
        }
    }

    // MARK: - 空状态（验收 5）

    /// 是否该显示空状态：**第一轮扫描完成之后**、没有任何已确认工具、**且这次运行没有
    /// 运行级问题**。
    ///
    /// 第三个条件（ticket #32）与分类明细页同一条纪律：规则没配上时的空候选不是
    /// 「你还没确认工具」，对着一台装了工具的机器说这句话是误导。
    public var isEmpty: Bool {
        state.hasLoaded && state.confirmedToolCount == 0 && state.issues.isEmpty
    }

    /// 空状态的引导文案：告诉用户去哪儿确认工具，而不是摆一排 0。
    ///
    /// 有运行级问题时为 `nil`——那不是空状态（见 `issueTexts`）。
    public var emptyGuidanceText: String? {
        isEmpty ? L10n.text(.overviewEmptyNoTools, language: language) : nil
    }

    /// 固定文案。
    public var pageTitle: String { L10n.text(.overviewPageTitle, language: language) }
    public var stageNoteText: String { L10n.text(.overviewStageNote, language: language) }
    public var reloadTitle: String { L10n.text(.overviewReload, language: language) }
    public var categorySectionTitle: String { L10n.text(.overviewSectionCategories, language: language) }
    public var toolSectionTitle: String { L10n.text(.overviewSectionTools, language: language) }
    public var scanningText: String? { state.isScanning ? L10n.text(.overviewScanning, language: language) : nil }

    /// 「重新扫描」的键盘快捷键说明。视图把它挂到按钮上，键盘与鼠标走的是同一个动作
    /// （`reload()`），因此不存在两套语义。与发现与确认页一致用 ⌘R。
    public var reloadShortcutText: String { Self.reloadShortcut }

    /// ⌘R：重新扫描。
    static let reloadShortcut = "⌘R"

    // MARK: - 数字（验收 1、2）

    /// 总占用文案；还没有结果或空状态时为 `nil`（宁可什么都不显示，也不显示 0）。
    public var totalText: String? {
        guard let report = visibleReport else { return nil }
        return L10n.format(.overviewTotalValue, [
            ByteSizeDisplay.string(from: report.totalBytes),
            Self.countText(report.totalFileCount),
        ], language: language)
    }

    /// 总占用的辅助功能文案（辅助技术也要读得出数字，验收 7）。
    public var totalAccessibilityText: String? {
        guard let report = visibleReport else { return nil }
        return L10n.format(.overviewAccessibilityTotal, [
            ByteSizeDisplay.string(from: report.totalBytes),
            Self.countText(report.totalFileCount),
        ], language: language)
    }

    /// 「可归档占比」文案：占比 + 可归档字节。
    public var archivableShareText: String? {
        guard let report = visibleReport else { return nil }
        return L10n.format(.overviewArchivableValue, [
            ArchivableShare.percentText(report.archivableShare),
            ByteSizeDisplay.string(from: report.archivableOccupancy.bytes),
        ], language: language)
    }

    /// 四类分列（全体工具逐类求和）。
    ///
    /// 名称与处理方式走 `CategoryCopy`（本地化目录里的同一批 key），与分类明细页同源。
    public var categoryRows: [OverviewCategoryRow] {
        visibleReport?.categoryLines.map(categoryRow) ?? []
    }

    /// 各工具占用，**按体积从大到小**排列（同样大小按工具标识，保证顺序稳定）。
    public var toolRows: [OverviewToolRow] {
        guard let report = visibleReport else { return [] }
        return report.toolReports
            .sorted { lhs, rhs in
                if lhs.occupancy.bytes != rhs.occupancy.bytes { return lhs.occupancy.bytes > rhs.occupancy.bytes }
                return lhs.toolID < rhs.toolID
            }
            .map { toolRow($0, homeDirectory: homeDirectory) }
    }

    // MARK: - 磁盘剩余空间（验收 7）

    /// 磁盘剩余空间文案；还没读过容量时为 `nil`。
    ///
    /// 读到容量就给数字（**真的 0 也照常显示**——盘确实满了是事实）；
    /// 读不到就按原因给「未知」的说明，绝不回落到 0。
    public var freeSpaceText: String? {
        guard let capacity = state.capacity else { return nil }
        switch capacity {
        case let .measured(availableBytes, totalBytes):
            return L10n.format(.overviewDiskFree, [
                ByteSizeDisplay.string(from: availableBytes),
                ByteSizeDisplay.string(from: totalBytes),
            ], language: language)
        case .unknown(.volumeUnreadable):
            return L10n.text(.overviewDiskUnknownUnreadable, language: language)
        case .unknown(.capacityNotReported):
            return L10n.text(.overviewDiskUnknownNotReported, language: language)
        }
    }

    // MARK: - 主按钮（验收 4）

    /// 「开始归档」。
    public var archiveButtonTitle: String { L10n.text(.overviewArchiveAction, language: language) }

    /// 主按钮**恒不可用**：归档能力属于 M3。
    ///
    /// 刻意不由「有没有可归档数据」推导：即使有数据，能力也还不存在。
    /// 界面因此必须给出原因（`archiveDisabledReason`），而不是给一个点了没反应的按钮。
    public var archiveButtonIsEnabled: Bool { false }

    /// 主按钮为什么不可用（逐字解释，不是一句「暂不可用」）。
    public var archiveDisabledReason: String { L10n.text(.overviewArchiveDisabledReason, language: language) }

    // MARK: - 内部

    /// 可以摆给用户看的那份报告；`nil` 表示**一个占用数字都不许出现**。
    ///
    /// 三种情况一律不给数字：运行级问题（规则没配上，根本没扫过）、空状态
    /// （`report` 里可能还留着上一轮的结果，例如用户刚移出全部工具）、还没有任何报告。
    /// 宁可整块不显示，也不显示 0——「没扫过」被读成「占 0 B」就是这个页面最不该犯的错。
    private var visibleReport: DeepScanReport? {
        guard state.issues.isEmpty else { return nil }
        return isEmpty ? nil : state.report
    }

    private func categoryRow(_ line: CategoryOccupancyLine) -> OverviewCategoryRow {
        let occupancyText = occupancyText(line.occupancy)
        let title = CategoryCopy.nameText(for: line.category, language: language)
        let handling = CategoryCopy.handlingText(for: line.category, language: language)
        return OverviewCategoryRow(
            categoryID: line.categoryID,
            title: title,
            handling: handling,
            occupancyText: occupancyText,
            bytes: line.occupancy.bytes,
            fileCount: line.occupancy.fileCount,
            accessibilityLabel: L10n.format(.overviewAccessibilityCategory, [
                title,
                occupancyText,
                handling,
            ], language: language)
        )
    }

    private func toolRow(_ report: ToolScanReport, homeDirectory: String) -> OverviewToolRow {
        let occupancyText = occupancyText(report.occupancy)
        let displayPath = ToolRootDisplay.abbreviated(report.toolRootPath, homeDirectory: homeDirectory)
        let share = ArchivableShare.percentText(report.archivableShare)
        let archivableSize = ByteSizeDisplay.string(from: report.archivableOccupancy.bytes)
        let negligible = report.isArchivableShareNegligible ? L10n.text(.overviewToolNegligible, language: language) : nil
        let displayOnly = report.displayOnlyOccupancy.bytes > 0
            ? L10n.format(
                .overviewToolDisplayOnly,
                [ByteSizeDisplay.string(from: report.displayOnlyOccupancy.bytes)],
                language: language
            )
            : nil

        // 辅助功能读出同一批事实：名字、路径、占用、可归档、占比，外加两句如实的补充。
        var accessibilityLabel = L10n.format(.overviewAccessibilityTool, [
            report.displayName,
            displayPath,
            occupancyText,
            archivableSize,
            share,
        ], language: language)
        for extra in [negligible, displayOnly].compactMap({ $0 }) {
            accessibilityLabel += "；" + extra
        }

        return OverviewToolRow(
            toolID: report.toolID,
            displayName: report.displayName,
            displayPath: displayPath,
            occupancyText: occupancyText,
            bytes: report.occupancy.bytes,
            fileCount: report.occupancy.fileCount,
            archivableText: L10n.format(.overviewToolArchivable, [archivableSize, share], language: language),
            negligibleAnnotation: negligible,
            displayOnlyText: displayOnly,
            accessibilityLabel: accessibilityLabel
        )
    }

    /// 「1 MB（2 个文件）」。
    private func occupancyText(_ occupancy: Occupancy) -> String {
        L10n.format(.overviewOccupancyValue, [
            ByteSizeDisplay.string(from: occupancy.bytes),
            Self.countText(occupancy.fileCount),
        ], language: language)
    }

    /// 文件数与 `ByteSizeFormatter` 同一套纪律：**不带千分位分隔符**，任何系统语言下写法一致。
    private static func countText(_ count: Int) -> String { "\(count)" }

    /// 已确认工具根的去重排序清单：确认存储的顺序不作保证，比较工具集合时不能靠它。
    private static func sortedToolRootPaths(_ records: [ConfirmationRecord]) -> [String] {
        Set(records.map(\.toolRootPath)).sorted()
    }
}
