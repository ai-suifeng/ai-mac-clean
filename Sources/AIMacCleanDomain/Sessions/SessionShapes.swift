import Foundation

import AIMacCleanRules

/// 一台工具的「会话形状目录」（issue #26）。
///
/// 会话归组是**规则驱动**的：哪些路径是会话文件、哪些是与主转录同级的子代理转录、
/// 哪些是按会话 ID 关联的数据，全部来自规则文件的 `structuralFingerprint.sessionFilePatterns`
/// 与 `cascade` 声明。新增一个已知工具因此只需要新增一个规则文件，本层不出现
/// 「如果是 Claude 就……」这种分支（PRD §5.2）。
///
/// 本类型只做「路径 → 形状」的判定，不碰磁盘、不判类别——类别由深扫那条判定链
/// （`DeepScanRuleCatalog`）负责，避免同一件事出现两套答案。
struct SessionShapeCatalog {

    /// 会话文件形状（相对工具根）。声明顺序保留，用于稳定排序。
    let sessionPatterns: [PathPattern]

    /// 级联声明（`siblingTranscripts` / `sessionKeyedDirectory` / `sessionKeyedFile`）。
    let cascades: [CascadeRelationship]

    /// 目录剪枝用的「字面前缀」集合；为空表示不剪枝（有形状不以字面开头）。
    ///
    /// 一条路径只有落在某条声明形状的字面前缀下才**可能**命中它（`projects/…` 只可能
    /// 出现在 `projects` 下）。据此可以只走必要的那几棵子树：`~/.claude/plugins`、
    /// `~/.codex/.tmp` 这类实测大头（247M / 879M）连列举都不必。
    let pruningBases: [String]

    init(rule: ToolRule) {
        sessionPatterns = rule.structuralFingerprint?.sessionFilePatterns ?? []
        cascades = rule.cascade

        // 剪枝范围必须覆盖「可能被判为可归档」的全部形状：会话文件、级联声明，
        // 以及分类表里声明为可归档的条目（散落文件也要如实呈现，不能因为剪枝漏掉）。
        var patterns = sessionPatterns
        patterns.append(contentsOf: cascades.map(\.pattern))
        patterns.append(contentsOf: rule.classification
            .filter { $0.category == .archivableSession }
            .map(\.pattern))

        var bases: [String] = []
        var unbounded = false
        for pattern in patterns {
            let prefix = Self.literalPrefix(of: pattern)
            if prefix.isEmpty {
                // 有形状不以字面开头（`**/x.jsonl`、`*/y`）：剪枝会漏，直接全走。
                unbounded = true
                break
            }
            if !bases.contains(prefix) { bases.append(prefix) }
        }
        pruningBases = unbounded ? [] : bases
    }

    /// 目录是否值得进去：它的相对路径必须是某个字面前缀的前缀。
    func shouldDescend(into relativeDirectory: String) -> Bool {
        guard !pruningBases.isEmpty else { return true }
        return pruningBases.contains { base in
            base == relativeDirectory || base.hasPrefix(relativeDirectory + "/")
        }
    }

    /// 这条路径命中的**最具体**的会话文件形状；没有命中的返回 `nil`。
    ///
    /// 多条形状同时命中时（Codex 的 `rollout-<ISO>.jsonl[.zst]` 与带两个 UUID 的
    /// fork 形态），取「具名占位段最少、通配最少、可选字面量最少、字面字符最多」的那条，
    /// 再用模式串本身做稳定平手判定。规则文件的声明顺序因此不影响结果。
    func bestSessionPattern(for relativePath: String) -> PathPattern? {
        sessionPatterns
            .filter { $0.matches(relativePath: relativePath) }
            .min { lhs, rhs in Self.isMoreSpecific(lhs, than: rhs) }
    }

    /// 同级转录的基准目录：**最深的**那个祖先目录，使得剩下部分命中级联模式。
    ///
    /// 级联模式的基准是「主转录所在目录」（`CascadeRelationship` 的说明），
    /// 因此这里从最深的祖先往上找第一个命中的；找不到就是 `nil`（形状对不上，
    /// 由调用方如实归入未归组）。
    func siblingBaseDirectory(for relativePath: String, pattern: PathPattern) -> String? {
        let components = PathText.components(of: relativePath)
        guard components.count > 1 else { return nil }
        for cut in stride(from: components.count - 1, through: 0, by: -1) {
            let remainder = components.dropFirst(cut).joined(separator: "/")
            guard pattern.matches(relativePath: remainder) else { continue }
            return components.prefix(cut).joined(separator: "/")
        }
        return nil
    }

    /// 按会话 ID 命名的关联数据目录的会话 ID（形如 `file-history/<会话UUID>`）。
    func keyedDirectorySessionID(for relativePath: String, pattern: PathPattern) -> String? {
        let components = PathText.components(of: relativePath)
        guard components.count > 1 else { return nil }
        for cut in stride(from: components.count - 1, through: 1, by: -1) {
            let directory = components.prefix(cut).joined(separator: "/")
            guard pattern.matches(relativePath: directory) else { continue }
            return pattern.captures(relativePath: directory)?
                .first { $0.kind == .uuid }?
                .value
        }
        return nil
    }

    /// 文件名里带会话 ID 的关联数据文件的会话 ID（形如
    /// `todos/<会话UUID>-agent-<另一个UUID>.json`）。
    ///
    /// 取**第一个** `<uuid>` 捕获：规则声明的顺序就是语义顺序（先会话 UUID，后代理 UUID），
    /// 且两者之间的字面量 `-agent-` 强制了边界，不受字符集重叠影响。
    func keyedFileSessionID(for relativePath: String, pattern: PathPattern) -> String? {
        pattern.captures(relativePath: relativePath)?.first { $0.kind == .uuid }?.value
    }

