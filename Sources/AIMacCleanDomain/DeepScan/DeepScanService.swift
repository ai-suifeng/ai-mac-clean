import Foundation

import AIMacCleanCore
import AIMacCleanRules

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

/// 生产实现：确认记录 → 深扫输入 → `DeepScanner`。
///
/// ## 为什么要有这一层
///
/// `DeepScanner` 的输入是 `ConfirmedTool`（工具标识 + 展示名 + 工具根）与**已准入的规则**，
/// 两者都带规则层类型。界面拿不到也不该拿到它们，因此映射放在这里一次做完：
/// 工具标识来自确认记录，展示名来自规则（`Claude Code`，而不是 `claude-code` 或路径）。
///
/// ## 同一个工具标识只扫一次（#31）
///
/// 一个工具标识可能有多条确认记录（用户确认过 `~/.claude`，又确认过一个同结构的备份目录）。
/// 逐条扫会把规则声明的**仅展示根**算两遍——Cursor 的 14G AppSupport 因此会变成 28G，
/// 概览页的总占用随之虚高。这里按工具标识去重，保留哪一条有明确次序：
/// 规则声明的工具根优先（它就是归档范围），其余按路径字典序取最小的一条，
/// 保证结果与输入顺序无关、可复现。
///
/// 去重的代价说清楚：同一个工具标识的**其它**根不再计入概览占用（少报，不虚报）；
/// 它们仍然出现在「发现与确认」页的已确认列表里。宁可少报，也不许把同一块空间算两遍。
public struct DeepScanService: ConfirmedToolScanning {

    private let rules: RuleAdmissionReport
    private let homeDirectory: String
    private let scanner: any DeepScanning

    /// - Parameters:
    ///   - rules: **已过** `RuleSetAdmission` 的规则集（保护单调性已经生效）。
    ///   - homeDirectory: `~/…` 展开与路径缩写用的主目录。显式传入，本层不读 `NSHomeDirectory()`。
    ///   - scanner: 深扫器。测试注入记录型文件系统后，可以断言这条路径同样零写入。
    public init(
        rules: RuleAdmissionReport,
        homeDirectory: String,
        scanner: any DeepScanning = DeepScanner()
    ) {
        self.rules = rules
        self.homeDirectory = homeDirectory
        self.scanner = scanner
    }

    /// 应用启动时用的入口：加载内置规则 → 规则集准入 → 真实深扫器。
    ///
    /// 规则资源没打进应用包时（里程碑 6 的打包风险，见 `DiscoveryService.standard` 的说明），
    /// 这里得到一份空规则集：每台已确认工具仍会拿到一份零占用的报告（`DeepScanner` 的
    /// 「不静默丢弃」约定），而不是整页报错。
    public static func standard(
        homeDirectory: String = NSHomeDirectory(),
        ruleDirectory: URL? = BuiltInRuleResources.directory,
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem()
    ) -> DeepScanService {
        DeepScanService(
            rules: admittedRules(inDirectory: ruleDirectory, homeDirectory: homeDirectory),
            homeDirectory: homeDirectory,
            scanner: DeepScanner(fileSystem: fileSystem)
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

    public func scan(_ records: [ConfirmationRecord]) -> DeepScanReport {
        scanner.scan(
            tools: confirmedTools(from: records),
            rules: rules,
            homeDirectory: homeDirectory
        )
    }

    /// 确认记录 → 深扫输入：按工具标识去重，展示名取规则里的名字。
    ///
    /// 未知工具（记录里没有工具标识）**不参与去重**：它们没有规则可依据，
    /// 每一条记录都是一个独立的目录，用路径当标识与展示名（GLOSSARY「不确定」）。
    public func confirmedTools(from records: [ConfirmationRecord]) -> [ConfirmedTool] {
        let identified = records
            .filter { $0.toolIdentifier != nil }
            .reduce(into: [String: ConfirmationRecord]()) { chosen, record in
                guard let id = record.toolIdentifier else { return }
                guard let current = chosen[id] else {
                    chosen[id] = record
                    return
                }
                if isPreferred(record, over: current, toolID: id) {
                    chosen[id] = record
                }
            }
            .values
            .sorted { ($0.toolIdentifier ?? "") < ($1.toolIdentifier ?? "") }

        let unknown = records
            .filter { $0.toolIdentifier == nil }
            .sorted { $0.toolRootPath < $1.toolRootPath }

        return (identified + unknown).map { record in
            let id = record.toolIdentifier ?? record.toolRootPath
            return ConfirmedTool(
                id: id,
                displayName: displayName(forToolID: id, toolRootPath: record.toolRootPath),
                toolRootPath: record.toolRootPath
            )
        }
    }

    // MARK: - 内部

    /// 规则里的展示名；没有规则可依据时退化成路径（`~/.mystery`），不编造名字。
    private func displayName(forToolID id: String, toolRootPath: String) -> String {
        rules.usableRule(id: id)?.displayName
            ?? ToolRootDisplay.abbreviated(toolRootPath, homeDirectory: homeDirectory)
    }

    /// 两条同 id 记录里哪一条该留下：规则声明的工具根优先，其次路径字典序小者。
    private func isPreferred(
        _ candidate: ConfirmationRecord,
        over current: ConfirmationRecord,
        toolID: String
    ) -> Bool {
        let declared = declaredToolRootPaths(forToolID: toolID)
        let candidateIsDeclared = declared.contains(normalized(candidate.toolRootPath))
        let currentIsDeclared = declared.contains(normalized(current.toolRootPath))
        if candidateIsDeclared != currentIsDeclared { return candidateIsDeclared }
        return normalized(candidate.toolRootPath) < normalized(current.toolRootPath)
    }

    /// 规则为该工具声明的主工具根（展开 `~` 后归一），用于去重时的优先级判定。
    private func declaredToolRootPaths(forToolID id: String) -> Set<String> {
        let roots = rules.usableRule(id: id)?.roots ?? []
        return Set(
            roots
                .filter { $0.role == .toolRoot }
                .map { normalized($0.absolutePath(homeDirectory: homeDirectory)) }
        )
    }

    /// 只做路径归一（去重复与尾随分隔符、消掉 `.` / `..`），**不解析符号链接**：
    /// 这里比的是记录与规则声明的字面路径，解析链接反而会把不同位置当成同一个。
    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
