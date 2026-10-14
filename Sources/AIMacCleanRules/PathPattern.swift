import Foundation

/// 占位符的种类。
///
/// 决定「这一段在磁盘上长什么样」，但**不决定怎么把它还原成项目路径**——
/// 引擎不做逆向解码（PRD §5.3：Claude Code 的编码不可无损逆解）。
public enum PlaceholderKind: String, Codable, Equatable, CaseIterable, Sendable {
    /// 一段 UUID。
    case uuid
    /// 项目路径编码后的目录名（编码方案由规则文件的 `projectPathEncoding` 声明）。
    case encodedPath
    /// 日期的一个分量：`year` / `month` / `day`（对应 `sessions/YYYY/MM/DD`）。
    case date
    /// 其它具名占位段，例如 `rollout-<ISO>` 里的 `<ISO>`、`<name:sessionID>`。
    case name
}

/// 路径模式里的单个记号。
public enum PathPatternToken: Equatable, Sendable {
    /// 原样匹配的字面文本。
    case literal(String)
    /// `*`：匹配单段内的任意文本。
    case wildcard
    /// `<kind>` 或 `<kind:标签>`。
    case placeholder(kind: PlaceholderKind, label: String?)
    /// `[字面量]`：可选后缀，如 `.jsonl[.zst]`。
    case optionalLiteral(String)
}

/// 路径模式里的一段（不含分隔符 `/`）。
public struct PathPatternSegment: Equatable, Sendable {
    public let tokens: [PathPatternToken]

    public init(tokens: [PathPatternToken]) {
        self.tokens = tokens
    }
}

/// 相对某个基目录的路径模式。
///
/// 语法（各记号含义见 `PathPatternToken`）：
///
/// - 分段用 `/` 分隔；`*` 是整段通配；`**` 只能作为最后一段单独出现。
/// - 占位符：`<uuid>`、`<uuid:标签>`、`<encodedPath>`、`<date:year|month|day>`、`<名字>`。
/// - 可选字面量：`[.zst]`。
///
/// 解析在加载期完成，匹配语义属于 issue #5。
public struct PathPattern: Codable, Equatable, Sendable {
    /// 模式串的分段。
    public let segments: [PathPatternSegment]

    public init(segments: [PathPatternSegment]) {
        self.segments = segments
    }

    /// 解析模式串。
    public init(_ source: String) throws {
        guard !source.isEmpty else { throw RuleFormatError.emptyPattern }
        guard !source.hasPrefix("/"), !source.hasSuffix("/") else {
            throw RuleFormatError.emptySegment
        }

        var segments: [PathPatternSegment] = []
        for rawSegment in source.split(separator: "/", omittingEmptySubsequences: false) {
            guard !rawSegment.isEmpty else { throw RuleFormatError.emptySegment }
            segments.append(
                PathPatternSegment(tokens: try PathPattern.parseSegment(String(rawSegment), wholePattern: source))
            )
        }

        // `**` 只能整段、且只能是最后一段：它意味着「剩下的全都要」。
        for (index, segment) in segments.enumerated() {
            guard segment.tokens == [.literal("**")] else {
                if segment.tokens.contains(.literal("**")) {
                    throw RuleFormatError.invalidRecursiveWildcard(source)
                }
                continue
            }
            guard index == segments.count - 1 else {
                throw RuleFormatError.invalidRecursiveWildcard(source)
            }
        }

        self.segments = segments
    }

    // MARK: - Codable

    /// 规则文件里以模式串出现；读出时即解析，语法错误在加载期暴露。
    public init(from decoder: Decoder) throws {
        let source = try decoder.singleValueContainer().decode(String.self)
        try self.init(source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalString)
    }

    /// 规范化后的模式串：再次解析应得到同一个值（`canonicalString` 是幂等的）。
    public var canonicalString: String {
        segments.map { segment in
            segment.tokens.map { PathPattern.render($0) }.joined()
        }.joined(separator: "/")
    }

    // MARK: - 分段解析

