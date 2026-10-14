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

    /// 词表文件里支持的版本。
    public static let currentSchemaVersion = 1

    /// 从词表文件读入关键词与负向名单（PRD §4.3「词表放可更新的配置文件」）。
    ///
    /// 读不出来时**抛出带中文说明的错误**：词表错了要看得见，不能静默变成空词表——
    /// 空词表不会让功能出错，只会让负向名单悄悄失效、旧快照悄悄变成高置信度候选。
    public static func load(from url: URL) throws -> DiscoveryHints {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DiscoveryHintsError.unreadableFile(path: url.path, detail: "\(error)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            throw DiscoveryHintsError.malformed(path: url.path, reason: "顶层必须是一个 JSON 对象。")
        }

        if let version = root["schemaVersion"] as? Int {
            guard version == currentSchemaVersion else {
                throw DiscoveryHintsError.unsupportedVersion(
                    path: url.path,
                    found: version,
                    supported: currentSchemaVersion
                )
            }
        }

        var keywords: [String: [String]] = [:]
        if let raw = root["nameKeywords"] {
            guard let map = raw as? [String: [String]] else {
                throw DiscoveryHintsError.malformed(
                    path: url.path,
                    reason: "nameKeywords 必须是「工具标识 → 关键词数组」的对象。"
                )
            }
            keywords = map
        }

        var negatives: [String] = []
        if let raw = root["negativeNamePatterns"] {
            guard let list = raw as? [String] else {
                throw DiscoveryHintsError.malformed(
                    path: url.path,
                    reason: "negativeNamePatterns 必须是字符串数组。"
                )
            }
            negatives = list.filter { !$0.isEmpty }
        }

        return DiscoveryHints(nameKeywords: keywords, negativeNamePatterns: negatives)
    }
}

/// 词表文件读不出来 / 格式不对的原因。
public enum DiscoveryHintsError: Error, Equatable, Sendable {
    case unreadableFile(path: String, detail: String)
    case malformed(path: String, reason: String)
    case unsupportedVersion(path: String, found: Int, supported: Int)
}

extension DiscoveryHintsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(path, detail):
            return "关键词 / 负向名单词表无法读取（\(path)）：\(detail)"
        case let .malformed(path, reason):
            return "关键词 / 负向名单词表格式不对（\(path)）：\(reason)"
        case let .unsupportedVersion(path, found, supported):
            return """
            关键词 / 负向名单词表的 schemaVersion 是 \(found)（\(path)），\
            本软件支持的是 \(supported)。
            """
        }
    }
}
