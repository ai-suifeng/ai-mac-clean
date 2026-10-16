import Foundation

/// 准入拒绝一条规则的原因类型。
public enum RuleRejectionReason: Equatable, Sendable {
    /// 保护单调性违规：用户规则把内置受保护路径改判成了别的类别。
    case protectionMonotonicity(ProtectionMonotonicityViolation)
    /// 规则把「不确定」的数据降级成了可归档（PRD §5.1：不确定仅展示占用）。
    case uncertainDowngrade(UncertainDowngrade)
    /// 规则读不进来：结构不合法（含凭空发明的新类别）。
    case malformed(RuleFormatError)
}

extension RuleRejectionReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .protectionMonotonicity(violation):
            return violation.description
        case let .uncertainDowngrade(downgrade):
            return downgrade.description
        case let .malformed(format):
            return format.errorDescription ?? "\(format)"
        }
    }
}

extension RuleRejectionReason {
    /// 是否是保护单调性违规——验收 A16 的断言落点。
    public var isProtectionMonotonicityViolation: Bool {
        if case .protectionMonotonicity = self { return true }
        return false
    }

    /// 不确定降级违规时，指向命中的不确定形态标识（如 `uncertain/sqlite`）。
    public var uncertainShapeIdentifier: String? {
        guard case let .uncertainDowngrade(downgrade) = self else { return nil }
        return downgrade.uncertainShapeIdentifier
    }

    /// 保护单调性违规时，指向命中的内置受保护条目标识（如 `codex-cli/auth`）。
    public var protectedRuleIdentifier: String? {
        guard case let .protectionMonotonicity(violation) = self else { return nil }
        return violation.protectedRuleIdentifier
    }

    /// 保护单调性违规时，规则声明的那个类别（如 `.cacheAndLog`）。
    public var protectionDeclaredCategory: DataCategory? {
        guard case let .protectionMonotonicity(violation) = self else { return nil }
        return violation.declaredCategory
    }
}

