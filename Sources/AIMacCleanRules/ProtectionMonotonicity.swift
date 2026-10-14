import Foundation

/// 内置受保护条目在一条规则的具体上下文里展开成的「受保护区域」。
///
/// 区域不是抽象概念：它就是「在这个工具根下，哪些相对路径受保护」，
/// 于是准入可以问一句可判定的问题——**用户声明的这个路径模式，是不是整片都落在区域内**。
struct ProtectedRegion {

    enum Shape {
        /// 受保护目录：模式匹配相对路径的前缀，命中即覆盖整棵子树。
        case leadingDirectory([SegmentLanguage])
        /// 受保护文件名：与相对路径的**最后一段**比较（任意深度都可命中）。
        case fileName([SegmentLanguage])
        /// 工具根本身就落在某个受保护目录之下（符号链接落到共享技能目录）。
        case entireToolRoot
    }

    /// 命中的内置条目标识，如 `codex-cli/auth`。
    let ruleIdentifier: String
    /// 给用户看的作用域说明。
    let scopeDescription: String
    /// 比对前先拼在用户模式前面的前缀段（工具根相对主目录的部分）。
    let prefix: [SegmentLanguage]
    let shape: Shape

    init(ruleIdentifier: String, scopeDescription: String, prefix: [SegmentLanguage], shape: Shape) {
        self.ruleIdentifier = ruleIdentifier
        self.scopeDescription = scopeDescription
        self.prefix = prefix
        self.shape = shape
    }

    /// 用户声明的路径模式是否整片落在这个受保护区域内。
    ///
    /// 判定的是「**全部**匹配路径都受保护」，而不是「碰到了某一个」。
    /// `auth.json` 整片落在 `auth*` 里 → 是改判；`logs/**` 只是可能顺带包含一个
    /// `auth.json` → 不是改判，那属于规则写得粗糙，真正的兜底在代码层的内置保护
    /// （PRD §8.3：命中受保护规则的路径即使被规则选中，也直接拒绝归档与移除）。
    func contains(_ pattern: PathPattern) -> Bool {
        let declared = prefix + pattern.segments.map(SegmentLanguage.init(segment:))

        switch shape {
        case .entireToolRoot:
            return true

        case let .leadingDirectory(region):
            return ProtectedRegion.isLeadingPrefixContained(region, in: declared)

        case let .fileName(region):
            guard let last = declared.last else { return false }
            if region.count > 1 {
                // 内置清单里文件名条目都是单段；万一出现多段，按前缀比对（更保守）。
                return ProtectedRegion.isLeadingPrefixContained(region, in: declared)
            }
            return SegmentRelation.isContained(last, in: region[0])
        }
    }

    /// `region` 的每一段都把 `declared` 的对应前缀段整个包住。
    private static func isLeadingPrefixContained(_ region: [SegmentLanguage], in declared: [SegmentLanguage]) -> Bool {
        guard region.count <= declared.count else { return false }
        return zip(declared, region).allSatisfy { SegmentRelation.isContained($0, in: $1) }
    }
}

/// 把内置受保护清单（issue #9）按工具根展开成一组受保护区域。
enum ProtectedRegionFactory {

