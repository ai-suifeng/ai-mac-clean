import Foundation

/// 两个路径模式分段之间的关系判定。
///
/// 只回答三件事，全部只依赖模式本身，**不 stat 磁盘**（规则声明的路径可以不存在）：
///
/// - `matches`：这个分段能不能匹配某个具体路径分段；
/// - `isContained`：这个分段匹配的全部字符串，是不是都落在另一个分段的范围内；
/// - `intersects`：两个分段有没有共同的匹配结果。
///
/// 判定的方向很重要。准入用的是 `isContained`：
/// **只有当用户分类模式的每一个可能取值都落在内置受保护区域内，才算「把受保护路径
/// 改判了」**。`auth.json` 落在 `auth*` 之内 → 拒绝；`logs/**` 只是可能顺带包含一个
/// `auth.json` → 那是规则写得粗糙，不是「改判」，执行时仍由代码层的内置保护兜底
/// （PRD §8.3：命中受保护规则的路径即使被规则选中，也直接拒绝归档与移除）。
enum SegmentRelation {

    /// 这个分段能不能匹配 `text`。
    static func matches(_ language: SegmentLanguage, text: String) -> Bool {
        let normalized = text.lowercased()
        return language.variants.contains { RunAutomaton(runs: $0).accepts(normalized) }
    }

    /// `a` 匹配的全部字符串是否都被 `b` 匹配（`a ⊆ b`）。
    static func isContained(_ a: SegmentLanguage, in b: SegmentLanguage) -> Bool {
        a.variants.allSatisfy { left in
            b.variants.contains { RunAutomaton(runs: left).isContained(in: RunAutomaton(runs: $0)) }
        }
    }

    /// `a` 与 `b` 是否存在共同的匹配结果。
    static func intersects(_ a: SegmentLanguage, _ b: SegmentLanguage) -> Bool {
        a.variants.contains { left in
            b.variants.contains { right in RunAutomaton(runs: left).intersects(RunAutomaton(runs: right)) }
        }
    }
}

/// 游程序列上的小型非确定自动机。
///
/// 状态是「当前游程 + 已消耗长度」；游程达到最小长度后可以 epsilon 步进到下一段游程，
/// 也可以在字符集内多消耗一个字符。无界游程的偏移量被压成 0/1 两态，
/// 因此状态总数很小（每个字符游程至多 2 态），判定不会因模式变长而发散。
struct RunAutomaton {
    typealias State = Int

    let runs: [SegmentLanguage.Run]

    init(runs: [SegmentLanguage.Run]) {
        self.runs = runs
    }

    private func encode(atom: Int, offset: Int) -> State { atom * 2 + offset }

    private var start: State { encode(atom: 0, offset: 0) }

    private func isAccepting(_ state: State) -> Bool { state / 2 == runs.count }

    /// 无界游程的偏移量压到 0/1：再往后与「已吃一个字符」完全等价。
    private func clamped(_ offset: Int, in atom: Int) -> Int {
        guard let maximum = runs[atom].maximumLength else { return offset > 0 ? 1 : 0 }
        return min(offset, maximum)
    }

    /// 自动机上的一步：epsilon 步不消耗字符，带标签的步消耗一个落在标签里的字符。
    private enum Step {
        case epsilon(to: State)
        case consume(_ characters: SegmentLanguage.CharacterClass, to: State)
    }

    private func successors(of state: State) -> [Step] {
        let atom = state / 2
        let offset = state % 2
        guard atom < runs.count else { return [] }

        let run = runs[atom]
        var next: [Step] = []

        if offset >= run.minimumLength {
            next.append(.epsilon(to: encode(atom: atom + 1, offset: 0)))
        }
        if offset < (run.maximumLength ?? Int.max) {
            next.append(.consume(run.characters, to: encode(atom: atom, offset: clamped(offset + 1, in: atom))))
        }
        return next
    }

    // MARK: 匹配

    /// 是否存在完整匹配 `text` 的路径。
    func accepts(_ text: String) -> Bool {
        let characters = Array(text)
        var failed: Set<Int> = []

        func walk(_ state: State, _ position: Int) -> Bool {
            if isAccepting(state) { return position == characters.count }
            let key = state * (characters.count + 1) + position
            if failed.contains(key) { return false }

            var matched = false
            for step in successors(of: state) {
                switch step {
                case let .epsilon(to):
                    matched = walk(to, position)
                case let .consume(label, to):
                    if position < characters.count, label.matches(characters[position]) {
                        matched = walk(to, position + 1)
                    }
                }
                if matched { break }
            }
            if !matched { failed.insert(key) }
            return matched
        }

        return walk(start, 0)
    }

    // MARK: 关系判定

