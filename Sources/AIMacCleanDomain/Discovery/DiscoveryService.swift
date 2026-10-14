import Foundation

import AIMacCleanCore
import AIMacCleanRules

/// 一次发现的结果 + **这次没能完成的部分**（issue #16）。
///
/// `DiscoveryResult` 只讲「扫到了什么」，界面还需要讲「有什么没扫到、有什么没配上」——
/// 规则资源没打进包、词表读不出来这类问题如果不进结果，界面就只能说一句
/// 「没有候选」，用户无从判断是机器上真没有工具，还是软件自己没配好。
public struct DiscoveryRun: Equatable, Sendable {

    /// 候选与读不到的目录。
    public let result: DiscoveryResult

    /// 这次运行的已知问题（逐条可读）。
    public let issues: [DiscoveryIssue]

    public init(result: DiscoveryResult = DiscoveryResult(), issues: [DiscoveryIssue] = []) {
        self.result = result
        self.issues = issues
    }
}

/// 一次发现里「没能完成的那部分」。
public enum DiscoveryIssue: Equatable, Sendable {

    /// 一条规则都没加载进来——候选列表必然是空的，而且这不是用户机器的问题。
    ///
    /// 单独成为一条 issue 而不是让发现器返回空结果：空结果长得和「真没装工具」一模一样，
    /// 那会让用户以为机器上真的没有 AI 工具（issue #15 记录的 `Bundle.module` 打包风险）。
    case noRulesLoaded

    /// 关键词 / 负向名单词表读不出来。发现仍然继续，只是少了排序与降权。
    case hintsUnavailable(reason: String)

    /// 规则文件读到了，但**一条都没通过准入**（全部被保护单调性拒绝等）。
    case noUsableRules(rejectedCount: Int)
}

extension DiscoveryIssue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noRulesLoaded:
            return "没有加载到任何内置规则文件，候选列表为空。"
        case let .hintsUnavailable(reason):
            return "关键词 / 负向名单词表没读到：\(reason)"
        case let .noUsableRules(rejectedCount):
            return "加载到 \(rejectedCount) 条规则，但全部未通过规则集准入（保护单调性校验），候选列表为空。"
        }
    }
}

/// 发现管线的运行入口（issue #16 的接线处）。
///
/// 单独成协议是为了让**界面状态机**不依赖文件系统：视图模型的测试给一个固定结果，
/// 生产接线（真实规则目录、`/Applications`、PATH）由 `DiscoveryService` 提供。
/// spec #7 没有为发现管线之外的接线单开 seam，因此这里不开测试 seam，
/// 只保证两者的形状一致。
public protocol DiscoverySource {
    func run() -> DiscoveryRun
}

/// 生产环境的发现接线（issue #16；把 #12/#15 的零件真正接起来）。
///
/// 一次 `run()` 依次做三件事，顺序本身就是纪律：
/// 1. **加载内置规则** → 规则集准入 → 可用规则集（保护单调性在这一步生效）。
/// 2. **采集外部佐证**：同名 App（`/Applications`、`~/Applications`）与 PATH 中的命令。
///    这一步**必须**发生在打分之前，否则「高置信度」永远拿不到（User Story 10）。
/// 3. **浅扫**：只遍历扫描根的一级子目录，产出候选与读不到的目录。
///
/// 全部输入（主目录、规则目录、词表、应用目录、PATH）都由调用方注入——
/// 测试才能全部跑在临时目录上（PRD §13 第 3 条）。
public struct DiscoveryService: DiscoverySource {

    /// 运行一次发现需要的所有外部输入。
    public struct Configuration: Equatable, Sendable {

        /// 主目录绝对路径（`~` 的展开基准）。
        public var homeDirectory: String

        /// 内置规则目录。`nil` 表示资源没找到（见下方打包说明）。
        public var ruleDirectory: URL?

        /// 关键词 / 负向名单词表文件。文件不存在不算错误（词表是可选配置）。
        public var hintsFileURL: URL?

        /// 采集同名 App 的目录（`/Applications`、`~/Applications`）。
        public var applicationDirectories: [String]

        /// 采集 PATH 命令的目录。
        public var commandSearchPaths: [String]