    /// 某个工具根下的全部受保护区域。
    ///
    /// 作用域的取法与 `BuiltInProtectedPaths.protection` 一致：工具根作用域按最后一段
    /// 目录名识别，主目录条目按「工具根相对主目录的前缀」比对，凭证文件名在任何位置都算，
    /// 未识别位置的文件名黑名单只在工具根本身未被识别时生效。
    static func regions(forToolRoot rootPath: String, homeDirectory: String) -> [ProtectedRegion] {
        let normalizedRoot = ProtectedPathMath.normalize(rootPath)
        let normalizedHome = ProtectedPathMath.normalize(homeDirectory)
        let scope = BuiltInProtectedPaths.scope(ofToolRoot: normalizedRoot)
        let homeRelative = ProtectedPathMath.relativePath(of: normalizedRoot, under: normalizedHome)
        let prefix = homeRelative.map { literalSegments($0) } ?? []

        var regions: [ProtectedRegion] = []

        for rule in BuiltInProtectedPaths.rules {
            guard let pattern = try? PathPattern(rule.pattern) else { continue }
            let languages = pattern.segments.map(SegmentLanguage.init(segment:))

            let applies: Bool
            let description: String
            switch rule.scope {
            case let .toolRoot(identifier):
                applies = scope == .toolRoot(identifier)
                description = "\(identifier) 工具根下的 \(rule.pattern)"
            case .homeDirectory:
                applies = homeRelative != nil
                description = "主目录下的 \(rule.pattern)"
            case .credentialFileName:
                applies = true
                description = "任何位置的凭证文件名 \(rule.pattern)"
            case .unknownLocation:
                applies = scope == .unknownLocation
                description = "未识别位置的文件名黑名单 \(rule.pattern)"
            }
            guard applies else { continue }

            regions.append(
                ProtectedRegion(
                    ruleIdentifier: rule.identifier,
                    scopeDescription: description,
                    // 主目录条目要按「工具根相对主目录」的前缀比对，其余条目从工具根起步。
                    prefix: rule.scope == .homeDirectory ? prefix : [],
                    shape: rule.kind == .directory ? .leadingDirectory(languages) : .fileName(languages)
                )
            )
        }

        if let region = toolRootRegion(forToolRoot: normalizedRoot, homeDirectory: normalizedHome) {
            regions.append(region)
        }

        return regions
    }

    /// 工具根的**真实目标**本身落在某个内置受保护目录之下时，整棵工具根都是受保护的。
    ///
    /// 实测形态：`~/.codex/skills` 与 `~/.opencode/skills` 是指向 `~/.agents/skills`
    /// 的符号链接（PRD §14.5、issue #5）。以它为工具根的规则写什么都落在受保护区域内。
    private static func toolRootRegion(forToolRoot root: String, homeDirectory: String) -> ProtectedRegion? {
        let realRoot = ProtectedPathMath.resolvingSymlinks(root)
        guard realRoot != root,
              let match = BuiltInProtectedPaths.protection(
                forPath: realRoot,
                underToolRoot: homeDirectory,
                homeDirectory: homeDirectory
              ),
              let builtin = BuiltInProtectedPaths.rules.first(where: { $0.identifier == match.ruleIdentifier }),
              builtin.kind == .directory
        else { return nil }

        return ProtectedRegion(
            ruleIdentifier: builtin.identifier,
            scopeDescription: "工具根真实目标 \(realRoot)",
            prefix: [],
            shape: .entireToolRoot
        )
    }

    private static func literalSegments(_ relativePath: String) -> [SegmentLanguage] {
        ProtectedPathMath.components(of: relativePath).map { component in
            let runs = component.lowercased().map { SegmentLanguage.Run.literal($0) }
            return SegmentLanguage(runs: runs)
        }
    }
}

/// 保护单调性判定（issue #11 不变式 1；PRD §8.1、验收 A16）。
enum ProtectionMonotonicity {

    /// 一处与内置受保护区域冲突的分类声明。
    struct Finding {
        /// 冲突的性质。
        enum Kind {
            /// 把受保护路径放进了**可归档类别**——保护单调性违规，整条规则被拒绝。
            case demotion
            /// 类别同样「只展示、不动」，不构成降级，但标签与内置保护不一致，给出提示。
            case mislabelling
        }

        let kind: Kind
        /// 规则里出问题的字段，如 `classification[3].category`。
        let field: String
        let entry: ClassificationEntry
        let region: ProtectedRegion
    }

