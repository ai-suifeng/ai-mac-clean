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

extension RuleRejectionReason {
    /// 是否是保护单调性违规——验收 A16 的断言落点。
    public var isProtectionMonotonicityViolation: Bool {
        if case .protectionMonotonicity = self { return true }
        return false
    }

    /// 保护单调性违规时，指向命中的内置受保护条目标识（如 `codex-cli/auth`）。
    public var protectedRuleIdentifier: String? {
        guard case let .protectionMonotonicity(downgrade) = self else { return nil }
        return downgrade.protectedRuleIdentifier
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

/// 一条不构成降级、但与内置保护不一致的分类声明。
///
/// 例：规则把 `shell-snapshots/**` 标成 `cacheAndLog`，而内置清单把它列为受保护。
/// 两个类别都不允许删除，所以规则照常可用；但界面应当如实说明「它其实仍受保护」，
/// 而不是让用户以为「这是缓存，可以随手清掉」。
public struct RuleAdmissionWarning: Equatable, Sendable {
    public let ruleIdentifier: String
    public let ruleDisplayName: String
    /// 规则里出问题的字段，如 `classification[7].category`。
    public let field: String
    public let pattern: String
    public let declaredCategory: DataCategory
    /// 命中的内置受保护条目标识。
    public let protectedRuleIdentifier: String

    public init(
        ruleIdentifier: String,
        ruleDisplayName: String,
        field: String,
        pattern: String,
        declaredCategory: DataCategory,
        protectedRuleIdentifier: String
    ) {
        self.ruleIdentifier = ruleIdentifier
        self.ruleDisplayName = ruleDisplayName
        self.field = field
        self.pattern = pattern
        self.declaredCategory = declaredCategory
        self.protectedRuleIdentifier = protectedRuleIdentifier
    }
}

extension RuleAdmissionWarning: CustomStringConvertible {
    public var description: String {
        """
        规则「\(ruleDisplayName)」（\(ruleIdentifier)）的字段 \(field) 把路径 \(pattern) 标为 \
        \(declaredCategory.rawValue)（\(declaredCategory.displayText)），而内置受保护条目 \
        \(protectedRuleIdentifier) 把它列为受保护。该类别同样不会删除任何数据，因此规则可用，\
        但这条路径实际仍然受保护。
        """
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
    /// 不构成降级、但与内置保护不一致的声明（见 `RuleAdmissionWarning`）。
    public let warnings: [RuleAdmissionWarning]

    public init(usableRules: [ToolRule], rejections: [RuleRejection], warnings: [RuleAdmissionWarning] = []) {
        self.usableRules = usableRules
        self.rejections = rejections
        self.warnings = warnings
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
/// 这是独立可测的边界：**不经过发现流程就能断言**（spec #7「Testing Decisions」）。
public enum RuleSetAdmission {

    /// 主入口：准入一组规则。
    ///
    /// 拒绝粒度是**单条规则**：一条坏规则被单独拒绝并给出原因，其余已知工具的规则照常可用。
    public static func admit(rules: [ToolRule], homeDirectory: String) -> RuleAdmissionReport {
        var usable: [ToolRule] = []
        var rejections: [RuleRejection] = []
        var warnings: [RuleAdmissionWarning] = []

        for rule in rules {
            if let rejection = rejection(forRule: rule, homeDirectory: homeDirectory) {
                rejections.append(rejection)
                continue
            }
            usable.append(rule)
            warnings.append(contentsOf: RuleSetAdmission.warnings(forRule: rule, homeDirectory: homeDirectory))
        }

        return RuleAdmissionReport(usableRules: usable, rejections: rejections, warnings: warnings)
    }

    /// 单条规则的准入结论：被拒绝时给出原因，通过时返回 `nil`。
    ///
    /// 保护单调性的核心断言就打在这里——不需要规则文件、不需要发现流程，
    /// 直接给出规则与主目录就能判定。
    public static func rejection(forRule rule: ToolRule, homeDirectory: String) -> RuleRejection? {
        guard let hit = ProtectionMonotonicity.downgrade(in: rule, homeDirectory: homeDirectory) else {
            return nil
        }

        let downgrade = ProtectionDowngrade(
            field: hit.field,
            pattern: hit.entry.pattern.canonicalString,
            declaredCategory: hit.entry.category,
            protectedRuleIdentifier: hit.region.ruleIdentifier,
            protectedScopeDescription: hit.region.scopeDescription
        )

        return RuleRejection(
            source: source(of: rule),
            ruleIdentifier: rule.id,
            ruleDisplayName: rule.displayName,
            reason: .protectionMonotonicity(downgrade)
        )
    }

    /// 某条规则里不构成降级、但与内置保护不一致的声明。
    public static func warnings(forRule rule: ToolRule, homeDirectory: String) -> [RuleAdmissionWarning] {
        ProtectionMonotonicity.findings(in: rule, homeDirectory: homeDirectory)
            .filter { $0.kind == .mislabelling }
            .map { finding in
                RuleAdmissionWarning(
                    ruleIdentifier: rule.id,
                    ruleDisplayName: rule.displayName,
                    field: finding.field,
                    pattern: finding.entry.pattern.canonicalString,
                    declaredCategory: finding.entry.category,
                    protectedRuleIdentifier: finding.region.ruleIdentifier
                )
            }
    }

    /// 规则来源标识：读进来的规则带文件路径，内联规则只报工具标识。
    private static func source(of rule: ToolRule) -> String {
        "内联规则 \(rule.id)"
    }
}

