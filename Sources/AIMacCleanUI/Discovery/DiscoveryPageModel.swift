import Combine
import Foundation

import AIMacCleanDomain

/// 发现与确认页的视图模型（issue #16）。
///
/// 页面里所有会出错的状态都在这里：分档、折叠、决定落盘、移出列表 / 加回、
/// 权限提示、加载失败。视图只做渲染与转发，因此这一层可以在没有窗口的情况下测。
///
/// ## 不变式
///
/// 1. **只显示还需要问用户的候选**（PRD §4.1 第 4 步）：确认与忽略都会留下记录，
///    有记录的不再出现在待确认列表里——下次启动（换一个模型实例）同样不会重复询问。
/// 2. **「疑似」默认折叠**（User Story 4）：纯名称命中、没有结构证据的候选
///    归到「低」档，默认收起。用户手动展开后，重新扫描不会把它折回去。
/// 3. **决定立刻落盘**：每个动作都直接写确认存储，失败就把原因摆在界面上，
///    不做「先改界面、稍后再说」。
/// 4. **诚实**：没有体积、没有分类、没有归档收益（本阶段是里程碑 1）。
/// 5. **不预先索权**：只有真的遇到授权失败才提示，并列出**具体哪些位置**没扫到。
public final class DiscoveryPageModel: ObservableObject {

    /// 界面读的那一份状态。
    @Published public private(set) var state: DiscoveryPageState

    private let source: DiscoverySource
    private let store: ConfirmationStore
    private let settings: ConfirmationSettings?
    private let homeDirectory: String
    private let now: () -> Date

    /// 用户手动改过的折叠状态，跨重新扫描保留。
    private var expansionOverrides: [ConfidenceTier: Bool] = [:]

    /// 一次运行的结果缓存：决定落盘后要重排列表，不必重新扫描磁盘。
    private var latestRun: DiscoveryRun

    /// - Parameters:
    ///   - source: 发现管线（生产用 `DiscoveryService`，测试给固定结果）。
    ///   - store: 确认存储。决定、移出列表、加回都直接写它。
    ///   - settings: 设置项（纯名称候选是否默认折叠）。传 `nil` 时按默认值处理。
    ///   - homeDirectory: 路径展示用的主目录，由调用方注入，测试才不用碰真实主目录。
    ///   - now: 决定时刻的时钟，由调用方注入。
    public init(
        source: DiscoverySource,
        store: ConfirmationStore,
        settings: ConfirmationSettings?,
        homeDirectory: String,
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.store = store
        self.settings = settings
        self.homeDirectory = homeDirectory
        self.now = now
        self.latestRun = DiscoveryRun()
        self.state = DiscoveryPageState()
    }

    /// 应用启动时用的入口：真实规则目录与本机确认存储（不读 PATH，不列举通用位置）。
    public static func standard(
        store: ConfirmationStore = JSONConfirmationStore.standard(),
        settings: ConfirmationSettings? = ConfirmationSettings.standard(),
        homeDirectory: String = NSHomeDirectory()
    ) -> DiscoveryPageModel {
        DiscoveryPageModel(
            source: DiscoveryService.standard(homeDirectory: homeDirectory),
            store: store,
            settings: settings,
            homeDirectory: homeDirectory
        )
    }

    // MARK: - 生命周期

    /// 跑一次发现并铺开状态。视图出现时调用；重复调用等价于重新扫描。
    public func load() {
        latestRun = source.run()
        rebuildState()
    }

    /// 「重新扫描」按钮。
    public func reload() {
        load()
    }

    // MARK: - 决定

    /// 确认某个候选是 AI 工具（GLOSSARY「工具」），立即落盘（User Stories 15、16、19）。
    public func confirm(toolRootPath: String) {
        decide(toolRootPath: toolRootPath, decision: .confirmed)
    }

    /// 忽略某个候选，立即落盘（忽略同样是一种用户判断，下次不再询问）。
    public func ignore(toolRootPath: String) {
        decide(toolRootPath: toolRootPath, decision: .ignored)
    }

    /// 把已确认的工具**移出列表**，也就是忘掉这条确认记录（User Story 17）。
    ///
    /// 记录不再存在，因此该候选会重新变成待确认。动作完全可逆：再确认一次就回来。
    public func forgetConfirmedTool(toolRootPath: String) {
        perform {
            try self.store.forgetTool(atToolRootPath: toolRootPath)
        }
    }

    // MARK: - 键盘（User Story 41）

    /// 一个候选行上两个动作的标识。键盘与按钮走的是**同一组**方法——
    /// 因此「只用键盘完成确认与忽略」与「用鼠标点」行为完全一致，不存在两套语义。
    public enum RowAction: CaseIterable, Sendable {
        /// 主操作：确认是 AI 工具。
        case confirm
        /// 次操作：忽略。
        case ignore
    }