    /// 规则里全部与内置受保护区域冲突的分类声明。
    ///
    /// ## 什么算降级
    ///
    /// PRD §5.1 的「处理」列写得很清楚：**只有「可归档会话」这一类被授予归档与移除的许可**，
    /// 缓存与日志、不确定、受保护都只是「只展示占用，不动」。因此保护单调性的可判定
    /// 含义是——**内置受保护路径不能落进被授予归档与移除许可的类别**：
    ///
    /// - 判为 `archivableSession`（可归档会话） → 违规，**拒绝整条规则**（验收 A16、User Story 29）；
    /// - 判为 `cacheAndLog` / `uncertain` → 仍然不动它，但标签与内置保护不一致，
    ///   给出可读提示，让界面能如实说明「它其实仍受保护」，而不是让用户误以为规则生效。
    ///
    /// 这里说的始终是**类别层面的许可**，而且许可覆盖的是归档与移除**两步**：
    /// 移除原文件以自校验归档包的校验通过为前提（GLOSSARY「移除」、ADR-0002），
    /// 因此本判定既不把两步合成一步，也不把「可归档」读成「可移除」。
    ///
    /// 遍历顺序：先按规则里的声明顺序，再按内置清单顺序，因此报出来的总是**第一条**
    /// 出问题的声明，且指向具体的内置条目。
    static func findings(in rule: ToolRule, homeDirectory: String) -> [Finding] {
        guard !rule.classification.isEmpty else { return [] }

        let regions = toolRootRegions(of: rule, homeDirectory: homeDirectory)
        var found: [Finding] = []

        for (index, entry) in rule.classification.enumerated() {
            // 受保护是最高档：声明「受保护」只会抬高保护，不构成降级。
            guard entry.category != .protected else { continue }

            for region in regions where region.contains(entry.pattern) {
                found.append(
                    Finding(
                        kind: entry.category == .archivableSession ? .demotion : .mislabelling,
                        field: "classification[\(index)].category",
                        entry: entry,
                        region: region
                    )
                )
                break
            }
        }
        return found
    }

    /// 「不确定」形态的区域化表示（与受保护区域同构，只是判定对象不同）。
    static func uncertainRegions(forToolRoot rootPath: String) -> [ProtectedRegion] {
        let normalizedRoot = ProtectedPathMath.normalize(rootPath)
        return UncertainShapes.shapes.map { shape in
            ProtectedRegion(
                ruleIdentifier: shape.identifier,
                scopeDescription: "不确定形态 \(shape.pattern.canonicalString)",
                prefix: [],
                shape: .fileName(shape.pattern.segments.map(SegmentLanguage.init(segment:)))
            )
        }
    }

    /// 规则里第一处「把不确定降级为可归档」的声明；没有则返回 `nil`。
    static func uncertainDowngrade(in rule: ToolRule, homeDirectory: String) -> Finding? {
        guard !rule.classification.isEmpty else { return nil }

        let regions = rule.roots
            .filter { $0.role == .toolRoot }
            .flatMap { uncertainRegions(forToolRoot: absolutePath($0.path, homeDirectory: homeDirectory)) }

        for (index, entry) in rule.classification.enumerated()
        where entry.category == .archivableSession {
            for region in regions where region.contains(entry.pattern) {
                return Finding(kind: .mislabelling,
                               field: "classification[\(index)].category",
                               entry: entry,
                               region: region)
            }
        }
        return nil
    }

    /// 规则里第一处削弱内置保护的声明；没有则返回 `nil`。
    static func downgrade(in rule: ToolRule, homeDirectory: String) -> Finding? {
        findings(in: rule, homeDirectory: homeDirectory).first { $0.kind == .demotion }
    }

    /// 规则声明的每个工具根各自展开出的受保护区域。
    ///
    /// 声明了多个工具根时，任何一个根下降级都算降级——保守方向。
    /// `displayOnly` 根只用于展示占用，不参与分类声明的比对。
    private static func toolRootRegions(of rule: ToolRule, homeDirectory: String) -> [ProtectedRegion] {
        rule.roots
            .filter { $0.role == .toolRoot }
            .flatMap { ProtectedRegionFactory.regions(forToolRoot: absolutePath($0.path, homeDirectory: homeDirectory),
                                                     homeDirectory: homeDirectory) }
    }

    /// `~/` 展开成调用方给的主目录。
    ///
    /// 展开只做字符串拼接、**不检查路径是否存在**：规则声明的路径在磁盘上缺失不是拒绝理由
    /// （spec #7 User Story 22）。
    static func absolutePath(_ path: String, homeDirectory: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let tail = path == "~" ? "" : String(path.dropFirst(2))
        let home = ProtectedPathMath.normalize(homeDirectory)
        return tail.isEmpty ? home : home + "/" + tail
    }
}
