import Foundation

import AIMacCleanRules

/// 一次深扫的接线结果（issue #27）。
public struct DeepScanRun: Equatable, Sendable {

    /// 各工具的占用报告；没有可用规则时为空。
    public let report: DeepScanReport

    /// 这次运行里已知的问题（逐条可读）。
    public let issues: [DeepScanIssue]

    public init(report: DeepScanReport = DeepScanReport(toolReports: []), issues: [DeepScanIssue] = []) {
        self.report = report
        self.issues = issues
    }
}

/// 一次深扫里「没能完成的那部分」。
public enum DeepScanIssue: Equatable, Sendable {

    /// 一条规则都没加载进来——分类无从谈起，而且这不是用户机器的问题。
    case noRulesLoaded

    /// 规则读到了，但**一条都没通过准入**（保护单调性等，issue #11）。
    case noUsableRules(rejectedCount: Int)
}

extension DeepScanIssue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noRulesLoaded:
            return "没有加载到任何内置规则文件，无法判定分类。"
        case let .noUsableRules(rejectedCount):
            return "加载到 \(rejectedCount) 条规则，但全部未通过规则集准入，无法判定分类。"
        }
    }
}

/// 深扫的运行入口（issue #27 的接线处）。
///
/// 单独成协议的理由与浅扫一样：**界面状态机不该自己去读规则文件与确认存储**。
/// 视图模型的测试注入一个固定结果，生产接线由 `DeepScanService` 提供。
public protocol DeepScanSource {
    func run() -> DeepScanRun
}

/// 生产环境的深扫接线（issue #27）。
///
/// 一次 `run()` 依次做三件事，顺序本身就是纪律：
/// 1. **加载内置规则** → 规则集准入（保护单调性在这一步生效）。
/// 2. **从确认存储装配一台台工具**（`ConfirmedTool`）：只认**已确认**的记录，
///    并按工具标识去重（见 `ConfirmedTool.normalized`）。
/// 3. **深扫**：`DeepScanner` 只读元数据与文件头，零写入。
///
/// 没有可用规则时**不扫**：不给出一排 0 B 的假占用，而是给出 `DeepScanIssue`
/// 让界面把原因说出来（PRD §5.1 的四类判定来自规则声明，没有规则就没有四类）。
public struct DeepScanService: DeepScanSource {

    /// 运行一次深扫需要的外部输入。
    public struct Configuration: Equatable, Sendable {

        /// 主目录绝对路径（`~` 的展开基准）。
        public var homeDirectory: String

        /// 内置规则目录。`nil` 表示资源没找到。
        public var ruleDirectory: URL?

        public init(homeDirectory: String, ruleDirectory: URL?) {
            self.homeDirectory = homeDirectory
            self.ruleDirectory = ruleDirectory
        }
    }

    public let configuration: Configuration

    /// 已确认工具的来源（GLOSSARY「工具」）。
    public let store: any ConfirmationStore

    /// 真正干活的深扫器。测试可注入记录器或替身。
    public let scanner: any DeepScanning

    public init(
        configuration: Configuration,
        store: any ConfirmationStore,
        scanner: any DeepScanning = DeepScanner()
    ) {
        self.configuration = configuration
        self.store = store
        self.scanner = scanner
    }

    /// 应用启动时用的入口：真实规则目录与本机确认存储。
    public static func standard(
        store: any ConfirmationStore = JSONConfirmationStore.standard(),
        homeDirectory: String = NSHomeDirectory(),
        ruleDirectory: URL? = BuiltInRuleResources.directory,
        scanner: any DeepScanning = DeepScanner()
    ) -> DeepScanService {
        DeepScanService(
            configuration: Configuration(homeDirectory: homeDirectory, ruleDirectory: ruleDirectory),
            store: store,
            scanner: scanner
        )
    }

    public func run() -> DeepScanRun {
        let (rules, issues) = loadUsableRules()
        guard issues.isEmpty else {
            // 没有可判定的分类：返回空报告 + 问题，让界面说清原因，
            // 而不是显示一排「0 B」（那会被读成「这些工具什么都没占」）。
            return DeepScanRun(issues: issues)
        }

        let tools = ConfirmedTool.normalized(confirmedTools(rules: rules))
        return DeepScanRun(
            report: scanner.scan(
                tools: tools,
                rules: rules,
                homeDirectory: configuration.homeDirectory
            ),
            issues: []
        )
    }

    // MARK: - 内部

    /// 加载规则并走规则集准入。目录缺失或一条都没载入都给问题，不静默。
    private func loadUsableRules() -> (rules: RuleAdmissionReport, issues: [DeepScanIssue]) {
        guard let directory = configuration.ruleDirectory else {
            return (RuleAdmissionReport(usableRules: [], rejections: []), [.noRulesLoaded])
        }
        let report = RuleLoader.loadRules(inDirectory: directory)
        guard !report.rules.isEmpty else {
            return (RuleAdmissionReport(usableRules: [], rejections: []), [.noRulesLoaded])
        }
        let admission = RuleSetAdmission.admit(rules: report.rules, homeDirectory: configuration.homeDirectory)
        guard !admission.usableRules.isEmpty else {
            return (admission, [.noUsableRules(rejectedCount: admission.rejections.count)])
        }
        return (admission, [])
    }

    /// 把已确认的记录装配成深扫的输入。
    ///
    /// 展示名取规则的 `displayName`（它是用户认得的名字：`Claude Code`），
    /// 没有对应规则时退回记录里的标识——不编造名字。
    private func confirmedTools(rules: RuleAdmissionReport) -> [ConfirmedTool] {
        store.confirmedTools.compactMap { record in
            guard let identifier = record.toolIdentifier else { return nil }
            return ConfirmedTool(
                id: identifier,
                displayName: rules.usableRule(id: identifier)?.displayName ?? identifier,
                toolRootPath: record.toolRootPath
            )
        }
    }
}

extension ConfirmedTool {

    /// 按**工具标识**去重，并给出确定的顺序。
    ///
    /// 确认存储以工具根路径为键，而深扫的输入是「一台台工具」：同一条规则被确认出两条记录时，
    /// 不去重就会把这台工具扫两遍——规则声明的**仅展示根**（issue #31：Cursor 的
    /// `~/Library/Application Support/Cursor` 14G）因此被算两遍，占用直接翻倍。
    ///
    /// 多条记录撞同一个标识时保留**工具根路径字典序最小**的那条：规则为每个工具只声明
    /// 一个工具根，多出来的记录是同一台工具的重复确认；取字典序最小的那条是为了让结果
    /// 不随确认存储的遍历顺序变（同样的输入永远给同样的结果）。
    public static func normalized(_ tools: [ConfirmedTool]) -> [ConfirmedTool] {
        var seen = Set<String>()
        return tools
            .sorted { ($0.id, $0.toolRootPath) < ($1.id, $1.toolRootPath) }
            .filter { seen.insert($0.id).inserted }
    }
}
