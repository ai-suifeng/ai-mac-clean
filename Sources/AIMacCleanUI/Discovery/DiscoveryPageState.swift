import Foundation

import AIMacCleanDomain

/// 发现与确认页的一屏状态（issue #16）。
///
/// 这是**给界面用的完整快照**：视图不再自己算分组、排序、可访问性文案，
/// 也不直接读确认存储。整个页面因此可以被一行测试断言。
public struct DiscoveryPageState: Equatable {

    /// 待确认候选，按置信度高 → 中 → 低分组；空分档不出现。
    public var pendingGroups: [CandidateGroup]

    /// 已确认的工具（GLOSSARY「工具」），带「移出列表」入口。
    public var confirmedTools: [ConfirmedToolRow]

    /// 已忽略的候选，带「加回」入口。
    public var ignoredCandidates: [IgnoredCandidateRow]

    /// 这次没能扫描的位置（权限不足等），逐条列出**具体路径**（PRD §4.4、User Story 37）。
    public var unreadableDirectories: [UnreadableDirectory]

    /// 运行级问题（规则没载入、词表没读到），逐条可读。
    public var issues: [DiscoveryIssue]

    /// 最近一次写确认记录失败的原因。`nil` 表示没有失败。
    public var lastActionFailure: String?

    /// 是否已经跑过一次发现。
    public var hasLoaded: Bool

    /// 是否正在扫描（issue #21）。扫描在后台跑，界面据此禁用「重新扫描」并给出进度提示。
    public var isScanning: Bool

    public init(
        pendingGroups: [CandidateGroup] = [],
        confirmedTools: [ConfirmedToolRow] = [],
        ignoredCandidates: [IgnoredCandidateRow] = [],
        unreadableDirectories: [UnreadableDirectory] = [],
        issues: [DiscoveryIssue] = [],
        lastActionFailure: String? = nil,
        hasLoaded: Bool = false,
        isScanning: Bool = false
    ) {
        self.pendingGroups = pendingGroups
        self.confirmedTools = confirmedTools
        self.ignoredCandidates = ignoredCandidates
        self.unreadableDirectories = unreadableDirectories
        self.issues = issues
        self.lastActionFailure = lastActionFailure
        self.hasLoaded = hasLoaded
        self.isScanning = isScanning
    }
}

/// 一档置信度的候选分组。
public struct CandidateGroup: Equatable, Identifiable {

    /// 置信度档位（高 / 中 / 低）。
    public let tier: ConfidenceTier

    /// 该档的候选，顺序沿用发现器的排序（高 → 中 → 低，同档内名字命中的在前）。
    public let candidates: [Candidate]

    /// 该分组当前是否展开。纯名称命中的「疑似」分组默认折叠（User Story 4）。
    public var isExpanded: Bool

    public var id: String { tier.rawValue }

    public init(tier: ConfidenceTier, candidates: [Candidate], isExpanded: Bool) {
        self.tier = tier
        self.candidates = candidates
        self.isExpanded = isExpanded
    }
}

/// 已确认工具的一行。
public struct ConfirmedToolRow: Equatable, Identifiable {

    public let record: ConfirmationRecord

    /// 给用户看的路径（`~/.codex` 形式）。
    public let displayPath: String

    public var id: String { record.toolRootPath }
}

/// 已忽略候选的一行。
public struct IgnoredCandidateRow: Equatable, Identifiable {

    public let record: ConfirmationRecord

    /// 给用户看的路径。
    public let displayPath: String

    public var id: String { record.toolRootPath }
}

/// 一个候选在界面上的呈现文案（可见文字 + 辅助功能读出的文字）。
///
/// 单独成类型是为了让「候选与置信度能被辅助技术读出」（User Story 42）可以被断言，
/// 而不是只能靠看界面。所有文案来自 `L10n`，不在这里硬编码。
public struct CandidatePresentation: Equatable {

    public let displayPath: String
    /// 置信度（高 / 中 / 低）。
    public let confidenceText: String
    /// 是否标「疑似」。
    public let isSuspicious: Bool
    /// 命中的信号，逐条一句（结构指纹 / 名称 / 外部佐证）。
    public let signalTexts: [String]
    /// 降权原因，逐条一句。
    public let demotionTexts: [String]
    /// 是否命中内置受保护条目。
    public let isProtected: Bool

    /// 辅助功能读出的标签：路径 + 置信度。
    public var accessibilityLabel: String {
        L10n.format(.candidateAccessibility, [displayPath, confidenceText])
    }

    /// 辅助功能读出的补充值：疑似标记 + 信号 + 降权原因。
    public var accessibilityValue: String {
        ([isSuspicious ? L10n.text(.discoverySuspiciousBadge) : nil]
            + signalTexts
            + demotionTexts
            + (isProtected ? [L10n.text(.discoveryProtectionNote)] : []))
            .compactMap { $0 }
            .joined(separator: "；")
    }
}
