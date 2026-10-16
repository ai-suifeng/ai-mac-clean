import Foundation

/// 一次扫描期间的**受保护判定快照**（issue #29 的性能切片）。
///
/// ## 为什么要有它
///
/// 深扫要对每个文件做一次内置受保护判定（`auth*`、`*.sqlite*`、`skills*`、链接真实目标…）。
/// 逐次走 `BuiltInProtectedPaths.protection(forPath:underToolRoot:homeDirectory:listing:)`
/// 时，每次判定都会**重新**解析工具根与主目录的符号链接、**重新**展开受保护目录——
/// 本机实测（issue #29 评论）单次判定约 2.1 ms，其中约 1.6 ms 花在这两件与「这条路径是否
/// 受保护」无关的事上；5 万文件因此要 132 秒。
///
/// 这两件事在一次扫描期间**不会变**：工具根、主目录、以及内置目录条目在磁盘上展开出来的
/// 位置，都是同一个扫描上下文里的常量。快照把它们算一次，之后每条路径只做纯文本比较。
///
/// ## 它不是缓存，也不改变结论
///
/// - **判定逻辑只有一处实现**：`BuiltInProtectedPaths.protection(...)` 现在就是
///   「建一个快照 + 按原语义解析这条路径」的薄封装，两者不可能有第二套答案。
/// - 快照的作用域是**一次扫描**：调用方（深扫的每台工具各一份）用完即弃，
///   因此仍然保留「宁可每次重算，也不留过期缓存」的纪律——只是把「每次」从
///   「每个文件」提到「每次扫描」。同一棵树在扫描期间被外部改动时，两者的差异
///   与深扫本身遍历期间的快照性质一致（深扫本来就按目录逐层读取）。
///
/// ## 用法
///
/// - 逐文件路径已经能递推真实路径时（深扫沿目录下行，父目录的真实路径已知），
///   用 `protection(forPath:resolvedPath:)`，给 `realToolRoot` 作起点即可，零额外磁盘读取。
/// - 少量需要自己解析的路径（符号链接目标）用 `protection(forPath:)`。
public struct ProtectedPathContext {

    /// 工具根的**真实路径**（已解析符号链接）。深扫从它开始按目录递推每条路径的真实形态。
    public let realToolRoot: String

    private let normalizedRoot: String
    private let normalizedHome: String
    private let scope: BuiltInProtectedScope
    private let realRoot: String
    private let realHome: String

    /// 按作用域预先分好的内置条目；同一作用域内保持清单原有顺序（先命中先返回）。
    private let rulesByScope: [BuiltInProtectedScope: [BuiltInProtectedRule]]

    /// 内置目录条目在磁盘上展开出的受保护目录（已解析符号链接），保持原判定顺序。
    private let protectedDirectories: [ExpandedProtectedDirectory]

    private struct ExpandedProtectedDirectory {
        let rule: BuiltInProtectedRule
        let realPath: String
    }

    /// 建立快照：只在这里读磁盘（解析符号链接 + 展开受保护目录）。
    ///
    /// - Parameters:
    ///   - toolRoot: 工具根绝对路径。
    ///   - homeDirectory: 主目录绝对路径（显式传入，本层不读 `NSHomeDirectory()`）。
    ///   - listing: 目录条目展开用的列举层（issue #19）；注入记录器即可断言「列举了哪些目录」。
    public init(
        toolRoot: String,
        homeDirectory: String,
        listing: any ProtectedPathDirectoryListing = RealProtectedPathDirectoryListing()
    ) {
        let normalizedRoot = ProtectedPathMath.normalize(toolRoot)
        let normalizedHome = ProtectedPathMath.normalize(homeDirectory)
        let realRoot = ProtectedPathMath.resolvingSymlinks(normalizedRoot)
        let realHome = ProtectedPathMath.resolvingSymlinks(normalizedHome)

        var rulesByScope: [BuiltInProtectedScope: [BuiltInProtectedRule]] = [:]
        for rule in BuiltInProtectedPaths.rules {
            rulesByScope[rule.scope, default: []].append(rule)
        }

        // 受保护目录的展开（原 `protectedDirectoryRule`）：展开根只有已知工具根，
        // 主目录作用域的目录条目由第 3 步的直接模式匹配负责，不参与展开（issue #19）。
        var roots: [BuiltInProtectedScope: String] = [:]
        for (identifier, relativeRoot) in BuiltInProtectedPaths.rootRelativePaths {
            roots[.toolRoot(identifier)] = ProtectedPathMath.normalize(normalizedHome + "/" + relativeRoot)
        }
        var expanded: [ExpandedProtectedDirectory] = []
        for rule in BuiltInProtectedPaths.rules where rule.kind == .directory {
            guard let root = roots[rule.scope] else { continue }
            for directory in Self.existingDirectories(matching: rule.pattern, in: root, listing: listing) {
                expanded.append(ExpandedProtectedDirectory(
                    rule: rule,
                    realPath: ProtectedPathMath.resolvingSymlinks(directory)
                ))
            }
        }

        self.normalizedRoot = normalizedRoot
        self.normalizedHome = normalizedHome
        self.scope = BuiltInProtectedPaths.scope(ofToolRoot: normalizedRoot)
        self.realRoot = realRoot
        self.realHome = realHome
        self.realToolRoot = realRoot
        self.rulesByScope = rulesByScope
        self.protectedDirectories = expanded
    }

    // MARK: - 判定

    /// 自己解析符号链接的判定入口（符号链接目标这类少量路径用）。
    ///
    /// 解析结果与 `resolvedPath(forPath:)` 完全一致，因此与显式给路径的那条入口同结论。
    public func protection(forPath path: String) -> ProtectedMatch? {
        protection(forPath: path, resolvedPath: resolvedPath(forPath: path))
    }

