import Foundation

import AIMacCleanCore
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

/// 「把已确认的工具深扫成一份占用报告」这件事的入口（issue #28）。
///
/// 概览页只需要这一个动作：给它确认存储里的记录，拿回 `DeepScanReport`。
/// 规则加载、规则集准入、`~/…` 展开、展示名解析这些事都在实现里，
/// 视图模型因此不必认识规则层（UI 只依赖 Domain）。
///
/// 收成协议是为了可注入：概览页的测试给一份固定报告，不跑磁盘扫描
/// （扫描本身已由 `DeepScanningTests` / `DeepScanBundledRuleTests` 在各自的 seam 上钉住）。
public protocol ConfirmedToolScanning {

    /// 对这批**已确认**的工具做深扫。
    ///
    /// - Parameter records: 确认存储里的记录（`ConfirmationStore.confirmedTools`）。
    ///   未确认的候选不在其中，因此不可能出现在占用里（PRD §4.1 第 4 步）。
    func scan(_ records: [ConfirmationRecord]) -> DeepScanReport
}

/// 生产环境的深扫接线：**分类明细页（#27）与概览页（#28）共用这一个类型**。
///
/// 两个入口不是两条路：
/// - `run() -> DeepScanRun` 给分类明细页：带上「规则不可用」这种**问题**，
///   让界面把原因说出来，而不是显示一排 0 B 的假占用。
/// - `scan(_:) -> DeepScanReport` 给概览页：只要一份报告；规则缺失时照常给结果
///   （没有规则可依的已确认工具落进「不确定」，而不是整页报错）。
///
/// 两者都收敛到同一段核心（`scan(tools:rules:)`）：**规则加载、规则集准入、
/// 「确认记录 → 深扫输入」的映射只有一份**。于是「同一个工具标识只扫一次」（#31：
/// 否则规则声明的仅展示根——Cursor 的 14G AppSupport——会被算两遍）这条纪律
/// 在两条入口上完全一致，不可能分歧。
public struct DeepScanService: DeepScanSource, ConfirmedToolScanning {

    /// 运行一次深扫需要的外部输入。
    public struct Configuration: Equatable, Sendable {

        /// 主目录绝对路径（`~` 的展开基准与路径缩写基准）。
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
    ///
    /// **概览页入口没有它**（`nil`）：那条入口的记录由调用方逐条传给 `scan(_:)`，
    /// 服务不需要一个「记录恒为空」的假存储来占位。只有分类明细页入口
    /// （`run()`，从目录加载规则的那条）才持有真实存储。
    private let store: (any ConfirmationStore)?

    /// 真正干活的深扫器。测试可注入记录器或替身。
    public let scanner: any DeepScanning

    /// 构造时注入的规则集（`nil` 表示规则要现从 `configuration.ruleDirectory` 加载）。
    ///
    /// 只有概览页入口（`init(rules:homeDirectory:scanner:)`）会填它：那条入口的规则
    /// 已过 `RuleSetAdmission`，不再读规则目录。分类明细页入口走目录加载，与出厂接线同一条路。
    private let injectedRules: RuleAdmissionReport?

    // MARK: - 装配

    /// 分类明细页的入口（issue #27）：配置 + 确认存储 + 深扫器。
    ///
    /// 规则在每次 `run()` 时从 `configuration.ruleDirectory` 重新加载并准入。
    public init(
        configuration: Configuration,
        store: any ConfirmationStore,
        scanner: any DeepScanning = DeepScanner()
    ) {
        self.configuration = configuration
        self.store = store
        self.scanner = scanner
        self.injectedRules = nil
    }

    /// 概览页的入口（issue #28）：**已准入**的规则 + 主目录 + 深扫器。
    ///
    /// 规则已经过 `RuleSetAdmission`（保护单调性在这一步生效），因此这条入口不再读规则目录；
    /// `homeDirectory` 显式传入，本层不读 `NSHomeDirectory()`。
    /// 这条入口没有确认存储：概览页的记录由调用方逐条传给 `scan(_:)`。
    public init(
        rules: RuleAdmissionReport,
        homeDirectory: String,
        scanner: any DeepScanning = DeepScanner()
    ) {
        self.configuration = Configuration(homeDirectory: homeDirectory, ruleDirectory: nil)
        self.store = nil
        self.scanner = scanner
        self.injectedRules = rules
    }

    /// 应用启动时用的统一入口：真实规则目录 + 本机确认存储（两个页面共用）。
    ///
    /// `fileSystem` 透给 `DeepScanner`：测试注入记录型文件系统后，
    /// 可以断言概览读的这条路同样零写入。
    public static func standard(
        store: any ConfirmationStore = JSONConfirmationStore.standard(),
        homeDirectory: String = NSHomeDirectory(),
        ruleDirectory: URL? = BuiltInRuleResources.directory,
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem(),
        scanner: (any DeepScanning)? = nil
    ) -> DeepScanService {
        DeepScanService(
            configuration: Configuration(homeDirectory: homeDirectory, ruleDirectory: ruleDirectory),
            store: store,
            scanner: scanner ?? DeepScanner(fileSystem: fileSystem)
        )
    }