    /// 与 `other` 是否存在被两边同时接受的字符串。
    ///
    /// 普通乘积图：epsilon 步可以与对方的任意一步自由配对，因此这里允许两侧异步推进。
    func intersects(_ other: RunAutomaton) -> Bool {
        var queue: [(State, State)] = [(start, other.start)]
        var index = 0
        var seen: Set<StatePair> = []

        while index < queue.count {
            let (left, right) = queue[index]
            index += 1
            guard seen.insert(StatePair(left: left, right: right)).inserted else { continue }
            if isAccepting(left), other.isAccepting(right) { return true }

            for leftStep in successors(of: left) {
                for rightStep in successors(of: right) {
                    switch (leftStep, rightStep) {
                    case let (.epsilon(left), .epsilon(right)):
                        queue.append((left, right))
                    case let (.epsilon(left), .consume(_, right)):
                        queue.append((left, right))
                    case let (.consume(_, left), .epsilon(right)):
                        queue.append((left, right))
                    case let (.consume(leftLabels, left), .consume(rightLabels, right)):
                        if leftLabels.intersects(rightLabels) { queue.append((left, right)) }
                    }
                }
            }
        }
        return false
    }

    /// 本自动机匹配的全部字符串是否都被 `other` 接受。
    ///
    /// 用**同步子集构造**：两侧读同一个前缀，各自维护「读完这个前缀后可能处在的状态
    /// 集合」。凡是出现「本侧已接受、对方不可能接受」的前缀，就有一条逃出 `other` 的
    /// 路径，包含关系不成立。
    ///
    /// 这里必须同步推进：乘积图允许一侧 epsilon 步与对方的读字符步自由配对，那对「求交」
    /// 正确，对「求包含」会漏判（前缀只被一侧吃掉，另一侧原地不动，看起来仍「有路可走」）。
    func isContained(in other: RunAutomaton) -> Bool {
        var frontier: Set<StatePair> = [StatePair(left: [start], right: [other.start])]
        var visited: Set<StatePair> = []

        while let pair = frontier.popFirst() {
            guard visited.insert(pair).inserted else { continue }

            let left = closure(pair.left)
            let right = other.closure(pair.right)
            if left.contains(where: isAccepting) && !right.contains(where: other.isAccepting) {
                return false
            }
            // 对方已经拒绝这个前缀：继续单侧推进本自动机，它一旦接受就是逃逸前缀。
            if right.isEmpty {
                guard !left.isEmpty else { continue }
                for character in characters(left, other: other) {
                    frontier.insert(StatePair(left: advance(left, by: character), right: []))
                }
                continue
            }
            // 本侧已经拒绝这个前缀：这条分支不可能再产生逃逸前缀。
            guard !left.isEmpty else { continue }

            for character in characters(left, other: other) {
                frontier.insert(StatePair(left: advance(left, by: character),
                                          right: other.advance(right, by: character)))
            }
        }

        return true
    }

    // MARK: 内部

    /// epsilon 闭包：不吃字符、只跨游程前进的那些步。
    private func closure(_ states: Set<State>) -> Set<State> {
        var result = states
        var queue = Array(states)
        var index = 0
        while index < queue.count {
            for step in successors(of: queue[index]) {
                if case let .epsilon(to) = step, result.insert(to).inserted {
                    queue.append(to)
                }
            }
            index += 1
        }
        return result
    }

    /// 读一个字符后可能到达的状态集合。
    private func advance(_ states: Set<State>, by character: Character) -> Set<State> {
        var result: Set<State> = []
        for state in states {
            for step in successors(of: state) {
                if case let .consume(label, to) = step, label.matches(character) {
                    result.insert(to)
                }
            }
        }
        return result
    }

    /// 需要考虑的字符：两侧字面集合里的字符，外加一个「其它任意字符」的代表元
    /// （对应 `*` 这类「什么都能吃」的标签——只有它能吃住这个代表元）。
    private func characters(_ left: Set<State>, other: RunAutomaton) -> Set<Character> {
        var result: Set<Character> = [Self.otherCharacter]
        for automaton in [self, other] {
            for character in automaton.literalCharacters {
                result.insert(character)
            }
        }
        return result
    }

    /// 本自动机里出现过的字面字符。
    private var literalCharacters: Set<Character> {
        var result: Set<Character> = []
        for run in runs {
            if case let .explicit(characters) = run.characters {
                result.formUnion(characters)
            }
        }
        return result
    }

    /// 「既不属于任何字面集合、又确实能被 `*` 匹配」的字符代表元。
    static let otherCharacter = Character("\u{1}")

    private struct StatePair: Hashable {
        let left: Set<State>
        let right: Set<State>

        init(left: Set<State>, right: Set<State>) {
            self.left = left
            self.right = right
        }

        init(left: State, right: State) {
            self.left = [left]
            self.right = [right]
        }
    }
}
