import Foundation

import AIMacCleanCore
import AIMacCleanRules

/// 浅扫发现器（Seam 1；issue #12 / spec #7 §发现管线）。
///
/// 输入：若干**扫描根**（注入，测试用临时目录树）与一份**已验证可用的规则集**
/// （`RuleSetAdmission` 的 `usableRules`）。输出：候选列表。
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
/// 3. **浅扫**：只看扫描根的一级子目录，不递归计算体积（User Story 2、44）。
///    比对结构指纹时的下潜有层数与条目数上限。
///    **已知偏差（刻意保留，PRD §13.1 要求把偏差记下来）**：spec / US2 写的是
///    「浅扫只遍历一级子目录」，但 `discover(scanRoots:)` 还会**补一次**规则声明的工具根，
///    且不限制它在扫描根下的深度。原因有两条，缺一不可：
///    - DeepSeek Harness 的真实工具根是 `~/Library/Application Support/deepseek-harness-desktop/harness-home`，
///      是那一层目录的**孙子**（PRD §14.5）。只扫一层就永远发现不了它，
///      而「发现非标准位置」是 User Story 7 的硬要求。
///    - OpenCode 的数据根在 `~/.local/share/opencode`（PRD §5.4），同样不是一层。
///    补漏仍然**只做一次存在性判断**（不递归、不列举），因此递归成本不变；准入口径也不变：
///    照样要过结构指纹才能拿到「中」以上，声明在非隐藏位置的规则也不因此被捡起来。
/// 4. **错误按目录隔离**：读不到一个目录只跳过它自己，并在结果里说明；
///    整体扫描不失败，空结果是成功（User Story 13、14）。
/// 5. **只读元数据与文件头**：文件内容最多读 `headerByteLimit` 字节，且只读开头；
///    自带压缩的文件（`.zst` / `.zstd` …）只按扩展名识别，不解压（User Story 11、24）。
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

    /// 按 PRD §4.2 的标准扫描根浅扫一次。
    public func discover() -> DiscoveryResult {
        discover(scanRoots: ScanRoot.standard(forHomeDirectory: homeDirectory))
    }

    /// 按给定的扫描根浅扫一次。
    ///
    /// ## 与「只遍历一级子目录」的偏差
    ///
    /// spec #7 / US2 描述的是「浅扫只遍历一级子目录」。本方法在**这一层之外还补一次**：
    /// 规则声明的每一个工具根目录，只要它确实存在、不是符号链接，且不违反扫描根的
    /// 隐藏目录筛选口径（`~` 下只看隐藏目录），都会被看一眼——**不论它在扫描根下深几层**。
    ///
    /// 这是**刻意保留的偏差**，记在这里而不是悄悄做（PRD §13.1）：
    /// DeepSeek Harness 的真实工具根 `…/deepseek-harness-desktop/harness-home` 是
    /// `~/Library/Application Support` 的孙子（PRD §14.5），OpenCode 的数据根在
    /// `~/.local/share/opencode`——只扫一层就发现不了它们，而「发现非标准位置」是
    /// User Story 7 的要求。
    ///
    /// 补的那一次只判断声明路径本身存在与否（不列举、不递归），因此递归成本不变；
    /// 准入口径也不放宽：照样要过结构指纹才能拿到「中」以上。
    public func discover(scanRoots: [ScanRoot]) -> DiscoveryResult {
        var unreadable: [UnreadableDirectory] = []
        var candidates: [Candidate] = []
        var seenPaths: Set<String> = []
        let reader = ShallowDirectoryReader(fileSystem: fileSystem)

        for scanRoot in scanRoots {
            switch shallowEntries(of: scanRoot, reader: reader) {
            case let .failure(directory):
                unreadable.append(directory)
            case let .success(entries):
                for entry in entries {
                    // 一级子目录里只有「真目录」可能是工具根；符号链接不跟随。
                    guard entry.isDirectory, !entry.isSymbolicLink, seenPaths.insert(entry.path).inserted else {
                        continue
                    }
                    guard let candidate = candidate(
                        forDirectory: entry,
                        scanRootPath: scanRoot.path,
                        reader: reader,
                        unreadable: &unreadable
                    ) else { continue }
                    candidates.append(candidate)
                }
            }
        }

        // 规则声明的工具根本身也看一眼：PRD §4.2 的扫描位置全是「一层」，
        // 而 DeepSeek Harness 的真实工具根在 `~/Library/Application Support/deepseek-harness-desktop/harness-home`
        // ——它是那一层目录的**孙子**，只扫一层就永远发现不了它。
        // 这里只做一次存在性判断（不递归、不列举），因此仍然属于浅扫；
        // 它也不放宽准入：照样要过结构指纹才能拿到「中」以上。
        // 这段补漏是相对 spec「只遍历一级子目录」的**已知偏差**，理由见方法文档注释。
        for path in declaredToolRootPaths() where seenPaths.insert(path).inserted {
            // 但它**不能绕过扫描位置的筛选口径**：`~` 下只看隐藏目录（PRD §4.2），
            // 因此声明在 `~/notes` 这种非隐藏位置的规则不该被这条补漏捡起来。
            guard !isOutsideScanRootFilter(path, scanRoots: scanRoots) else { continue }
            guard reader.isDirectory(path), !reader.isSymbolicLink(path) else {
                continue
            }
            let entry = ShallowDirectoryReader.Entry(
                name: path.split(separator: "/").last.map(String.init) ?? path,
                path: path,
                isDirectory: true,
                isSymbolicLink: false
            )
            guard let candidate = candidate(
                forDirectory: entry,
                // 补漏来的路径深度不定，把它归到**最近的那个扫描根**名下，
                // 名称判定才不会越过扫描根去看更上面的段。
                scanRootPath: enclosingScanRoot(of: path, in: scanRoots)?.path,
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

    /// 这个路径是否被某个扫描根的筛选口径明确排除（如 `~` 下的非隐藏目录）。
    private func isOutsideScanRootFilter(_ path: String, scanRoots: [ScanRoot]) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last, components.count >= 2 else { return false }
        let parent = "/" + components.dropLast().joined(separator: "/")

        return scanRoots.contains { scanRoot in
            guard scanRoot.path == parent else { return false }
            switch scanRoot.entryFilter {
            case .allEntries: return false
            case .hiddenDirectoriesOnly: return !name.hasPrefix(".")
            }
        }
    }

    /// 覆盖 `path` 的、最深的那个扫描根；没有任何扫描根覆盖它时返回 `nil`。
    private func enclosingScanRoot(of path: String, in scanRoots: [ScanRoot]) -> ScanRoot? {
        scanRoots
            .filter { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
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

    /// 一个一级子目录是否成为候选；不是就返回 `nil`（名字再像也不行）。
    ///
    /// **准入只认两件事**：目录落在规则声明的工具根上，以及该规则声明的结构指纹命中。
    /// 名称关键词、负向名单、外部佐证都不参与「是否入列」这道判断。
    private func candidate(
        forDirectory entry: ShallowDirectoryReader.Entry,
        scanRootPath: String?,
        reader: ShallowDirectoryReader,
        unreadable: inout [UnreadableDirectory]
    ) -> Candidate? {
        guard let rule = rule(declaringToolRootAt: entry.path) else { return nil }
        guard let fingerprint = rule.structuralFingerprint else { return nil }

        let evaluated = FingerprintEvaluator.evaluate(
            fingerprint: fingerprint,
            toolRootPath: entry.path,
            reader: reader
        )
        unreadable.append(contentsOf: evaluated.unreadable)

        // 两件不同的事，各用各的依据：
        // - `nameMatches` 说的是「目录名命中了哪些关键词」——只反映名字，界面如实这么显示；
        // - 外部佐证问的是「这台机器上装没装这个工具」，依据是**候选所属的规则**，
        //   不是目录名碰巧命中了哪几个词。
        let nameMatches = matchedKeywords(ruleIdentifier: rule.id, of: entry.path)
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

        if let negative = negativePattern(matching: entry.path, scanRootPath: scanRootPath) {
            // 负向名单：已知易误判的名字（`-bak` 旧快照、工具伴生小工具）降权并标疑似
            // （User Story 5、6、PRD A1）。**降权不改变入列**——它已经因为结构证据入列了。
            confidence = .low
            isSuspicious = true
            demotions.append(.negativeNamePattern(negative))
        }

        return Candidate(
            toolRootPath: entry.path,
            displayPath: DisplayPath.abbreviate(entry.path, homeDirectory: homeDirectory),
            ruleIdentifier: rule.id,
            ruleDisplayName: rule.displayName,
            confidence: confidence,
            isSuspicious: isSuspicious,
            signals: signals,
            demotions: demotions,
            protection: BuiltInProtectedPaths.protection(
                forPath: entry.path,
                underToolRoot: entry.path,
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
    /// ## 只比对扫描器真正判定的那些段
    ///
    /// 比对范围是：**工具根自身的名字**，加上它**相对所属扫描根**的那几段。
    /// 扫描根**本身不是被判定的对象**——它是起点。
    ///
    /// 早先的实现把整条路径逐段拆开全比一遍，于是 `$HOME` **以上**的段也进了比对范围：
    /// 一个叫 `…-backup/Users/x` 的主目录会把该主目录下**每一个**候选都降权成疑似，
    /// 界面还写「命中负向名单 *backup*」——而那条路径本身没有任何问题。
    /// 名字判定只能落在扫描器看过的那层，否则等于让用户目录名替工具背锅。
    ///
    /// `scanRootPath` 为 `nil`（补漏来的路径不落在任何扫描根之下）时只比对最后一段：
    /// 宁可漏判降权，也不误判——降权会挡住用户看见真正的高置信度候选。
    private func negativePattern(matching path: String, scanRootPath: String?) -> String? {
        let components = judgedComponents(of: path, scanRootPath: scanRootPath)
        guard !components.isEmpty else { return nil }

        return hints.negativeNamePatterns.first { pattern in
            components.contains { GlobPattern.matches(pattern: pattern, text: $0) }
        }
    }

    /// 名字判定真正看的那几段：相对扫描根的路径（末段一定在内）。
    private func judgedComponents(of path: String, scanRootPath: String?) -> [String] {
        let all = path.split(separator: "/").map(String.init)

        var relative: ArraySlice<String>
        if let scanRootPath {
            let root = scanRootPath.split(separator: "/").map(String.init)
            relative = all.count >= root.count ? all.dropFirst(root.count)[...] : all[...]
        } else {
            relative = all.suffix(1)[...]
        }

        guard let last = relative.last else { return [] }
        return Array(relative.dropLast()) + [last]
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

    // MARK: - 扫描根列举

    private enum ScanRootOutcome {
        case success([ShallowDirectoryReader.Entry])
        case failure(UnreadableDirectory)
    }

    /// 读一个扫描根的一级子目录，按入口筛选口径过滤。
    ///
    /// 扫描根不存在只是「这里没有可看的东西」（User Story 22），不算读不到；
    /// 读得到但列不出来（权限不足等）才是需要说明的情况。
    private func shallowEntries(
        of scanRoot: ScanRoot,
        reader: ShallowDirectoryReader
    ) -> ScanRootOutcome {
        guard reader.isDirectory(scanRoot.path) else { return .success([]) }

        do {
            let entries = try reader.entries(in: scanRoot.path)
            let filtered = entries.filter { entry in
                switch scanRoot.entryFilter {
                case .allEntries:
                    return true
                case .hiddenDirectoriesOnly:
                    return entry.name.hasPrefix(".")
                }
            }
            return .success(filtered)
        } catch {
            return .failure(UnreadableDirectory(path: scanRoot.path, reason: reason(of: error)))
        }
    }

    /// 系统错误的中文说明。
    private func reason(of error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return nsError.localizedDescription }
        switch nsError.code {
        case NSFileReadNoPermissionError: return "权限不足"
        case NSFileReadNoSuchFileError: return "路径已不存在"
        default: return nsError.localizedDescription
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