/// 一次「把内置受保护路径改判成别的类别」的具体事实。
///
/// 不叫「降级」：判成缓存与日志或不确定并不是把保护**降低**了，而是给同一条路径
/// 换了一句与内置清单矛盾的承诺。名字必须说清是哪一种。
public struct ProtectionMonotonicityViolation: Equatable, Sendable {
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

extension ProtectionMonotonicityViolation: CustomStringConvertible {
    public var description: String {
        """
        规则字段 \(field) 把路径 \(pattern) 判为 \(declaredCategory.rawValue)（\(declaredCategory.displayText)），\
        但该路径落在内置受保护条目 \(protectedRuleIdentifier)（\(protectedScopeDescription)）的范围内。\
        内置受保护路径是下界：用户规则对这类路径只能声明为受保护，不能改判成别的类别\
        （PRD §8.1、spec #7「规则集准入」）。改成受保护即可通过准入。
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
        不确定数据无法安全分类，只能仅展示占用，规则不能把它降级为可归档（PRD §5.1）。
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

/// 一份待准入的原始规则：字节 + 来源标识。
///
/// 准入既要能吃「已经读进来的规则」，也要能吃「原始文件」：类别封闭这类问题
/// 只有读到原始字节才看得见（封闭枚举在类型层面挡住了它）。
public struct RawToolRule: Sendable {
    /// 规则文件路径，或调用方给的来源标识。
    public let source: String
    public let data: Data

    public init(source: String, data: Data) {
        self.source = source
        self.data = data
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

    /// 准入后的规则集里，某条相对路径命中的**全部**分类条目类别。
    ///
    /// 这是「同一路径同时匹配多条」的原始事实，交给 `ClassificationResolution`
    /// 按判定顺序归属；规则被拒绝、或路径未命中任何条目时返回空数组。
    public func matchingCategories(forRelativePath path: String, ruleID: String) -> [DataCategory] {
        guard let rule = usableRule(id: ruleID) else { return [] }

        return rule.classification
            .filter { PatternMatching.matches($0.pattern, relativePath: path) }
            .map(\.category)
    }

    /// 准入后的规则集里，某条相对路径被判成什么类别；规则被拒绝时返回 `nil`。
    ///
    /// 同一路径命中多条分类条目时按 `ClassificationResolution.precedence`
    /// 的判定顺序归属（受保护 > 不确定 > 缓存与日志 > 可归档会话），
    /// **与规则文件里声明的先后无关**（issue #25 验收 6）。
    /// 一条都没命中时按 `ClassificationResolution.unclassified`（不确定，仅展示占用）——
    /// 规则没声明过的数据不能因此被默认成可归档。
    ///
    /// `isBuiltInProtected` 由调用方用 `BuiltInProtectedPaths` 判好传进来，它是最高的那一档：
    /// 内置受保护清单是代码层强制的不变量（PRD §8.1、§8.3），规则分类不能盖过它。
    /// 之所以由调用方传入而不是在这里现算，是因为这份清单的判定要列举规则声明的工具根
    /// （符号链接真实目标），深扫应当**算一次、复用**，而不是每个文件都列举一遍。
    ///
    /// 被拒绝的规则不在 `usableRules` 里，因此**永远不会**通过这条查询给出降级后的类别。
    ///
    /// 边界说明：完整的规则匹配语义属于发现器那一侧的工作（issue #12），
    /// 这里只提供一条够界面展示与验收断言使用的最小查询。
    public func category(
        forRelativePath path: String,
        ruleID: String,
        isBuiltInProtected: Bool = false
    ) -> DataCategory? {
        guard usableRule(id: ruleID) != nil else { return nil }

        // 内置保护是最高的那一档：命中即受保护，规则把它声明成什么都不改变结论。
        if isBuiltInProtected { return .protected }

        return ClassificationResolution.resolve(matches: matchingCategories(forRelativePath: path, ruleID: ruleID))
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

        for rule in rules {
            if let rejection = rejection(forRule: rule, homeDirectory: homeDirectory) {
                rejections.append(rejection)
                continue
            }
            usable.append(rule)
        }

        return RuleAdmissionReport(usableRules: usable, rejections: rejections)
    }

    /// 从规则文件字节准入：读不进来的规则同样逐条拒绝，其余规则照常可用。
    public static func admit(rawRules: [RawToolRule], homeDirectory: String) -> RuleAdmissionReport {
        var decoded: [ToolRule] = []
        var rejections: [RuleRejection] = []

        for raw in rawRules {
            do {
                decoded.append(try RuleLoader.loadRule(from: raw.data, source: raw.source))
            } catch let error as RuleLoadError {
                rejections.append(
                    RuleRejection(
                        source: raw.source,
                        ruleIdentifier: "（读不出来的规则）",
                        ruleDisplayName: raw.source,
                        reason: malformedReason(error)
                    )
                )
            } catch {
                rejections.append(
                    RuleRejection(
                        source: raw.source,
                        ruleIdentifier: "（读不出来的规则）",
                        ruleDisplayName: raw.source,
                        reason: .malformed(.malformedJSON("\(error)"))
                    )
                )
            }
        }

        let report = admit(rules: decoded, homeDirectory: homeDirectory)
        return RuleAdmissionReport(
            usableRules: report.usableRules,
            rejections: rejections + report.rejections
        )
    }

    private static func malformedReason(_ error: RuleLoadError) -> RuleRejectionReason {
        switch error {
        case let .unreadableFile(_, detail):
            return .malformed(.unreadableSource(detail))
        case let .invalidRule(_, reason):
            return .malformed(reason)
        }
    }

    /// 单条规则的准入结论：被拒绝时给出原因，通过时返回 `nil`。
    ///
    /// 保护单调性的核心断言就打在这里——不需要规则文件、不需要发现流程，
    /// 直接给出规则与主目录就能判定。
    public static func rejection(forRule rule: ToolRule, homeDirectory: String) -> RuleRejection? {
        if let hit = ProtectionMonotonicity.reclassification(in: rule, homeDirectory: homeDirectory) {
            return RuleRejection(
                source: source(of: rule),
                ruleIdentifier: rule.id,
                ruleDisplayName: rule.displayName,
                reason: .protectionMonotonicity(violation(from: hit))
            )
        }

        if let hit = ProtectionMonotonicity.uncertainDowngrade(in: rule, homeDirectory: homeDirectory) {
            let downgrade = UncertainDowngrade(
                field: hit.field,
                pattern: hit.entry.pattern.canonicalString,
                uncertainShapeIdentifier: hit.region.ruleIdentifier
            )
            return RuleRejection(
                source: source(of: rule),
                ruleIdentifier: rule.id,
                ruleDisplayName: rule.displayName,
                reason: .uncertainDowngrade(downgrade)
            )
        }

        return nil
    }

    private static func violation(from hit: ProtectionMonotonicity.Finding) -> ProtectionMonotonicityViolation {
        ProtectionMonotonicityViolation(
            field: hit.field,
            pattern: hit.entry.pattern.canonicalString,
            declaredCategory: hit.entry.category,
            protectedRuleIdentifier: hit.region.ruleIdentifier,
            protectedScopeDescription: hit.region.scopeDescription
        )
    }

    /// 规则来源标识：读进来的规则带文件路径，内联规则只报工具标识。
    private static func source(of rule: ToolRule) -> String {
        "内联规则 \(rule.id)"
    }
}