    private static func parseSegment(_ text: String, wholePattern: String) throws -> [PathPatternToken] {
        if text == "**" {
            // 递归通配只允许整段、且只能在最后一段；判定留给整串解析。
            return [.literal("**")]
        }

        var tokens: [PathPatternToken] = []
        var literal = ""
        var index = text.startIndex

        func flushLiteral() {
            if !literal.isEmpty {
                tokens.append(.literal(literal))
                literal = ""
            }
        }

        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "*":
                flushLiteral()
                tokens.append(.wildcard)
            case "<":
                flushLiteral()
                let (token, next) = try parsePlaceholder(text, from: index, wholePattern: wholePattern)
                tokens.append(token)
                index = next
                continue
            case "[":
                flushLiteral()
                guard let closing = text[index...].firstIndex(of: "]") else {
                    throw RuleFormatError.unterminatedOptionalLiteral
                }
                let inner = String(text[text.index(after: index)..<closing])
                guard !inner.isEmpty, !inner.contains("/") else {
                    throw RuleFormatError.unterminatedOptionalLiteral
                }
                tokens.append(.optionalLiteral(inner))
                index = text.index(after: closing)
                continue
            default:
                literal.append(character)
            }
            index = text.index(after: index)
        }
        flushLiteral()
        return tokens
    }

    private static func parsePlaceholder(
        _ text: String,
        from start: String.Index,
        wholePattern: String
    ) throws -> (PathPatternToken, String.Index) {
        let afterOpen = text.index(after: start)
        guard let closing = text[afterOpen...].firstIndex(of: ">") else {
            throw RuleFormatError.unterminatedPlaceholder
        }
        let body = String(text[afterOpen..<closing])
        guard !body.isEmpty else { throw RuleFormatError.invalidPlaceholder("<>") }
        guard !body.contains("/") else { throw RuleFormatError.invalidPlaceholder("<\(body)>") }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2 { throw RuleFormatError.invalidPlaceholder("<\(body)>") }

        let kindText = parts[0]
        let label = parts.count == 2 ? parts[1] : nil
        if let label, label.isEmpty { throw RuleFormatError.invalidPlaceholder("<\(body)>") }

        switch kindText {
        case "uuid", "encodedPath":
            return (.placeholder(kind: PlaceholderKind(rawValue: kindText)!, label: label), text.index(after: closing))
        case "date":
            guard let label, ["year", "month", "day"].contains(label) else {
                throw RuleFormatError.invalidPlaceholder("<\(body)>")
            }
            return (.placeholder(kind: .date, label: label), text.index(after: closing))
        case "name":
            guard let label else { throw RuleFormatError.invalidPlaceholder("<\(body)>") }
            return (.placeholder(kind: .name, label: label), text.index(after: closing))
        default:
            break
        }

        // 简写：`<uuidA>` 视作带标签的 uuid；`<ISO>` 视作具名占位段。
        if let shorthand = uuidShorthandLabel(kindText) {
            return (.placeholder(kind: .uuid, label: shorthand), text.index(after: closing))
        }
        if let first = kindText.first, first.isUppercase, isIdentifierLike(kindText) {
            return (.placeholder(kind: .name, label: kindText), text.index(after: closing))
        }
        throw RuleFormatError.invalidPlaceholder("<\(body)>")
    }

    /// `uuid` / `uuidA` / `uuidPrimary` → `nil` / `A` / `Primary`。
    private static func uuidShorthandLabel(_ text: String) -> String? {
        guard text.count >= 4, text.hasPrefix("uuid") else { return nil }
        let suffix = String(text.dropFirst(4))
        guard suffix.first?.isUppercase == true, isIdentifierLike(suffix) else { return nil }
        return suffix
    }

    private static func isIdentifierLike(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - 渲染

    private static func render(_ token: PathPatternToken) -> String {
        switch token {
        case let .literal(text):
            return text
        case .wildcard:
            return "*"
        case let .optionalLiteral(text):
            return "[\(text)]"
        case let .placeholder(kind, label):
            switch (kind, label) {
            case let (.uuid, label?), let (.encodedPath, label?), let (.date, label?):
                return "<\(kind.rawValue):\(label)>"
            case (.date, nil):
                // 只有 `<date:year|month|day>` 合法，解析期已挡住裸 `<date>`。
                return "<date>"
            case let (.name, label?):
                // 首字母大写的具名占位段回写成简写形式（与手写规则文件一致），
                // 其余回写成显式的 <name:...>，保证再次解析得到同一个值。
                if let first = label.first, first.isUppercase,
                   isIdentifierLike(label),
                   !PlaceholderKind.allCases.contains(where: { $0.rawValue == label }) {
                    return "<\(label)>"
                }
                return "<name:\(label)>"
            case let (kind, nil):
                return "<\(kind.rawValue)>"
            }
        }
    }
}
