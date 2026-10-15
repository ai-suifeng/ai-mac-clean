import Foundation

/// 用户对某个候选做出的决定（spec #7 §持久化：「决定（确认 / 忽略）」）。
///
/// 术语取自 GLOSSARY 与 PRD §4.1 第 2 步：用户逐个「确认是 AI 工具」或「忽略」。
/// 两种决定都被保存——忽略同样是一种用户判断，下次启动不必重复询问（User Story 16）。
public enum ToolDecision: String, Codable, Equatable, Sendable, CaseIterable {
    /// 确认是 AI 工具（GLOSSARY「工具」）。
    case confirmed
    /// 忽略：这个候选不是我要的 AI 工具。
    case ignored
}

/// 一条**外部佐证**：除结构指纹之外，让候选更可信的旁证（PRD §4.3「关联检测」「内容特征」）。
///
/// 分三类，是为了让记录里的信号在几个月后仍然可读（User Story 19）：
/// 知道「因为规则声明的 `Cursor.app` 装在这儿」和「因为规则声明的 `codex` 命令在」
/// 是两回事。
public enum ExternalCorroboration: Equatable, Sendable {
    /// 规则声明的 App 包存在（`/Applications/Cursor.app` → `Cursor`）。
    case application(String)
    /// 规则声明的可执行文件存在（`/opt/homebrew/bin/codex` → `codex`）。
    case command(String)
    /// 会话文件开头的字段特征（只读文件头少量内容）。
    case contentFeature(String)
}

extension ExternalCorroboration: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .application(name):
            try container.encode("application", forKey: .kind)
            try container.encode(name, forKey: .value)
        case let .command(name):
            try container.encode("command", forKey: .kind)
            try container.encode(name, forKey: .value)
        case let .contentFeature(description):
            try container.encode("contentFeature", forKey: .kind)
            try container.encode(description, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case "application":
            self = .application(value)
        case "command":
            self = .command(value)
        case "contentFeature":
            self = .contentFeature(value)
        default:
            // 未知种类不静默丢弃：整条记录读不出来，好过几个月后看到一条没有理由的记录。
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "未知的外部佐证种类：\(kind)"
            )
        }
    }
}

/// 决定当时命中的信号（spec #7 §持久化：「确认时命中的信号」；User Story 19）。
///
/// 三类信号分开存，而不是拍平成一个字符串列表：几个月后回看，
/// 「因为结构指纹 `projects/<uuid>.jsonl`」与「因为名字里含 claude」必须是两句话，
/// 因为后者按设计**不足以**成为准入依据（GLOSSARY「结构指纹」）。
public struct ConfirmationSignals: Equatable, Sendable, Codable {
    /// 命中的结构指纹（GLOSSARY「结构指纹」），如 `projects/<uuid>.jsonl`。
    public var structuralFingerprints: [String]
    /// 命中的名称关键词（只用于排序，不用于准入，PRD §4.3）。
    public var nameMatches: [String]
    /// 外部佐证：同名 App / PATH 命令 / 会话文件字段特征。
    public var externalCorroborations: [ExternalCorroboration]

    public init(
        structuralFingerprints: [String] = [],
        nameMatches: [String] = [],
        externalCorroborations: [ExternalCorroboration] = []
    ) {
        self.structuralFingerprints = structuralFingerprints
        self.nameMatches = nameMatches
        self.externalCorroborations = externalCorroborations
    }

    /// 没有任何信号。
    public static let none = ConfirmationSignals()
}

/// 一条确认/忽略记录（GLOSSARY「工具」在本软件中以一条用户确认过的记录存在）。
///
/// 内容严格对应 spec #7 §持久化列出的五项：工具标识、工具根目录路径、决定、
/// 确认时命中的信号、时间戳。
public struct ConfirmationRecord: Equatable, Sendable, Codable {
    /// 工具标识：命中它的规则文件里的工具 id（如 `claude-code`）。
    ///
    /// 未知工具没有规则可依据，此时为 `nil`——**不编造标识**。
    public let toolIdentifier: String?
    /// 工具根目录路径（GLOSSARY「工具根目录」）。记录以它为键：用户是对一个具体目录做的判断。
    public let toolRootPath: String
    /// 用户的决定。
    public let decision: ToolDecision
    /// 决定当时命中的信号。
    public let signals: ConfirmationSignals
    /// 决定发生的时间（秒级精度即可——这是一次人工判断，不是机器事件）。
    public let decidedAt: Date

    public init(
        toolIdentifier: String?,
        toolRootPath: String,
        decision: ToolDecision,
        signals: ConfirmationSignals,
        decidedAt: Date
    ) {
        self.toolIdentifier = toolIdentifier
        self.toolRootPath = toolRootPath
        self.decision = decision
        self.signals = signals
        self.decidedAt = decidedAt
    }
}