    // MARK: - 入口一：分类明细页（#27）

    /// 跑一次深扫，并把「做不成的那部分」如实带回来。
    ///
    /// 没有可用规则时**不扫**：不给出一排 0 B 的假占用，而是给出 `DeepScanIssue`
    /// 让界面把原因说出来（PRD §5.1 的四类判定来自规则声明，没有规则就没有四类）。
    public func run() -> DeepScanRun {
        let (rules, issues) = loadUsableRules()
        guard issues.isEmpty else {
            // 没有可判定的分类：返回空报告 + 问题，让界面说清原因，
            // 而不是显示一排「0 B」（那会被读成「这些工具什么都没占」）。
            return DeepScanRun(issues: issues)
        }

        // 没有确认存储（概览页入口）时就是「没有已确认记录」：如实给一份空报告，
        // 而不是让一个恒为空的假存储假装自己是存储。
        return DeepScanRun(
            report: scan(tools: confirmedTools(from: store?.confirmedTools ?? []), rules: rules),
            issues: []
        )
    }

    // MARK: - 入口二：概览页（#28）

    /// 对这批**已确认**的记录做深扫（概览页只取报告，规则不可用时也照常给结果）。
    public func scan(_ records: [ConfirmationRecord]) -> DeepScanReport {
        scan(tools: confirmedTools(from: records), rules: admittedRules)
    }

    /// 本实例的已准入规则集。
    ///
    /// - 概览页入口：构造时注入的规则集原样返回。
    /// - 分类明细页入口：从 `configuration.ruleDirectory` 加载并准入
    ///   （与 `DiscoveryService` 的加载顺序一致）；目录缺失或一条都没载入时给空规则集。
    public var admittedRules: RuleAdmissionReport {
        if let injectedRules { return injectedRules }
        return DeepScanService.admittedRules(
            inDirectory: configuration.ruleDirectory,
            homeDirectory: configuration.homeDirectory
        )
    }

    /// 加载并准入规则；目录缺失时给空规则集（与 `DiscoveryService` 的加载顺序一致）。
    public static func admittedRules(
        inDirectory ruleDirectory: URL?,
        homeDirectory: String
    ) -> RuleAdmissionReport {
        guard let ruleDirectory else {
            return RuleAdmissionReport(usableRules: [], rejections: [])
        }
        let load = RuleLoader.loadRules(inDirectory: ruleDirectory)
        return RuleSetAdmission.admit(rules: load.rules, homeDirectory: homeDirectory)
    }

    /// 确认记录 → 深扫输入：按工具标识去重，展示名取规则里的名字。
    ///
    /// 未知工具（记录里没有工具标识）**不参与去重**：它们没有规则可依据，
    /// 每一条记录都是一个独立的目录，用路径当标识与展示名（GLOSSARY「不确定」）。
    ///
    /// `run()` 与 `scan(_:)` 都从这里取工具，因此两条入口对「哪条记录代表这台工具」
    /// 的判断完全一致。
    public func confirmedTools(from records: [ConfirmationRecord]) -> [ConfirmedTool] {
        let rules = admittedRules
        let identified = records
            .filter { $0.toolIdentifier != nil }
            .reduce(into: [String: ConfirmationRecord]()) { chosen, record in
                guard let id = record.toolIdentifier else { return }
                guard let current = chosen[id] else {
                    chosen[id] = record
                    return
                }
                if isPreferred(record, over: current, toolID: id, rules: rules) {
                    chosen[id] = record
                }
            }
            .values
            .sorted { ($0.toolIdentifier ?? "") < ($1.toolIdentifier ?? "") }

        let unknown = records
            .filter { $0.toolIdentifier == nil }
            .sorted { $0.toolRootPath < $1.toolRootPath }

        let tools = (identified + unknown).map { record in
            let id = record.toolIdentifier ?? record.toolRootPath
            return ConfirmedTool(
                id: id,
                displayName: displayName(forToolID: id, toolRootPath: record.toolRootPath, rules: rules),
                toolRootPath: record.toolRootPath
            )
        }

        // 兜底去重：上一步按工具标识收敛了**有规则可依**的记录，这里再按 `ConfirmedTool`
        // 的排序规则收一次——未知工具用路径当标识，与某条有标识的记录撞上同一条路径时
        // （同一个目录先被当作不确定、后来又被确认），不能被扫两遍。
        return ConfirmedTool.normalized(tools)
    }

