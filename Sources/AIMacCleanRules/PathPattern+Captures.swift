import Foundation

/// 路径模式下某个占位段捕获到的文本（issue #26）。
///
/// 「这条路径被模式命中」与「这条路径的哪一段是项目名 / 会话 ID」是两件事：
/// 前者只需要一个布尔值，后者必须知道每个占位段的边界。会话归组要的正是后者——
/// `projects/<encodedPath>/<uuid>.jsonl` 里的 `<encodedPath>` 就是会话所属项目的
/// 编码目录名（PRD §5.3：不可逆编码，只原样展示，绝不反向解码）。
public struct PathPatternCapture: Equatable, Hashable, Sendable {

    /// 占位段的种类（`<uuid>`、`<encodedPath>`、`<date:…>`、`<名字>`）。
    public let kind: PlaceholderKind

    /// 占位段的标签（`<uuidA>` → `A`、`<ISO>` → `ISO`、`<date:year>` → `year`）；无标签为 `nil`。
    public let label: String?

    /// 占位段在**模式**里的段序号（从 0 起），便于核对捕获来自哪一段。
    public let segmentIndex: Int

    /// 捕获到的文本，取自磁盘上的**原文**（比较是小写不敏感的，捕获值不是）。
    public let value: String

    public init(kind: PlaceholderKind, label: String?, segmentIndex: Int, value: String) {
        self.kind = kind
        self.label = label
        self.segmentIndex = segmentIndex
        self.value = value
    }
}

public extension PathPattern {

    /// 逐段匹配并取出所有占位段的捕获值；不命中时返回 `nil`。
    ///
    /// 命中与否**一律以权威匹配 `matches(relativePath:)` 为准**：本方法先问它，
    /// 免得逐记号匹配与它各说各话（测试 `test捕获与匹配在实测形状上完全一致` 钉住这点）。
    ///
    /// ## 边界：字符集重叠的占位段
    ///
    /// 捕获按「贪心」切分：`<ISO>` 这类无界占位段先吃最长合法前缀，再回溯到能让
    /// 其余记号成立的位置。当两个占位段字符集重叠时（Codex fork 文件名的
    /// `<ISO>` 与 `<uuidA>`），切法是**一种**合法解释而不是唯一解释。
    /// 因此消费者不许用捕获去推断语义关键的分界（会话 ID 见 `SessionGrouper`）；
    /// 捕获只用来取那些边界由字面量强制确定的段（`projects/<encodedPath>/…`、
    /// `file-history/<uuid>/…`）。
    func captures(relativePath: String) -> [PathPatternCapture]? {
        guard matches(relativePath: relativePath) else { return nil }

        let pathSegments = ProtectedPathMath.components(of: relativePath)
        var captures: [PathPatternCapture] = []

        for (index, patternSegment) in segments.enumerated() {
            // `**` 只能是最后一段：它吃掉剩余的全部分段，自己不产出捕获。
            if patternSegment.tokens == [.literal("**")] { break }
            guard index < pathSegments.count else { break }

            // 逐记号拆不开时不编一个捕获出来——命中由权威匹配说了算，
            // 这里宁可少给一个捕获，也不给一个错的。
            guard let segmentCaptures = Self.capture(tokens: patternSegment.tokens, text: pathSegments[index]) else {
                continue
            }
            captures.append(contentsOf: segmentCaptures.map { tokenIndex, kind, label, value in
                PathPatternCapture(kind: kind, label: label, segmentIndex: index, value: value)
            })
        }

        return captures
    }

    /// 第一个给定种类的占位段捕获值（`nil` 表示没捕获到）。
    func firstCapture(kind: PlaceholderKind, in relativePath: String) -> String? {
        captures(relativePath: relativePath)?.first { $0.kind == kind }?.value
    }

    // MARK: - 单段逐记号匹配

    /// 一段路径文本对一段模式记号的匹配，顺带把占位段的位置记下来。
    ///
    /// 返回 `nil` 表示这一段拆不开（不命中）。比较忽略大小写（与 `SegmentLanguage`
    /// 一致：macOS 默认文件系统大小写不敏感，忽略大小写只会多命中、不会漏命中），
    /// 但返回值永远是原文。
    static func capture(
        tokens: [PathPatternToken],
        text: String
    ) -> [(tokenIndex: Int, kind: PlaceholderKind, label: String?, value: String)]? {

        let characters = Array(text)
        let lowered = characters.map { Character($0.lowercased()) }

        func loweredLiteral(_ literal: String) -> [Character] {
            literal.map { Character($0.lowercased()) }
        }

        /// 原文区间 → 字符串。
        func original(_ range: Range<Int>) -> String { String(characters[range]) }

        var result: [(Int, PlaceholderKind, String?, String)]?

        /// - Returns: 是否找到了完整匹配。
        func walk(_ tokenIndex: Int, _ offset: Int, _ collected: [(Int, PlaceholderKind, String?, String)]) -> Bool {
            if tokenIndex == tokens.count {
                guard offset == characters.count else { return false }
                result = collected
                return true
            }

            switch tokens[tokenIndex] {
            case let .literal(literal):
                let expected = loweredLiteral(literal)
                guard offset + expected.count <= characters.count,
                      Array(lowered[offset ..< offset + expected.count]) == expected
                else { return false }
                return walk(tokenIndex + 1, offset + expected.count, collected)

            case let .optionalLiteral(literal):
                // 可选字面量：先试「带上」，再试「不带」（与 `SegmentLanguage` 的变体展开同序）。
                let expected = loweredLiteral(literal)
                if offset + expected.count <= characters.count,
                   Array(lowered[offset ..< offset + expected.count]) == expected,
                   walk(tokenIndex + 1, offset + expected.count, collected) {
                    return true
                }
                return walk(tokenIndex + 1, offset, collected)

            case .wildcard:
                // `*`：单段内任意文本（可以为空）。贪心：先试最长。
                var end = characters.count
                while end >= offset {
                    if walk(tokenIndex + 1, end, collected) { return true }
                    end -= 1
                }
                return false

            case let .placeholder(kind, label):
                let characterClass = SegmentLanguage.characterClass(for: kind)
                // 先求出这一段的字符集能连续吃到哪里，再贪心地从最长往短试。
                var furthest = offset
                while furthest < characters.count, characterClass.matches(lowered[furthest]) {
                    furthest += 1
                }
                var end = furthest
                while end > offset {
                    let next = collected + [(tokenIndex, kind, label, original(offset ..< end))]
                    if walk(tokenIndex + 1, end, next) { return true }
                    end -= 1
                }
                return false
            }
        }

        guard walk(0, 0, []) else { return nil }
        return result?.map { (tokenIndex: $0.0, kind: $0.1, label: $0.2, value: $0.3) }
    }
}