    /// 判定一条路径；`resolvedPath` 是调用方已经解析好符号链接的绝对路径。
    ///
    /// 六步与 `BuiltInProtectedPaths.protection(...)` 的历史语义逐步相同，顺序不得调整：
    /// 链接位置 → 真实目标相对工具根 → 真实目标相对主目录 → 凭证文件名 →
    /// 未识别位置黑名单 → 真实目标落在受保护目录之下。
    public func protection(forPath path: String, resolvedPath: String) -> ProtectedMatch? {
        let normalizedPath = ProtectedPathMath.normalize(path)
        let realPath = ProtectedPathMath.normalize(resolvedPath)

        // 1. 链接位置下的「工具根 + 相对路径」。
        if let relative = nonEmptyRelativePath(of: normalizedPath, under: normalizedRoot),
           let match = matchRules(scope: scope, relativePath: relative, source: .toolRootRelativePath) {
            return match
        }

        // 2. 解析符号链接后的「工具根 + 相对路径」。
        if let relative = nonEmptyRelativePath(of: realPath, under: realRoot),
           let match = matchRules(scope: scope, relativePath: relative, source: .resolvedRelativePath) {
            return match
        }

        // 3. 主目录下的跨工具条目（`~/.claude.json` 等位于工具根之外）。
        if let relative = nonEmptyRelativePath(of: realPath, under: realHome),
           let match = matchRules(scope: .homeDirectory, relativePath: relative, source: .homeRelativePath) {
            return match
        }

        // 4. 纯凭证文件名：与工具无关，任何位置都保护。
        if let match = matchFileNameRules(scope: .credentialFileName, normalizedPath: normalizedPath, realPath: realPath) {
            return match
        }

        // 5. 未识别位置的文件名黑名单（PRD §5.5：未知工具默认仅展示）。
        if scope == .unknownLocation,
           let match = matchFileNameRules(scope: .unknownLocation, normalizedPath: normalizedPath, realPath: realPath) {
            return match
        }

        // 6. 链接的真实目标落在某个内置受保护目录之下。
        for entry in protectedDirectories
        where realPath == entry.realPath || realPath.hasPrefix(entry.realPath + "/") {
            return ProtectedMatch(
                ruleIdentifier: entry.rule.identifier,
                scope: entry.rule.scope,
                matchedRelativePath: realPath,
                matchedVia: .symlinkRealTarget
            )
        }

        return nil
    }

    /// 解析一条路径的符号链接，得到判定要用的真实路径形态。
    public func resolvedPath(forPath path: String) -> String {
        ProtectedPathMath.resolvingSymlinks(ProtectedPathMath.normalize(path))
    }

    // MARK: - 匹配（与历史实现逐行等价，只是条目按作用域预分好了）

    private func nonEmptyRelativePath(of path: String, under root: String) -> String? {
        guard let relative = ProtectedPathMath.relativePath(of: path, under: root),
              !relative.isEmpty
        else { return nil }
        return relative
    }

    private func matchFileNameRules(
        scope: BuiltInProtectedScope,
        normalizedPath: String,
        realPath: String
    ) -> ProtectedMatch? {
        var names = [ProtectedPathMath.components(of: realPath).last ?? normalizedPath]
        if let linkName = ProtectedPathMath.components(of: normalizedPath).last, linkName != names[0] {
            names.append(linkName)
        }

        for name in names {
            if let match = matchRules(scope: scope, relativePath: name, source: .fileNameBlacklist) {
                return match
            }
        }
        return nil
    }

    private func matchRules(
        scope: BuiltInProtectedScope,
        relativePath: String,
        source: ProtectedMatchSource
    ) -> ProtectedMatch? {
        let components = ProtectedPathMath.components(of: relativePath)
        guard !components.isEmpty else { return nil }

        for rule in rulesByScope[scope] ?? [] {
            let matched: Bool
            switch rule.kind {
            case .file:
                guard let name = components.last else { continue }
                matched = ProtectedPathMath.matches(pattern: rule.pattern, component: name)
            case .directory:
                matched = Self.leadingPrefix(of: components, matches: rule.pattern)
            }

            guard matched else { continue }
            return ProtectedMatch(
                ruleIdentifier: rule.identifier,
                scope: rule.scope,
                matchedRelativePath: relativePath,
                matchedVia: source
            )
        }
        return nil
    }

    private static func leadingPrefix(of components: [String], matches pattern: String) -> Bool {
        for length in 1...components.count {
            let prefix = components.prefix(length).joined(separator: "/")
            if ProtectedPathMath.matches(pattern: pattern, path: prefix) {
                return true
            }
        }
        return false
    }

    /// 列出 `root` 下匹配模式的实际目录（含通配符与多段前缀展开）。
    ///
    /// **展开绝不越过 `root`**：中途遇到符号链接就停下，既不解析它，也不去它指向的位置
    /// 列举。`root` 一定是规则声明的工具根，因此这条展开碰不到规则之外的任何位置。
    private static func existingDirectories(
        matching pattern: String,
        in root: String,
        listing: any ProtectedPathDirectoryListing
    ) -> [String] {
        var current = [root]

        for component in ProtectedPathMath.components(of: pattern) {
            var next: [String] = []
            for directory in current {
                guard !ProtectedPathMath.isSymbolicLink(directory),
                      let entries = listing.entryNames(inDirectory: directory)
                else { continue }
                for entry in entries where ProtectedPathMath.matches(pattern: component, component: entry) {
                    next.append(directory == "/" ? "/\(entry)" : directory + "/" + entry)
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }
}