    // MARK: - 内部

    /// **两个入口共用的核心**：给定已准入的规则与已确认的工具，扫出报告。
    ///
    /// `run()` 与 `scan(_:)` 都收敛到这里，所以「同一台工具只扫一次」「结果与输入顺序无关」
    /// 这些纪律只有一处实现，两条入口给不出互相矛盾的报告。
    private func scan(
        tools: [ConfirmedTool],
        rules: RuleAdmissionReport
    ) -> DeepScanReport {
        scanner.scan(
            tools: tools,
            rules: rules,
            homeDirectory: configuration.homeDirectory
        )
    }

    /// 加载规则并走规则集准入。目录缺失或一条都没载入都给问题，不静默。
    ///
    /// 注入式装配（概览页入口，`ruleDirectory == nil`）直接用注入的规则集：
    /// 它在构造时就已过准入，这里不重复加载。
    private func loadUsableRules() -> (rules: RuleAdmissionReport, issues: [DeepScanIssue]) {
        let admitted = admittedRules
        guard !admitted.usableRules.isEmpty else {
            // 一条可用规则都没有：可能是一条规则都没读到，也可能是读到了但全部未过准入。
            // 两者的区别对用户有意义（前者多半是打包漏了资源，后者是规则本身有问题），
            // 因此按「有没有加载到规则」分开说话。
            if configuration.ruleDirectory != nil, let directory = configuration.ruleDirectory {
                let loaded = RuleLoader.loadRules(inDirectory: directory)
                if loaded.rules.isEmpty {
                    return (admitted, [.noRulesLoaded])
                }
                return (admitted, [.noUsableRules(rejectedCount: admitted.rejections.count)])
            }
            return (admitted, [.noRulesLoaded])
        }
        return (admitted, [])
    }

    /// 规则里的展示名；没有规则可依据时退化成路径（`~/.mystery`），不编造名字。
    private func displayName(forToolID id: String, toolRootPath: String, rules: RuleAdmissionReport) -> String {
        rules.usableRule(id: id)?.displayName
            ?? ToolRootDisplay.abbreviated(toolRootPath, homeDirectory: configuration.homeDirectory)
    }

    /// 两条同 id 记录里哪一条该留下：规则声明的工具根优先，其次路径字典序小者。
    private func isPreferred(
        _ candidate: ConfirmationRecord,
        over current: ConfirmationRecord,
        toolID: String,
        rules: RuleAdmissionReport
    ) -> Bool {
        let declared = declaredToolRootPaths(forToolID: toolID, rules: rules)
        let candidateIsDeclared = declared.contains(normalized(candidate.toolRootPath))
        let currentIsDeclared = declared.contains(normalized(current.toolRootPath))
        if candidateIsDeclared != currentIsDeclared { return candidateIsDeclared }
        return normalized(candidate.toolRootPath) < normalized(current.toolRootPath)
    }

    /// 规则为该工具声明的主工具根（展开 `~` 后归一），用于去重时的优先级判定。
    private func declaredToolRootPaths(forToolID id: String, rules: RuleAdmissionReport) -> Set<String> {
        let roots = rules.usableRule(id: id)?.roots ?? []
        return Set(
            roots
                .filter { $0.role == .toolRoot }
                .map { normalized($0.absolutePath(homeDirectory: configuration.homeDirectory)) }
        )
    }

    /// 只做路径归一（去重复与尾随分隔符、消掉 `.` / `..`），**不解析符号链接**：
    /// 这里比的是记录与规则声明的字面路径，解析链接反而会把不同位置当成同一个。
    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

extension ConfirmedTool {

    /// 按**工具标识**去重，并给出确定的顺序。
    ///
    /// 确认存储以工具根路径为键，而深扫的输入是「一台台工具」：同一条规则被确认出两条记录时，
    /// 不去重就会把这台工具扫两遍——规则声明的**仅展示根**（issue #31：Cursor 的
    /// `~/Library/Application Support/Cursor` 14G）因此被算两遍，占用直接翻倍。
    ///
    /// 多条记录撞同一个标识时保留**工具根路径字典序最小**的那条。
    ///
    /// 这是**不知道规则时**的兜底次序：`DeepScanService.confirmedTools(from:)` 在有规则可依时
    /// 会先把「规则声明的工具根」挑出来（见 `isPreferred`），再落到这里收敛。
    /// 两级次序的目标是同一个：同样的输入永远给同样的结果，且同一台工具只算一次。
    public static func normalized(_ tools: [ConfirmedTool]) -> [ConfirmedTool] {
        var seen = Set<String>()
        return tools
            .sorted { ($0.id, $0.toolRootPath) < ($1.id, $1.toolRootPath) }
            .filter { seen.insert($0.id).inserted }
    }
}
