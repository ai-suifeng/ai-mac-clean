import Foundation

/// 准入拒绝一条规则的原因类型。
public enum RuleRejectionReason: Equatable, Sendable {
    /// 保护单调性违规：用户规则把内置受保护路径降级成了更弱的类别。
    case protectionMonotonicity(ProtectionDowngrade)
    /// 规则把「不确定」的数据降级成了可归档（PRD §5.1：不确定只展示、锁定）。
    case uncertainDowngrade(UncertainDowngrade)
    /// 规则凭空声明了封闭枚举以外的新类别。
    case unknownCategory(field: String, value: String)
}

extension RuleRejectionReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .protectionMonotonicity(downgrade):
            return downgrade.description
        case let .uncertainDowngrade(downgrade):
            return downgrade.description
        case let .unknownCategory(field, value):
            return "规则字段 \(field) 声明了不存在的类别 \(value)。类别是封闭枚举：archivableSession、cacheAndLog、protected、uncertain。"
        }
    }
}

/// 一次「把内置受保护路径降级」的具体事实。
public struct ProtectionDowngrade: Equatable, Sendable {
    /// 规则里出问题的字段，如 `classification[3].category`。
    public let field: String
    /// 规则声明的路径模式。
    public let pattern: String
    /// 规则声明的类别。
    public let declaredCategory: DataCategory
    /// 命中的内置受保护条目标识（如 `codex-cli/auth`）。
    public let protectedRuleIdentifier: String
    /// 内置受保护条目覆盖的范围说明（相对工具根，或按文件名兜底）。
    public let protectedScopeDescription: String

    public init(
        field: String,
        pattern: String,
        declaredCategory: DataCategory,
        protectedRuleIdentifier: String,
        protectedScopeDescription: String
    ) {
        self.field = field
        self.pattern = pattern
        self.declaredCategory = declaredCategory
        self.protectedRuleIdentifier = protectedRuleIdentifier
        self.protectedScopeDescription = protectedScopeDescription
    }
}

extension ProtectionDowngrade: CustomStringConvertible {
    public var description: String {
        """
        规则字段 \(field) 把路径 \(pattern) 判为 \(declaredCategory.rawValue)（\(declaredCategory.displayText)），\
        但该路径落在内置受保护条目 \(protectedRuleIdentifier)（\(protectedScopeDescription)）的范围内。\
        内置受保护路径是下界，用户规则只能抬高保护，不能把它降低（PRD §8.1）。
        """
    }
}

/// 一次「把不确定降级为可归档」的具体事实。
public struct UncertainDowngrade: Equatable, Sendable {
    public let field: String
    public let pattern: String
    public let uncertainShapeIdentifier: String

    public init(field: String, pattern: String, uncertainShapeIdentifier: String) {
        self.field = field
        self.pattern = pattern
        self.uncertainShapeIdentifier = uncertainShapeIdentifier
    }
}

extension UncertainDowngrade: CustomStringConvertible {
    public var description: String {
        """
        规则字段 \(field) 把路径 \(pattern) 判为 archivableSession（可归档会话），\
        但该路径落在「不确定」形态 \(uncertainShapeIdentifier) 的范围内。\
        不确定数据无法安全分类，只能锁定展示，规则不能把它降级为可归档（PRD §5.1）。
        """
    }
}

extension DataCategory {
    /// 类别的中文名，用于可读诊断。
    public var displayText: String {
        switch self {
        case .archivableSession: return "可归档会话"
        case .cacheAndLog: return "缓存与日志"
        case .protected: return "受保护"
        case .uncertain: return "不确定"
        }
    }
}

/// 一条被拒绝的规则（拒绝粒度是单条规则）。
public struct RuleRejection: Error, Equatable, Sendable {
    /// 规则来源：文件路径，或内联规则的工具标识。
    public let source: String
    public let ruleIdentifier: String
    public let ruleDisplayName: String
    public let reason: RuleRejectionReason

    public init(source: String, ruleIdentifier: String, ruleDisplayName: String, reason: RuleRejectionReason) {
        self.source = source
        self.ruleIdentifier = ruleIdentifier
        self.ruleDisplayName = ruleDisplayName
        self.reason = reason
    }
}

extension RuleRejection: CustomStringConvertible {
    /// 可直接展示给用户的中文说明：哪条规则的哪个字段、判成了什么、撞上了哪条内置保护。
    public var description: String {
        "规则「\(ruleDisplayName)」（\(ruleIdentifier)，来源 \(source)）已被拒绝：\(reason)"
    }
}

/// 规则集准入的结果。
///
/// 同时表达「可用的规则集」与「被拒绝的规则 + 各自原因」：
/// 一条坏规则不会让其余已知工具的规则失效，也不会因为它而跳过任何保护（issue #11 不变式 2）。
public struct RuleAdmissionReport: Equatable, Sendable {
    /// 已验证可用的规则。
    public let usableRules: [ToolRule]
    /// 被拒绝的规则，一条一个原因。
    public let rejections: [RuleRejection]

    public init(usableRules: [ToolRule], rejections: [RuleRejection]) {
        self.usableRules = usableRules
        self.rejections = rejections
    }

    /// 是否全部准入。
    public var isFullyAdmitted: Bool { rejections.isEmpty }

    /// 按工具标识取一条可用规则。
    public func usableRule(id: String) -> ToolRule? {
        usableRules.first { $0.id == id }
    }
}

/// 规则集准入（Seam 2；issue #11）。
///
/// 职责：把一组原始规则变成「已验证可用的规则集」，或逐条拒绝并给出可读原因。
public enum RuleSetAdmission {

    /// 主入口：准入一组规则。
    public static func admit(rules: [ToolRule], homeDirectory: String) -> RuleAdmissionReport {
        RuleAdmissionReport(usableRules: rules, rejections: [])
    }
}