    // MARK: - 内部

    /// 模式的字面前缀：第一个带通配或占位符的段之前的所有段。
    static func literalPrefix(of pattern: PathPattern) -> String {
        var literals: [String] = []
        for segment in pattern.segments {
            guard segment.tokens.count == 1,
                  case let .literal(text) = segment.tokens[0],
                  text != "**"
            else { break }
            literals.append(text)
        }
        return literals.joined(separator: "/")
    }

    /// 具体性比较：`lhs` 是否比 `rhs` 更具体（用于 `min`）。
    static func isMoreSpecific(_ lhs: PathPattern, than rhs: PathPattern) -> Bool {
        let left = specificity(of: lhs)
        let right = specificity(of: rhs)
        for index in left.indices where left[index] != right[index] {
            // 前三项越小越好，第四项（字面字符数）越大越好。
            return index == 3 ? left[index] > right[index] : left[index] < right[index]
        }
        return lhs.canonicalString < rhs.canonicalString
    }

    /// (具名占位段数, 通配数, 可选字面量数, 字面字符数)。
    static func specificity(of pattern: PathPattern) -> [Int] {
        var namePlaceholders = 0
        var wildcards = 0
        var optionalLiterals = 0
        var literalCharacters = 0
        for segment in pattern.segments {
            for token in segment.tokens {
                switch token {
                case let .literal(text):
                    literalCharacters += text.count
                case .wildcard:
                    wildcards += 1
                case let .placeholder(kind, _):
                    if kind == .name { namePlaceholders += 1 }
                case let .optionalLiteral(text):
                    optionalLiterals += 1
                    literalCharacters += text.count
                }
            }
        }
        return [namePlaceholders, wildcards, optionalLiterals, literalCharacters]
    }
}

/// 会话 ID 的推导（issue #26 范围第 5 条）。
///
/// 规则用两条声明决定这件事：`sessionFileNaming.sessionIDSource` 说 ID 在文件名里还是
/// 父目录名里；`sessionFileNaming.stableSessionIdentifier` 说这个 ID 稳不稳定。
/// 引擎**不反向解码**任何编码路径——那件事有歧义（PRD §5.3）。
///
/// ## 文件名里有两个 UUID 时取哪一个
///
/// Codex 的 fork 会话文件名含两个 UUID（`rollout-<ISO>-<uuidA>_<uuidB>`），规则已经声明
/// 「文件名不是稳定 ID，一个逻辑会话可能跨多个文件」（`stableSessionIdentifier: false`）。
/// 本层选择的语义是：**取文件名里第一个 UUID 形状的记号**（fork 形态下即父 UUID）。
/// 于是 fork 出来的文件与它派生自的那份转录归到**同一个逻辑会话**，
/// 这正是 PRD §5.4 对 fork 的要求；测试 `testCodex的fork文件与它派生自的转录归为同一个会话`
/// 把这条语义钉死。
///
/// 之所以不靠模式捕获去切这两个 UUID：`<ISO>` 与 `<uuid>` 的字符集重叠
/// （见 `PathPattern.captures` 的边界说明），哪种切法都能自圆其说。按「文件名里第一个
/// UUID 形状记号」切则只有一个答案。
enum SessionIdentity {

    /// 会话 ID；规则没有声明 `sessionFileNaming` 时按「文件名」这一最常见形态处理
    /// （文档未规定默认值，这里取保守且与四个内置工具一致的取值）。
    static func sessionID(forRelativePath relativePath: String, source: SessionIDSource) -> String {
        let components = PathText.components(of: relativePath)
        let name = components.last ?? relativePath

        switch source {
        case .parentDirectoryName:
            // 会话 ID 在父目录名里（Harness：`session-<uuid>/session.jsonl.zstd`）。
            if components.count >= 2, let parent = components.dropLast().last, !parent.isEmpty {
                return parent
            }
            return fileNameStem(name)

        case .fileName:
            let stem = fileNameStem(name)
            if let uuid = firstUUID(in: stem) { return uuid }
            // 文件名里没有 UUID 形状的记号（合成夹具里就有这种名字）：退回整个主干，
            // 保证「一个会话文件至少有一个稳定的 ID」，绝不静默丢弃。
            return stem
        }
    }

    /// 去掉扩展名链之后的主干：`rollout-….jsonl.zst` → `rollout-…`、`<uuid>.jsonl` → `<uuid>`。
    static func fileNameStem(_ name: String) -> String {
        guard let dot = name.firstIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex ..< dot])
    }

    /// 文件名里第一个 UUID 形状的记号（`8-4-4-4-12` 个十六进制字符）。
    ///
    /// 不做「两侧必须是边界」的额外要求：真实文件名里 UUID 两边就是 `-`，
    /// 而 `-` 本身属于 UUID 字符集，用它当边界只会把正确答案挡掉。
    /// 形状本身（五组定长十六进制）已经把 ISO 时间戳那一段排除在外
    /// （`2026-10-14T10-00-00` 里没有任何一段是 8 位十六进制）。
    static func firstUUID(in text: String) -> String? {
        let groups = [8, 4, 4, 4, 12]
        let characters = Array(text.lowercased())

        func isHex(_ character: Character) -> Bool { character.isHexDigit }

        for start in characters.indices {
            var index = start
            var matched = true
            for (groupIndex, length) in groups.enumerated() {
                guard index + length <= characters.count,
                      characters[index ..< index + length].allSatisfy(isHex)
                else { matched = false; break }
                index += length
                if groupIndex < groups.count - 1 {
                    guard index < characters.count, characters[index] == "-" else { matched = false; break }
                    index += 1
                }
            }
            if matched { return String(characters[start ..< index]) }
        }
        return nil
    }
}