    /// 键盘主操作（Return）：确认当前行。
    public func performDefaultAction(onToolRootPath path: String) {
        confirm(toolRootPath: path)
    }

    /// 键盘次操作：忽略当前行。
    public func performSecondaryAction(onToolRootPath path: String) {
        ignore(toolRootPath: path)
    }

    /// 某个动作的快捷键说明，供视图挂到按钮上（辅助技术也会读它）。
    public func keyboardShortcut(for action: RowAction) -> String? {
        switch action {
        case .confirm: return Self.confirmShortcut
        case .ignore: return Self.ignoreShortcut
        }
    }

    /// Return：候选行里最常用的那个动作（确认）。
    static let confirmShortcut = "↩"
    /// ⌘I：忽略。与确认不同键，因此两只手都能停在同一个位置完成两步。
    static let ignoreShortcut = "⌘I"

    /// 把之前忽略的候选加回候选列表（User Story 18）。
    ///
    /// 底下的动作和「移出列表」是**同一个**：忘掉那条「忽略」记录。
    /// 叫 `restoreIgnored` 会撞上 GLOSSARY 的「还原」——那个词专指把归档的会话
    /// 按清单写回原路径（不可逆动作的对立面），不是「让一条判断消失」。
    public func forgetIgnoredCandidate(toolRootPath: String) {
        perform {
            try self.store.forgetTool(atToolRootPath: toolRootPath)
        }
    }

    private func decide(toolRootPath: String, decision: ToolDecision) {
        guard let candidate = candidate(forToolRootPath: toolRootPath) else {
            // 候选已经不在列表里（例如刚被重新扫描掉了）：不是错误，也不写记录。
            return
        }
        perform {
            try self.store.decide(
                toolIdentifier: candidate.ruleIdentifier,
                toolRootPath: candidate.toolRootPath,
                decision: decision,
                // 记录**决定当时**命中的信号，几个月后还能理解当初为什么这么判（User Story 19）。
                signals: candidate.signals,
                decidedAt: self.now()
            )
        }
    }

