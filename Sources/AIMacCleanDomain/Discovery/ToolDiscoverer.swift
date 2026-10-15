import Foundation

import AIMacCleanCore
import AIMacCleanRules

/// 浅扫发现器（Seam 1；issue #12 建立、issue #18 改为**规则驱动**）。
///
/// 输入：一份**已验证可用的规则集**（`RuleSetAdmission` 的 `usableRules`）与主目录。
/// 输出：候选列表。
///
/// ## 扫描口径：范围完全由规则文件决定（issue #18）
///
/// 浅扫**不枚举任何通用位置**。它只看规则声明的工具根：对每一个声明路径做一次
/// 存在性与「是不是符号链接」的判断，存在就在它内部比对结构指纹。
///
/// 换掉之前的原因是可量化的：旧口径按 PRD §4.2 那份通用清单把 `~`、`~/.cache`、
/// `~/Library/Containers` 等九个位置逐个列举一遍，本机合计约 1,400 个一级目录
/// （`~/Library/Containers` 一处就 728 个），而这层枚举**几乎不产生任何候选**——
/// 准入要求「命中规则声明的工具根」，而那些目录本来就没有规则声明它们。
/// 为了找 5 个已知工具扫了 1,400 个无关目录，观感上也让产品退化成一个通用硬盘清理器。
///
/// **新增一个工具 = 新增一个规则文件，代码零改动**（User Story 20 的意图
/// 从此成为扫描口径本身，而不只是实现上的方便）。
///
/// ## 不变式
///
/// 1. **结构指纹才准入**：目录必须落在某条规则声明的工具根上，才进入候选判定；
///    命中该规则声明的结构特征（会话文件路径模式 / 会话目录形态 / 项目目录形态）
///    才能拿到「中」以上的档位。名称关键词只参与排序，永远不参与准入
///    （User Story 8、9、PRD A1）——所以一个名字里含 `claude` 却没有结构的目录
///    **根本不会出现在候选列表里**。
/// 2. **不跟随符号链接**：遍历与指纹匹配都不解析符号链接（User Story 12）。
///    候选的受保护判定另按链接真实目标进行（issue #9）。
/// 3. **浅扫、不递归算大小**：工具根只做存在性判断；比对结构指纹时的下潜有层数与
///    条目数上限（User Story 2、44）。
///    **与 spec / US2「只遍历一级子目录」不再是偏差**：规则驱动的口径下，
///    「一级」这个说法本就没有意义——DeepSeek Harness 的真实工具根
///    `~/Library/Application Support/deepseek-harness-desktop/harness-home` 是那一层的
///    **孙子**（PRD §14.5），OpenCode 的数据根在 `~/.local/share/opencode`（PRD §5.4）。
///    这两条能被发现不是「多下潜了几层」，而是**规则直接声明了那个路径**。
///    代价边界有断言钉着：浅扫不会为了找一个声明路径去枚举它缺失的父目录
///    （见 `RuleDrivenScanTests` 的对照实验）。
/// 4. **错误按目录隔离**：读不到一个目录只跳过它自己，并在结果里说明；
///    整体扫描不失败，空结果是成功（User Story 13、14）。
/// 5. **只读元数据与文件头**：文件内容最多读 `headerByteLimit` 字节，且只读开头；
///    自带压缩的文件（`.zst` / `.zstd` …）只按扩展名识别，不解压（User Story 11、24）。
/// 6. **安装检测不是硬过滤器**：某个工具没装不影响它的数据目录被发现——卸载了工具、
///    磁盘上会话还在，正是这个产品最该帮用户发现的场景。安装证据只决定「高 / 中」
///    与同档内的先后（issue #18；见 `InstallationDetection`）。
public struct ToolDiscoverer {

    private let rules: [ToolRule]
    private let hints: DiscoveryHints
    private let externalEvidence: ExternalEvidence
    private let fileSystem: any DiscoveryFileSystem
    private let homeDirectory: String

