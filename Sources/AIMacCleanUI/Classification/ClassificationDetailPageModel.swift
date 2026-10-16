import Combine
import Foundation

import AIMacCleanDomain

/// 分类明细页的视图模型（issue #27）。
///
/// 页面里所有会出错的状态都在这里：扫描中、上一轮结果、空态、规则不可用。
/// 视图只做渲染与转发，因此这一层可以在没有窗口的情况下测。
///
/// ## 不变式
///
/// 1. **只在后台扫**（issue #21 的教训）：一次深扫要遍历数万文件（本机约 31G），
///    同步跑在调用线程上会把窗口冻住。扫描交给 `DiscoveryScheduler`，
///    完成后回主线程更新状态。
/// 2. **扫描中不清空上一轮结果**：进度条旁边继续显示上一次的数字，
///    比把整页清成空白诚实，也让界面保持可交互。
/// 3. **四条纪律都来自呈现层**：四类顺序、处理方式文案、极小占比标注、读不到的位置，
///    全在 `ClassificationDetailPresenter` 里，这一层只负责把它们摆出来。
/// 4. **诚实**：不显示压缩节省估算、不给任何收益暗示（PRD §9 的范围切分）。
public final class ClassificationDetailPageModel: ObservableObject {

    /// 界面读的那一份状态。
    @Published public private(set) var state: ClassificationDetailPageState

    private let source: DeepScanSource
    private let homeDirectory: String
    private let language: AppLanguage?

    /// 「扫描」与「更新状态」分别跑在哪条线程上（issue #21、issue #28 的同一条纪律）。
    private let scheduler: DiscoveryScheduler

    /// - Parameters:
    ///   - source: 深扫接线（生产用 `DeepScanService`，测试给固定结果）。
    ///   - homeDirectory: 路径展示用的主目录，由调用方注入，测试才不用碰真实主目录。
    ///   - language: 界面语言；`nil` 跟随 `L10n` 的默认（取不到时落到简体中文）。
    ///   - scheduler: 扫描与状态更新各跑在哪条线程上。生产是后台扫描 + 回主线程。
    public init(
        source: DeepScanSource,
        homeDirectory: String,
        language: AppLanguage? = nil,
        scheduler: DiscoveryScheduler = .immediate
    ) {
        self.source = source
        self.homeDirectory = homeDirectory
        self.language = language
        self.scheduler = scheduler
        self.state = ClassificationDetailPageState()
    }

    /// 应用里用的入口：真实规则目录与本机确认存储。
    ///
    /// 规则目录由 `DeepScanService.standard` 自己解析（`Bundle.module` 的规则资源）；
    /// 界面层不碰规则层，也不自己找规则文件。
    public static func standard(
        store: any ConfirmationStore = JSONConfirmationStore.standard(),
        homeDirectory: String = NSHomeDirectory(),
        language: AppLanguage? = nil
    ) -> ClassificationDetailPageModel {
        ClassificationDetailPageModel(
            source: DeepScanService.standard(store: store, homeDirectory: homeDirectory),
            homeDirectory: homeDirectory,
            language: language,
            // 生产：31G / 数万文件的递归扫描放到后台，界面不被冻住（issue #21）。
            scheduler: .background()
        )
    }

    // MARK: - 生命周期

    /// 跑一次深扫并铺开状态。页面出现时调用；重复调用等价于重新扫描。
    ///
    /// **不重算占用、不重新判定分类**：深扫自己会给出四类与子路径明细，
    /// 这一层只把它们摊成界面要的文字。
    public func load() {
        guard !state.isScanning else { return }
        state.isScanning = true

        scheduler.runScan { [weak self] in
            guard let self else { return }
            let run = self.source.run()
            self.scheduler.runOnMain { [weak self] in
                guard let self else { return }
                self.apply(run)
            }
        }
    }

    /// 「重新扫描」按钮。
    public func reload() {
        load()
    }

    // MARK: - 呈现

    /// 取某台工具的明细。
    public func detail(toolID: String) -> ToolClassificationDetail? {
        state.details.first { $0.toolID == toolID }
    }

    public var titleText: String { L10n.text(.classificationPageTitle, language: language) }

    /// 页面顶部的阶段说明：**当前版本什么都不动**。
    public var stageNoteText: String { L10n.text(.classificationStageNote, language: language) }

    /// 扫描进行中的进度提示文案。
    public var scanningText: String { L10n.text(.classificationScanning, language: language) }

    public var reloadTitleText: String { L10n.text(.classificationReload, language: language) }

    /// 还没确认过任何工具时的引导（PRD §9：空态要指路，不要显示 0）。
    public var emptyText: String { L10n.text(.classificationEmpty, language: language) }

    /// 运行级问题的可读说明（规则没载入、规则全被拒绝）。
    public var issueTexts: [String] {
        state.issues.map { issue in
            switch issue {
            case .noRulesLoaded:
                return L10n.text(.classificationIssueNoRules, language: language)
            case let .noUsableRules(rejectedCount):
                return L10n.format(.classificationIssueRulesRejected, ["\(rejectedCount)"], language: language)
            }
        }
    }

    // MARK: - 内部

    /// 把一次深扫结果摊成界面状态；扫描完成，`isScanning` 归位。
    private func apply(_ run: DeepScanRun) {
        state.details = run.report.toolReports.map { report in
            ClassificationDetailPresenter.detail(
                for: report,
                homeDirectory: homeDirectory,
                language: language
            )
        }
        state.issues = run.issues
        state.hasLoaded = true
        state.isScanning = false
    }
}
