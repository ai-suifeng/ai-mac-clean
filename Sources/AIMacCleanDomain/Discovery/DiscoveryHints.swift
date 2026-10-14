import Foundation

/// 名称关键词与负向名单（PRD §4.3）。
///
/// **词表不写死在代码里**：关键词与负向名单都是可更新的配置，由调用方注入，
/// 软件本体不认识 `claude`、`codex` 这些名字。加载入口见 `DiscoveryHints.load(from:)`。
///
/// ## 关键词的权限边界（GLOSSARY「结构指纹」）
///
/// 关键词**只用于给已入列的候选排序**，永远不参与准入：一个名字里含 `claude`
/// 但没有任何结构特征的目录，根本不会出现在候选列表里（User Story 9、PRD A1）。
/// 负向名单则相反：它能把已经入列的候选降权，防止旧快照与伴生小工具冒充工具本身
/// （User Story 5、6）。
public struct DiscoveryHints: Equatable, Sendable {

    /// 工具标识 → 该工具的名称关键词（如 `claude`、`code`）。
    public let nameKeywords: [String: [String]]

    /// 已知易误判的名字模式（`*` 匹配任意字符，忽略大小写）：`*-bak`、`*.bak*`、`*-backup*` 等。
    public let negativeNamePatterns: [String]

    public init(nameKeywords: [String: [String]] = [:], negativeNamePatterns: [String] = []) {
        self.nameKeywords = nameKeywords
        self.negativeNamePatterns = negativeNamePatterns
    }

    /// 空词表：关键词不参与排序，也没有负向名单。
    public static let none = DiscoveryHints()

    /// 某条规则的名称关键词。
    public func keywords(forRuleIdentifier identifier: String) -> [String] {
        nameKeywords[identifier] ?? []
    }
}