    /// - Parameters:
    ///   - rules: **已准入**的规则集（`RuleSetAdmission.admit(...).usableRules`）。
    ///   - hints: 名称关键词与负向名单。默认空：没有词表就只是不排序、不降权。
    ///   - externalEvidence: 外部佐证（同名 App / PATH 命令）。默认空。
    ///   - fileSystem: 浅扫读磁盘的那一层（issue #18）。默认真实文件系统；
    ///     测试注入记录器后可以逐条断言「一次发现访问了哪些路径」。
    ///   - homeDirectory: 把规则里的 `~/` 展开成绝对路径用的主目录，由调用方给出。
    public init(
        rules: [ToolRule],
        hints: DiscoveryHints = .none,
        externalEvidence: ExternalEvidence = .none,
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem(),
        homeDirectory: String
    ) {
        self.rules = rules
        self.hints = hints
        self.externalEvidence = externalEvidence
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
    }

    /// 规则驱动浅扫一次（issue #18）。
    ///
    /// 步骤只有两步，且顺序本身就是纪律：
    /// 1. 对规则声明的每一个工具根做一次存在性与符号链接判断（不列举父目录）。
    /// 2. 存在的那些，在其内部比对结构指纹，产出候选。
    ///
    /// 全程不碰任何规则没有声明的位置——这正是旧口径要去掉的那件事。
    public func discover() -> DiscoveryResult {
        var unreadable: [UnreadableDirectory] = []
        var candidates: [Candidate] = []
        let reader = ShallowDirectoryReader(fileSystem: fileSystem)

        for path in declaredToolRootPaths() {
            // 声明路径本身不存在只是「这里没有可看的东西」（User Story 22），不算读不到；
            // 是符号链接则不跟随——它指向哪里不关浅扫的事（User Story 12）。
            guard reader.isDirectory(path), !reader.isSymbolicLink(path) else { continue }
            guard let candidate = candidate(
                forToolRootAt: path,
                reader: reader,
                unreadable: &unreadable
            ) else { continue }
            candidates.append(candidate)
        }

        return DiscoveryResult(
            candidates: sorted(candidates),
            unreadableDirectories: unreadable
        )
    }

