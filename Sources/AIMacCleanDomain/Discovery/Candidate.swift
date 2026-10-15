import Foundation

import AIMacCleanRules

/// 候选的置信度三档（spec #7 §置信度模型、PRD §4.3）。
///
/// 置信度是**候选的属性**，不改变候选是否入列：分档只影响展示顺序与默认折叠。
public enum ConfidenceTier: String, CaseIterable, Comparable, Sendable {
    /// 高：结构指纹 **+** 外部佐证（规则声明的安装路径命中 / 会话文件字段特征）。
    case high
    /// 中：仅结构指纹命中。
    case medium
    /// 低：仅名称命中（没有结构证据），标记为「疑似」、默认折叠（User Story 4）。
    case low

    /// 排序用的序数：档位越高越可信。
    var rank: Int {
        switch self {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    public static func < (lhs: ConfidenceTier, rhs: ConfidenceTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

extension ConfidenceTier: CustomStringConvertible {
    /// 界面展示用中文档位名（PRD §4.3：高 / 中 / 低）。
    public var displayText: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    public var description: String { displayText }
}

/// 候选被降权 / 降档的原因。
///
/// 单独记一条而不是拍平成字符串：确认记录里要能分清「因为命中负向名单」
/// 与「因为根本没有结构证据」——几个月后回看，这两句话的含义完全不同
/// （User Story 19）。
public enum CandidateDemotion: Equatable, Sendable {
    /// 命中负向名单（`*-bak`、工具伴生小工具名等，PRD §4.3）。
    case negativeNamePattern(String)
    /// 没有命中任何结构指纹：只有位置或名字像，标记为「疑似」。
    case missingStructuralFingerprint
}

extension CandidateDemotion: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .negativeNamePattern(pattern):
            return "命中负向名单 \(pattern)：已知易误判的名字（备份 / 快照 / 工具伴生小工具），置信度封顶为「低」。"
        case .missingStructuralFingerprint:
            return "没有命中任何结构特征：只有位置或名字像，标记为「疑似」并默认折叠。"
        }
    }
}

/// 一个候选：结构指纹准入、等待用户确认是否为某 AI 工具的目录（GLOSSARY「候选」）。
///
/// 字段刻意围绕**确认那一刻需要展示的东西**：路径、归属哪条规则、置信度、
/// 命中了哪些信号（直接就是 `ConfirmationSignals`，可以原样存进确认记录）。
public struct Candidate: Equatable, Sendable {

    /// 工具根目录的绝对路径（GLOSSARY「工具根目录」）。确认记录以它为键。
    public let toolRootPath: String

    /// 给用户看的路径（`~/.codex` 形式）。
    public let displayPath: String

    /// 命中它的规则里的工具标识；未知工具没有规则可依据时为 `nil`——不编造标识。
    public let ruleIdentifier: String?

    /// 命中它的规则的展示名。
    public let ruleDisplayName: String?

    /// 置信度三档之一。
    public let confidence: ConfidenceTier

    /// 是否为「疑似」（User Story 4：纯名称命中的候选默认折叠）。
    public var isSuspicious: Bool

    /// 准入与打分时命中的信号，可原样写进确认记录（User Story 19）。
    public let signals: ConfirmationSignals

    /// 降权 / 降档原因。
    public let demotions: [CandidateDemotion]

    /// 工具根本身命中的内置受保护条目（issue #9）。
    ///
    /// 判定按符号链接的**真实目标**进行，与移除前的保护校验是同一套代码，
    /// 因此这里不会给出与后续归档阶段相反的结论。
    public let protection: ProtectedMatch?

    public init(
        toolRootPath: String,
        displayPath: String,
        ruleIdentifier: String? = nil,
        ruleDisplayName: String? = nil,
        confidence: ConfidenceTier,
        isSuspicious: Bool = false,
        signals: ConfirmationSignals = .none,
        demotions: [CandidateDemotion] = [],
        protection: ProtectedMatch? = nil
    ) {
        self.toolRootPath = toolRootPath
        self.displayPath = displayPath
        self.ruleIdentifier = ruleIdentifier
        self.ruleDisplayName = ruleDisplayName
        self.confidence = confidence
        self.isSuspicious = isSuspicious
        self.signals = signals
        self.demotions = demotions
        self.protection = protection
    }
}