        public init(
            homeDirectory: String,
            ruleDirectory: URL?,
            hintsFileURL: URL? = nil,
            applicationDirectories: [String] = [],
            commandSearchPaths: [String] = []
        ) {
            self.homeDirectory = homeDirectory
            self.ruleDirectory = ruleDirectory
            self.hintsFileURL = hintsFileURL
            self.applicationDirectories = applicationDirectories
            self.commandSearchPaths = commandSearchPaths
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// 应用启动时用的入口：真实 `/Applications`、`~/Applications` 与 `PATH`。
    ///
    /// ## 打包注意（issue #15 记录的风险，此处是唯一一处需要留意的地方）
    ///
    /// 规则文件走 SwiftPM 的 `Bundle.module` 解析，它在可执行文件旁边找资源 bundle。
    /// `swift run` 时这成立；打成 `.app` 之后资源 bundle 会被搬进
    /// `Contents/Resources/`（或 `Contents/Resources/<BundleID>_<Package>.bundle`），
    /// `Bundle.module` 的查找位置随之改变。**因此 `.app` 打包必须把规则资源 bundle
    /// 一并嵌入**（里程碑 6 的打包步骤）；万一漏了，`run()` 不会静默返回空列表——
    /// 它会给出 `DiscoveryIssue.noRulesLoaded`，界面上明确写出「候选为空是配置问题，
    /// 不是你机器上没装工具」。
    public static func standard(
        homeDirectory: String = NSHomeDirectory(),
        ruleDirectory: URL? = BuiltInRuleResources.directory,
        hintsFileURL: URL? = defaultHintsFileURL(),
        applicationDirectories: [String]? = nil,
        commandSearchPaths: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DiscoveryService {
        DiscoveryService(
            configuration: Configuration(
                homeDirectory: homeDirectory,
                ruleDirectory: ruleDirectory,
                hintsFileURL: hintsFileURL,
                applicationDirectories: applicationDirectories
                    ?? ["/Applications", homeDirectory + "/Applications"],
                commandSearchPaths: commandSearchPaths
                    ?? (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            )
        )
    }

    /// 词表默认放在应用支持目录下，与确认记录同属一地（`docs/discovery-hints.md`：
    /// 「放在应用支持目录下，随版本一起更新；路径由调用方给出」）。
    public static func defaultHintsFileURL(fileManager: FileManager = .default) -> URL? {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return root
            .appendingPathComponent(JSONConfirmationStore.directoryName, isDirectory: true)
            .appendingPathComponent("discovery-hints.json", isDirectory: false)
    }

    public func run() -> DiscoveryRun {
        var issues: [DiscoveryIssue] = []

        let (rules, ruleIssues) = loadUsableRules()
        issues.append(contentsOf: ruleIssues)

        let hints = loadHints(issues: &issues)

        let evidence = ExternalEvidenceCollector.detect(
            applicationDirectories: configuration.applicationDirectories,
            commandSearchPaths: configuration.commandSearchPaths
        )

        let discoverer = ToolDiscoverer(
            rules: rules,
            hints: hints,
            externalEvidence: evidence,
            homeDirectory: configuration.homeDirectory
        )

        return DiscoveryRun(result: discoverer.discover(), issues: issues)
    }

    // MARK: - 内部

    /// 加载规则文件并走规则集准入。规则目录缺失或一条都没载入都给 issue，不静默。
    private func loadUsableRules() -> (rules: [ToolRule], issues: [DiscoveryIssue]) {
        guard let directory = configuration.ruleDirectory else {
            return ([], [.noRulesLoaded])
        }
        let report = RuleLoader.loadRules(inDirectory: directory)
        guard !report.rules.isEmpty else {
            return ([], [.noRulesLoaded])
        }

        let admission = RuleSetAdmission.admit(
            rules: report.rules,
            homeDirectory: configuration.homeDirectory
        )
        var issues: [DiscoveryIssue] = []
        if admission.usableRules.isEmpty {
            issues.append(.noUsableRules(rejectedCount: admission.rejections.count))
        }
        return (admission.usableRules, issues)
    }

    /// 词表读不出来**不算致命**：发现照常进行，只是少了排序与降权，
    /// 但必须说得出来（`docs/discovery-hints.md`：词表错了要看得见）。
    private func loadHints(issues: inout [DiscoveryIssue]) -> DiscoveryHints {
        guard let url = configuration.hintsFileURL else { return .none }
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        do {
            return try DiscoveryHints.load(from: url)
        } catch {
            issues.append(.hintsUnavailable(reason: error.localizedDescription))
            return .none
        }
    }
}

/// 工具根目录路径的展示适配（UI 层只依赖 Domain，不直接引 Core）。
///
/// 只做缩写展示（`~/.codex`），**不做任何安全判定**——受保护判定在 Rules 层。
public enum ToolRootDisplay {
    public static func abbreviated(_ path: String, homeDirectory: String) -> String {
        DisplayPath.abbreviate(path, homeDirectory: homeDirectory)
    }
}
