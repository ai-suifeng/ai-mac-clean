import Foundation

/// 规则文件里出现的语法级错误。
///
/// 只覆盖「读进来时就能发现的结构问题」；准入层面的拒绝原因（保护单调性等）
/// 属于规则集准入（issue #11），不在此表达。
public enum RuleFormatError: Error, Equatable, Sendable {
    /// 模式为空。
    case emptyPattern
    /// 模式里有空的分段（`a//b`、以 `/` 开头或结尾）。
    case emptySegment
    /// 占位符没有闭合（缺 `>`）。
    case unterminatedPlaceholder
    /// 占位符语法不认识。
    case invalidPlaceholder(String)
    /// `**` 只能整段出现，且只能是最后一段。
    case invalidRecursiveWildcard(String)
    /// `[` 没有闭合的可选字面量。
    case unterminatedOptionalLiteral
    /// 必填字段缺失。
    case missingRequiredField(field: String)
    /// 字段值不合法。
    case invalidFieldValue(field: String, reason: String)
    /// 规则文件版本不受支持。
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// 文件不是合法的 UTF-8 JSON。
    case malformedJSON(String)
    /// 文件读不出来（不是文件、无权限等）。
    case unreadableSource(String)
}

extension RuleFormatError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPattern:
            return "规则里的路径模式为空。"
        case .emptySegment:
            return "路径模式里有空的分段：不允许以 / 开头或结尾，也不允许出现 //。"
        case .unterminatedPlaceholder:
            return "路径模式里的占位符没有闭合：< 后面缺少 >。"
        case let .invalidPlaceholder(source):
            return "路径模式里的占位符无法识别：\(source)。"
        case let .invalidRecursiveWildcard(source):
            return "路径模式里的递归通配符 ** 只能作为最后一段单独出现：\(source)。"
        case .unterminatedOptionalLiteral:
            return "路径模式里的可选字面量没有闭合：[ 后面缺少 ]。"
        case let .missingRequiredField(field):
            return "规则文件缺少必填字段：\(field)。"
        case let .invalidFieldValue(field, reason):
            return "规则文件字段 \(field) 的取值不合法：\(reason)"
        case let .unsupportedSchemaVersion(found, supported):
            return "规则文件版本 \(found) 不受支持，本版本只支持 \(supported)。"
        case let .malformedJSON(detail):
            return "规则文件不是合法的 JSON：\(detail)"
        case let .unreadableSource(detail):
            return "规则文件读不出来：\(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyPattern, .emptySegment, .unterminatedPlaceholder, .invalidPlaceholder,
             .invalidRecursiveWildcard, .unterminatedOptionalLiteral:
            return "占位符写法：<uuid>、<uuid:标签>、<encodedPath>、<date:year|month|day>、<名字>；可选后缀写作 [..]；* 匹配一段，** 递归匹配剩余分段。"
        case .missingRequiredField, .invalidFieldValue:
            return "对照规则格式文档补齐该字段；未知字段会被忽略，但必填字段不能缺。"
        case .unsupportedSchemaVersion:
            return "请使用与本应用匹配的规则文件版本。"
        case .unreadableSource:
            return "确认该路径是一个可读的普通文件。"
        case .malformedJSON:
            return "检查是否有中文引号、尾随逗号等 JSON 不允许的写法。"
        }
    }
}
