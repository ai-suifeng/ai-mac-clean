import Foundation

/// 一个路径模式**分段**能匹配哪些字符串（issue #11 保护单调性判定的基础）。
///
/// 分段里的记号被展开成一串「字符集 + 长度区间」的游程（run），再用一个小自动机做
/// 交集 / 包含判定：
///
/// - 字面字符 → 单字符游程；
/// - `*` → 任意字符、长度 0 起；
/// - `<uuid>` → 只可能是十六进制与短横线（UUID 的实际取值范围）；
/// - `<date:…>` → 只可能是数字；
/// - `<encodedPath>` / `<名字>` → 单段标识符：小写字母、数字、`_`、`-`，**不含 `.`**。
///
/// 最后一条是关键：编码后的项目路径与具名段本来就是「一段不含点的标识符」
/// （`-Users-xiaowei--claude`、`rollout-2025-10-14T09-08-28`），约束住它才能让
/// `projects/<encodedPath>/<uuid>.jsonl` 这样的会话模式**不会**被误判成内置条目
/// `claude-code/history`（`history.jsonl`）。约束越紧，准入越不会误拒正常规则。
///
/// 可选字面量 `[.jsonl]` 展开成「带 / 不带」两个变体，判定时逐对比较。
struct SegmentLanguage: Equatable {

    /// 游程匹配的字符集合。
    enum CharacterClass: Equatable {
        /// 明确列出的字符（小写比较）。
        case explicit(Set<Character>)
        /// 任意字符。分段内不会出现 `/`，因此无需排除。
        case any

        static func literal(_ character: Character) -> CharacterClass { .explicit([character]) }

        func matches(_ character: Character) -> Bool {
            switch self {
            case let .explicit(characters):
                return characters.contains(character)
            case .any:
                return true
            }
        }

        func intersects(_ other: CharacterClass) -> Bool {
            switch (self, other) {
            case (.any, _), (_, .any):
                return true
            case let (.explicit(left), .explicit(right)):
                return !left.intersection(right).isEmpty
            }
        }
    }

    /// 一段连续的同字符集文本。
    struct Run: Equatable {
        let characters: CharacterClass
        let minimumLength: Int
        /// `nil` 表示无界：无界游程在自动机里只有「还没吃字符」与「已吃至少一个字符」
        /// 两个状态（再往后与只吃一个字符的状态完全等价），因此状态数不随长度增长。
        let maximumLength: Int?

        static func literal(_ character: Character) -> Run {
            Run(characters: .literal(character), minimumLength: 1, maximumLength: 1)
        }

        static func any(minimumLength: Int) -> Run {
            Run(characters: .any, minimumLength: minimumLength, maximumLength: nil)
        }
    }

    let variants: [[Run]]
    /// 该分段是否等价于 `**`（递归通配，单独成段）。
    let isRecursiveWildcard: Bool

    init(runs: [Run]) {
        variants = [runs]
        isRecursiveWildcard = false
    }

    /// 由模式分段构造。
    init(segment: PathPatternSegment) {
        // `**` 不是普通分段：它吃掉一整段路径的分段结构。做「模式是否整体落在受保护
        // 区域内」这类判定时，把它当作「任意一段」处理。
        if segment.tokens == [.literal("**")] {
            variants = [[Run.any(minimumLength: 1)]]
            isRecursiveWildcard = true
        } else {
            variants = SegmentLanguage.expand(segment.tokens)
            isRecursiveWildcard = false
        }
    }

    // MARK: 记号展开

    private static func expand(_ tokens: [PathPatternToken]) -> [[Run]] {
        var variants: [[Run]] = [[]]

        for token in tokens {
            switch token {
            case let .literal(text):
                let runs = text.lowercased().map(Run.literal)
                variants = variants.map { $0 + runs }

            case .wildcard:
                variants = variants.map { $0 + [Run.any(minimumLength: 0)] }

            case let .placeholder(kind, _):
                let run = Run(characters: characterClass(for: kind), minimumLength: 1, maximumLength: nil)
                variants = variants.map { $0 + [run] }

            case let .optionalLiteral(text):
                // 可选字面量：展开成「带上」与「不带」两个变体。
                let runs = text.lowercased().map(Run.literal)
                let withIt = variants.map { $0 + runs }
                variants = variants + withIt
            }
        }

        return variants
    }

    /// 占位符的字符集。
    static func characterClass(for kind: PlaceholderKind) -> CharacterClass {
        switch kind {
        case .uuid:
            var set = Set("0123456789abcdef")
            set.insert("-")
            return .explicit(set)
        case .date:
            return .explicit(Set("0123456789"))
        case .encodedPath, .name:
            var set = Set("abcdefghijklmnopqrstuvwxyz0123456789")
            set.insert("_")
            set.insert("-")
            return .explicit(set)
        }
    }
}
