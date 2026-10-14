import Foundation

/// 加载规则时出错的两种形态。
public enum RuleLoadError: Error, Equatable, Sendable {
    /// 规则文件读不出来（不存在、不是文件、被占用……）。
    case unreadableFile(source: String, detail: String)
    /// 读到了，但结构不合法。
    case invalidRule(source: String, reason: RuleFormatError)
}

/// 加载失败的规则文件路径。
extension RuleLoadError {
    /// 出问题的规则文件路径。
    public var source: String {
        switch self {
        case let .unreadableFile(source, _), let .invalidRule(source, _):
            return source
        }
    }
}

extension RuleLoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(source, detail):
            return "无法读取规则文件 \(source)：\(detail)"
        case let .invalidRule(source, reason):
            return "规则文件 \(source) 不合法：\(reason.errorDescription ?? "\(reason)")"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreadableFile:
            return "确认该路径是一个可读的 JSON 文件。"
        case let .invalidRule(_, reason):
            return reason.recoverySuggestion
        }
    }
}

/// 一条加载期诊断。
///
/// 诊断只描述「这份规则文件读不进来、为什么」，不含准入结论——
/// 保护单调性一类拒绝理由属于规则集准入（issue #11）。
public struct RuleDiagnostic: Error, Equatable, Sendable {
    /// 出问题的规则文件路径。
    public let source: String
    /// 可读的原因。
    public let reason: RuleFormatError

    public init(source: String, reason: RuleFormatError) {
        self.source = source
        self.reason = reason
    }

    /// 读不了文件时也产出一条诊断，原因用结构化错误承载。
    public init(source: String, reason: RuleLoadError) {
        self.source = source
        switch reason {
        case let .unreadableFile(_, detail):
            self.reason = .unreadableSource(detail)
        case let .invalidRule(_, reason):
            self.reason = reason
        }
    }
}

extension RuleDiagnostic: LocalizedError {
    public var errorDescription: String? {
        "规则文件 \(source) 不合法：\(reason.errorDescription ?? "\(reason)")"
    }
}

/// 一次目录加载的结果。
public struct RuleLoadReport: Equatable, Sendable {
    /// 成功读入的规则。顺序按文件路径稳定排序。
    public let rules: [ToolRule]
    /// 读不进来的规则文件，一条一个原因。
    public let diagnostics: [RuleDiagnostic]

    public init(rules: [ToolRule], diagnostics: [RuleDiagnostic]) {
        self.rules = rules
        self.diagnostics = diagnostics
    }
}

/// 声明式规则加载器。
///
/// 边界说明（issue #10 只负责「读进来 + 结构合法」）：
/// - 加载器**不检查规则声明的路径在磁盘上是否存在**。路径缺失是扫描期「无匹配」，
///   不是加载失败（spec #7 User Story 22、PRD §5.4）。
/// - 加载器**不做保护单调性校验**，也不比较内置保护清单。那属于规则集准入（issue #11）。
/// - 加载器不认识任何工具名：新增工具 = 新增规则文件。
public enum RuleLoader {
    /// 规则文件的扩展名。
    public static let ruleFileExtension = "json"

    /// 从文件读入一条规则。
    public static func loadRule(at url: URL) throws -> ToolRule {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RuleLoadError.unreadableFile(source: url.path, detail: (error as NSError).localizedDescription)
        }
        return try loadRule(from: data, source: url.path)
    }

    /// 从字节读入一条规则。
    public static func loadRule(from data: Data, source: String) throws -> ToolRule {
        do {
            return try ToolRule.decode(from: data)
        } catch let error as RuleFormatError {
            throw RuleLoadError.invalidRule(source: source, reason: error)
        } catch let error as DecodingError {
            // 兜底：类型不匹配之类的解码错误也要变成可读的诊断，而不是裸的 DecodingError。
            throw RuleLoadError.invalidRule(source: source, reason: .malformedJSON(describe(error)))
        }
    }

    /// 读入目录下的全部规则文件（只取本层，不递归子目录）。
    ///
    /// 一条坏规则不该让其余已知工具的规则全部失效：读不进来的文件变成一条诊断，
    /// 其余规则照常返回。目录不存在或没有规则文件时返回空结果，不算失败。
    public static func loadRules(inDirectory directory: URL) -> RuleLoadReport {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
              )
        else {
            return RuleLoadReport(rules: [], diagnostics: [])
        }

        var rules: [ToolRule] = []
        var diagnostics: [RuleDiagnostic] = []

        for url in entries
            .filter({ $0.pathExtension.lowercased() == ruleFileExtension })
            .sorted(by: { $0.path < $1.path }) {
            do {
                let rule = try loadRule(at: url)
                rules.append(rule)
            } catch let error as RuleLoadError {
                diagnostics.append(RuleDiagnostic(source: url.path, reason: error))
            } catch {
                diagnostics.append(RuleDiagnostic(source: url.path, reason: .malformedJSON("\(error)")))
            }
        }

        return RuleLoadReport(rules: rules, diagnostics: diagnostics)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(context):
            return context.debugDescription
        case let .keyNotFound(key, _):
            return "缺少字段 \(key.stringValue)"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return context.debugDescription
        @unknown default:
            return "\(error)"
        }
    }
}