    /// 规则集里声明过的全部工具根目录的绝对路径（只认 `role == .toolRoot`）。
    private func declaredToolRootPaths() -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for rule in rules {
            for root in rule.roots where root.role == .toolRoot {
                let path = resolvedRootPath(root.path)
                if seen.insert(path).inserted { paths.append(path) }
            }
        }
        return paths
    }

    // MARK: - 候选判定

    /// 一个规则声明的工具根是否成为候选；不是就返回 `nil`（名字再像也不行）。
    ///
    /// **准入只认两件事**：目录落在规则声明的工具根上，以及该规则声明的结构指纹命中。
    /// 名称关键词、负向名单、外部佐证都不参与「是否入列」这道判断。
    private func candidate(
        forToolRootAt path: String,
        reader: ShallowDirectoryReader,
        unreadable: inout [UnreadableDirectory]
    ) -> Candidate? {
        guard let rule = rule(declaringToolRootAt: path) else { return nil }
        guard let fingerprint = rule.structuralFingerprint else { return nil }

        let evaluated = FingerprintEvaluator.evaluate(
            fingerprint: fingerprint,
            toolRootPath: path,
            reader: reader
        )
        unreadable.append(contentsOf: evaluated.unreadable)

        // 两件不同的事，各用各的依据：
        // - `nameMatches` 说的是「目录名命中了哪些关键词」——只反映名字，界面如实这么显示；
        // - 外部佐证问的是「这台机器上装没装这个工具」，依据是**候选所属的规则**，
        //   不是目录名碰巧命中了哪几个词。
        let nameMatches = matchedKeywords(ruleIdentifier: rule.id, of: path)
        let corroborations = externalEvidence.corroborations(forKeywords: corroborationKeywords(for: rule))
            + contentCorroborations(from: evaluated.evidence.contentFeatures)

        let signals = ConfirmationSignals(
            structuralFingerprints: evaluated.evidence.fingerprints,
            nameMatches: nameMatches,
            externalCorroborations: corroborations
        )

        var demotions: [CandidateDemotion] = []
        var confidence: ConfidenceTier
        var isSuspicious = false

        if evaluated.evidence.hasStructuralMatch {
            // 结构指纹 + 外部佐证 = 高；只有结构指纹 = 中（spec #7 §置信度模型）。
            confidence = corroborations.isEmpty ? .medium : .high
        } else {
            // 没有结构证据：只有位置像它，标为「疑似」并默认折叠（User Story 4）。
            confidence = .low
            isSuspicious = true
            demotions.append(.missingStructuralFingerprint)
        }

        if let negative = negativePattern(matching: path) {
            // 负向名单：已知易误判的名字（`-bak` 旧快照、工具伴生小工具）降权并标疑似
            // （User Story 5、6、PRD A1）。**降权不改变入列**——它已经因为结构证据入列了。
            confidence = .low
            isSuspicious = true
            demotions.append(.negativeNamePattern(negative))
        }

        return Candidate(
            toolRootPath: path,
            displayPath: DisplayPath.abbreviate(path, homeDirectory: homeDirectory),
            ruleIdentifier: rule.id,
            ruleDisplayName: rule.displayName,
            confidence: confidence,
            isSuspicious: isSuspicious,
            signals: signals,
            demotions: demotions,
            protection: BuiltInProtectedPaths.protection(
                forPath: path,
                underToolRoot: path,
                homeDirectory: homeDirectory
            )
        )
    }

    /// 声明了这个工具根的规则（只认 `role == .toolRoot`；`displayOnly` 不参与准入）。
    ///
    /// 多条规则声明同一个工具根时取第一条：规则集顺序由调用方决定，结果因此可复现。
    private func rule(declaringToolRootAt path: String) -> ToolRule? {
        rules.first { rule in
            rule.roots.contains { root in
                root.role == .toolRoot && resolvedRootPath(root.path) == path
            }
        }
    }

    /// 把规则里的 `~/…` 或绝对路径展开成绝对路径。
    private func resolvedRootPath(_ declared: String) -> String {
        let prefix = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        let expanded = declared.hasPrefix("~/") ? prefix + String(declared.dropFirst(1)) : declared
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }

    /// 拿去找同名 App / PATH 命令的词：**候选所属规则**声明的关键词，加上它的展示名。
    ///
    /// 依据是规则而不是目录名。早先的实现把两件事混成一件：先筛出「目录名命中了哪几个
    /// 关键词」，再用这些词去找外部佐证。词表是**用户可改的配置**，漏配关键词很正常——
    /// 一旦漏配，装了 OpenCode 也佐证不了 `~/.local/share/opencode`，「结构指纹 + 外部佐证
    /// = 高」这条就永远拿不到（User Story 10）。
    ///
    /// 展示名也参与匹配，因为它是规则自带的、不依赖用户词表的第二来源：
    /// `OpenCode` → `opencode`，`DeepSeek Harness` → `deepseek` / `harness`。
    /// 匹配仍然**忽略大小写与 `.app` 后缀**（见 `ExternalEvidence`），因此不相干的
    /// App 仍然不构成佐证。
    private func corroborationKeywords(for rule: ToolRule) -> [String] {
        var keywords = hints.keywords(forRuleIdentifier: rule.id)
        let displayName = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !displayName.isEmpty {
            keywords.append(displayName)
            keywords.append(
                contentsOf: displayName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
            )
        }

        var seen: Set<String> = []
        return keywords.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// 名称关键词命中（只用于排序，不参与准入，也不决定外部佐证）。
    private func matchedKeywords(ruleIdentifier: String, of path: String) -> [String] {
        let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? path.lowercased()
        return hints.keywords(forRuleIdentifier: ruleIdentifier).filter { keyword in
            !keyword.isEmpty && name.contains(keyword.lowercased())
        }
    }

    /// 命中的负向名单模式（`*` 匹配任意字符，忽略大小写）。
    ///
    /// ## 比对范围：主目录之下、直到工具根的每一段
    ///
    /// 规则驱动之后没有「扫描根」这层东西了（issue #18），判定边界改成**主目录**：
    /// 主目录以下的段（`Library`、`Application Support`、`.claude`、`harness-home` …）
    /// 全部参与比对，工具根自己的名字一定在内。
    ///
    /// 主目录**本身及以上**（`Users`、用户名、以及主目录目录名）永远不参与比对。
    /// 早先的实现按整条路径逐段全比，于是 `$HOME` 以上的段也进了比对范围：
    /// 一个叫 `…-backup/Users/x` 的主目录会把该主目录下**每一个**候选都降权成疑似，
    /// 界面还写「命中负向名单 *backup*」——而那条路径本身没有任何问题。
    /// 名字判定只能落在浅扫真正看过的位置，否则等于让用户目录名替工具背锅。
    ///
    /// 声明路径不在主目录之下时只比对它最后一段：宁可漏判降权，也不误判——
    /// 降权会挡住用户看见真正的高置信度候选。
    private func negativePattern(matching path: String) -> String? {
        let components = judgedComponents(of: path)
        guard !components.isEmpty else { return nil }

        return hints.negativeNamePatterns.first { pattern in
            components.contains { GlobPattern.matches(pattern: pattern, text: $0) }
        }
    }

    /// 名字判定真正看的那几段：主目录之下、直到工具根（含末段）。
    private func judgedComponents(of path: String) -> [String] {
        let all = path.split(separator: "/").map(String.init)
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory

        let homeDepth = home.split(separator: "/").count
        guard path.hasPrefix(home + "/"), all.count > homeDepth else {
            return all.suffix(1).map { $0 }
        }
        return Array(all[homeDepth...])
    }

    /// 文件头字段特征 → 外部佐证。
    private func contentCorroborations(from features: [String]) -> [ExternalCorroboration] {
        guard !features.isEmpty else { return [] }
        return [.contentFeature("会话文件开头含字段 " + features.joined(separator: "、"))]
    }

    // MARK: - 排序

    /// 候选排序：高 → 中 → 低；同档里名字命中关键词的排前面；再按路径排序保证可复现。
    ///
    /// 关键词在这里才起作用——它只影响**顺序**，不影响谁进了列表（User Story 9）。
    private func sorted(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { left, right in
            if left.confidence != right.confidence { return left.confidence > right.confidence }
            let leftKeyword = !left.signals.nameMatches.isEmpty
            let rightKeyword = !right.signals.nameMatches.isEmpty
            if leftKeyword != rightKeyword { return leftKeyword }
            return left.toolRootPath < right.toolRootPath
        }
    }
}

/// 单段内的通配符匹配：`*` 匹配任意字符，忽略大小写。
///
/// 词表（关键词与负向名单）要能写得出来、读得懂，语义刻意保持最简单的一种，
/// 不引入正则——负向名单是给人手写的配置。
enum GlobPattern {
    static func matches(pattern: String, text: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let text = Array(text.lowercased())
        if pattern == ["*"] { return true }

        var patternIndex = 0
        var textIndex = 0
        var lastStarIndex = -1
        var resumeIndex = 0

        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                lastStarIndex = patternIndex
                resumeIndex = textIndex
                patternIndex += 1
            } else if lastStarIndex >= 0 {
                patternIndex = lastStarIndex + 1
                resumeIndex += 1
                textIndex = resumeIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}