    /// 执行一次写操作，成功后重排界面，失败把原因摆在界面上。
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            state.lastActionFailure = nil
        } catch {
            state.lastActionFailure = error.localizedDescription
        }
        rebuildState()
    }

    // MARK: - 折叠

    /// 展开 / 折叠某一档（User Story 4 的另一半：折叠不是终点，用户要能自己打开）。
    public func setExpanded(_ expanded: Bool, for tier: ConfidenceTier) {
        expansionOverrides[tier] = expanded
        rebuildState()
    }

    public func toggleExpanded(for tier: ConfidenceTier) {
        let current = state.pendingGroups.first { $0.tier == tier }?.isExpanded ?? defaultExpansion(for: tier)
        setExpanded(!current, for: tier)
    }

    // MARK: - 呈现

    /// 某个候选的界面文案（可见文字与辅助功能文字）。
    public func presentation(for candidate: Candidate) -> CandidatePresentation {
        CandidatePresentation(
            displayPath: candidate.displayPath,
            confidenceText: confidenceText(for: candidate.confidence),
            isSuspicious: candidate.isSuspicious,
            signalTexts: Self.signalTexts(for: candidate.signals),
            demotionTexts: Self.demotionTexts(for: candidate.demotions),
            isProtected: candidate.protection != nil
        )
    }

    /// 置信度的展示文案（本地化，不在视图里硬编码）。
    public func confidenceText(for tier: ConfidenceTier) -> String {
        switch tier {
        case .high: return L10n.text(.discoveryConfidenceHigh)
        case .medium: return L10n.text(.discoveryConfidenceMedium)
        case .low: return L10n.text(.discoveryConfidenceLow)
        }
    }

    /// 分组标题（本地化）。
    public func groupTitle(for tier: ConfidenceTier) -> String {
        switch tier {
        case .high: return L10n.text(.discoveryGroupHigh)
        case .medium: return L10n.text(.discoveryGroupMedium)
        case .low: return L10n.text(.discoveryGroupLow)
        }
    }

    // MARK: - 权限与加载失败（PRD §4.4）

    /// 这次没能扫描的位置，逐条一句，**点名具体路径**。
    ///
    /// 没有读不到的目录时返回空数组——界面上因此不会凭空出现任何权限相关的话术，
    /// 更不会主动引导去申请完全磁盘访问（PRD §4.4：不要无条件索权）。
    public var permissionNoticeTexts: [String] {
        state.unreadableDirectories.map {
            L10n.format(.discoveryPermissionRow, [$0.path, $0.reason])
        }
    }

    /// 权限提示的标题（没有读到任何位置时不该显示）。
    public var permissionNoticeTitle: String? {
        permissionNoticeTexts.isEmpty ? nil : L10n.text(.discoveryPermissionTitle)
    }

    /// 权限提示脚注：说明这条提示只在真的遇到授权失败时出现。
    public var permissionNoticeFootnote: String {
        L10n.text(.discoveryPermissionFootnote)
    }

    /// 运行级问题（规则没载入、词表没读到）的可读说明。
    public var issueTexts: [String] {
        state.issues.map { issue in
            switch issue {
            case .noRulesLoaded:
                return L10n.text(.discoveryIssueNoRules)
            case let .hintsUnavailable(reason):
                return L10n.format(.discoveryIssueHintsUnavailable, [reason])
            case let .noUsableRules(rejectedCount):
                return L10n.format(.discoveryIssueRulesRejected, ["\(rejectedCount)"])
            }
        }
    }

    /// 最近一次写记录失败的原因（`nil` 表示没有失败）。
    public var actionFailureText: String? {
        state.lastActionFailure.map { L10n.format(.discoveryIssueActionFailed, [$0]) }
    }

    // MARK: - 内部

    private func candidate(forToolRootPath path: String) -> Candidate? {
        latestRun.result.candidates.first { $0.toolRootPath == path }
    }

    /// 依当前存储里的记录重算整屏状态。
    ///
    /// 不重新扫描磁盘：决定 / 移出列表 / 加回都只改记录，候选本身没变。
    private func rebuildState() {
        let result = latestRun.result
        let pendingPaths = Set(store.pendingToolRootPaths(amongCandidates: result.candidateToolRootPaths))
        let pending = result.candidates.filter { pendingPaths.contains($0.toolRootPath) }

        state.pendingGroups = [ConfidenceTier.high, .medium, .low].compactMap { tier in
            let candidates = pending.filter { $0.confidence == tier }
            guard !candidates.isEmpty else { return nil }
            return CandidateGroup(
                tier: tier,
                candidates: candidates,
                isExpanded: expansionOverrides[tier] ?? defaultExpansion(for: tier)
            )
        }
        state.confirmedTools = store.confirmedTools.map { record in
            ConfirmedToolRow(record: record, displayPath: Self.displayPath(for: record, candidates: result.candidates, homeDirectory: homeDirectory))
        }
        state.ignoredCandidates = store.ignoredCandidates.map { record in
            IgnoredCandidateRow(record: record, displayPath: Self.displayPath(for: record, candidates: result.candidates, homeDirectory: homeDirectory))
        }
        state.unreadableDirectories = result.unreadableDirectories
        state.issues = latestRun.issues
        state.hasLoaded = true
    }

    /// 「低」档（纯名称命中）默认折叠；其余展开（User Story 4）。
    private func defaultExpansion(for tier: ConfidenceTier) -> Bool {
        guard tier == .low else { return true }
        return !(settings?.collapsesNameOnlyCandidates ?? true)
    }

    /// 候选自带展示路径（`~/.codex`）；已不在候选列表里的记录按主目录缩写。
    private static func displayPath(
        for record: ConfirmationRecord,
        candidates: [Candidate],
        homeDirectory: String
    ) -> String {
        candidates.first { $0.toolRootPath == record.toolRootPath }?.displayPath
            ?? ToolRootDisplay.abbreviated(record.toolRootPath, homeDirectory: homeDirectory)
    }

    /// 命中的信号逐条成句（User Story 19：几个月后还看得懂当初为什么这么判）。
    static func signalTexts(for signals: ConfirmationSignals) -> [String] {
        var texts = signals.structuralFingerprints.map {
            L10n.format(.discoverySignalStructural, [$0])
        }
        texts += signals.nameMatches.map { L10n.format(.discoverySignalName, [$0]) }
        texts += signals.externalCorroborations.map { corroboration in
            switch corroboration {
            case let .application(name):
                return L10n.format(.discoverySignalApplication, [name])
            case let .command(name):
                return L10n.format(.discoverySignalCommand, [name])
            case let .contentFeature(description):
                return L10n.format(.discoverySignalContentFeature, [description])
            }
        }
        return texts
    }

    /// 降权 / 降档原因逐条成句。
    static func demotionTexts(for demotions: [CandidateDemotion]) -> [String] {
        demotions.map { demotion in
            switch demotion {
            case let .negativeNamePattern(pattern):
                return L10n.format(.discoveryDemotionNegativeName, [pattern])
            case .missingStructuralFingerprint:
                return L10n.text(.discoveryDemotionMissingFingerprint)
            }
        }
    }
}
