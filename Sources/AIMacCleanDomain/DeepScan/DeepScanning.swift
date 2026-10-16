import Foundation

import AIMacCleanCore
import AIMacCleanRules

/// 深扫器（issue #23、PRD §4.1 第 4 步）。
///
/// 给定**已确认的工具**（工具根 + 已准入规则），递归算出占用并按 PRD §5.1 的四类归好。
///
/// ## 本类型的硬纪律
///
/// 1. **零写入**：接口上只有读取。文件系统那一层（`DiscoveryFileSystem`）根本没有写入口，
///    因此「不创建 / 不修改 / 不删除」不是靠自觉，而是没有可写的东西。
/// 2. **只读元数据**：只 `stat` 取大小与类型，不读文件内容——`.zst` / `.zstd`
///    只认扩展名（对深扫而言扩展名甚至不影响统计：分类来自规则声明，不来自解码）。
/// 3. **不跟随符号链接**：目录与文件都不进链接目标；链接一律记进 `unfollowedLinks`，
///    既不把目标的占用算进来，也不去目标里遍历（PRD §8.2 的同一条纪律）。
/// 4. **权限错误按目录粒度隔离**：读不到的目录进 `unreadable`，其余照常统计，
///    绝不让一次扫描因为一个目录而整体失败（PRD §4.4）。
///
/// ## 分类只认规则声明
///
/// 分类映射来自规则文件的 `classification[{pattern, category}]`。规则没有声明到的路径
/// 落进**不确定**，绝不默认算作可归档（`CategoryProvenance.undeclared`）。
/// 受保护判定另外复用 `BuiltInProtectedPaths`（按链接真实目标），规则只展示、不改判。
public protocol DeepScanning {
    func scan(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String
    ) throws -> DeepScanReport
}

/// 深扫器的默认实现。
public struct DeepScanner: DeepScanning, @unchecked Sendable {

    private let fileSystem: any DiscoveryFileSystem
    private let protectedPathListing: any ProtectedPathDirectoryListing

    /// - Parameters:
    ///   - fileSystem: 可注入的文件系统读取层（`DiscoveryFileSystem`）。默认真实文件系统；
    ///     测试套记录器后可以断言「碰了哪些路径」「有没有写尝试」。
    ///   - protectedPathListing: 受保护判定做通配展开时的目录列举（issue #19）。
    ///     默认真实文件系统；测试可注入记录器。
    public init(
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem(),
        protectedPathListing: any ProtectedPathDirectoryListing = RealProtectedPathDirectoryListing()
    ) {
        self.fileSystem = fileSystem
        self.protectedPathListing = protectedPathListing
    }

    /// 扫描一组已确认工具。
    ///
    /// - Parameters:
    ///   - tools: 已确认的工具。没在这里的工具不会被扫到——深扫入口就是「已确认工具」。
    ///   - rules: 已过 `RuleSetAdmission` 的规则集。没有对应规则的工具照常返回一份
    ///     零占用的报告，不会被静默丢掉（用户确认过的工具必须出现在结果里）。
    ///   - homeDirectory: 受保护判定用的主目录。显式传入，本层不读 `NSHomeDirectory()`。
    ///   - options: 并发度等扫描选项。
    public func scan(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String,
        options: DeepScanOptions = DeepScanOptions()
    ) throws -> DeepScanReport {
        let results = scanTools(tools, rules: rules, homeDirectory: homeDirectory, options: options)
        // 固定按工具标识排序：并行下完成顺序不确定，而结果必须确定（验收 7）。
        return DeepScanReport(toolReports: results.sorted { $0.toolID < $1.toolID })
    }

    public func scan(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String
    ) throws -> DeepScanReport {
        try scan(tools: tools, rules: rules, homeDirectory: homeDirectory, options: DeepScanOptions())
    }

    // MARK: - 并发

    private func scanTools(
        _ tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String,
        options: DeepScanOptions
    ) -> [ToolScanReport] {
        guard !tools.isEmpty else { return [] }

        let rulesByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let parallelism = min(options.maxConcurrentTools, tools.count)
        guard parallelism > 1 else {
            return tools.map { scanTool($0, rule: rulesByID[$0.id], homeDirectory: homeDirectory) }
        }

        // 并行扫多台工具（验收 7）。单台工具内部仍是顺序递归：目录互相独立，但它们共享
        // 同一条「工具 → 类别 → 子路径」汇总，并行化汇总的收益远小于竞争带来的复杂度
        // （本机实测的瓶颈是单台工具里的数万文件，而不是台数）。
        let lock = NSLock()
        var results: [ToolScanReport] = []
        results.reserveCapacity(tools.count)

        let queue = DispatchQueue(label: "ai-mac-clean.deep-scan", qos: .userInitiated, attributes: .concurrent)
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: parallelism)
        for tool in tools {
            semaphore.wait()
            group.enter()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                let report = self.scanTool(tool, rule: rulesByID[tool.id], homeDirectory: homeDirectory)
                lock.lock()
                results.append(report)
                lock.unlock()
            }
        }
        group.wait()

        return results
    }

    // MARK: - 单台工具

    private func scanTool(_ tool: ConfirmedTool, rule: ToolRule?, homeDirectory: String) -> ToolScanReport {
        var walk = DirectoryWalk(
            tool: tool,
            rule: rule,
            fileSystem: fileSystem,
            protectedPathListing: protectedPathListing,
            homeDirectory: homeDirectory
        )
        walk.run()
        return walk.report
    }
}

// MARK: - 递归

/// 单台工具的递归遍历。一次性用完即弃。
private struct DirectoryWalk {

    /// 一个「工具 → 类别 → 子路径」桶。
    private struct Bucket {
        let anchor: String
        let pattern: String?
        let provenance: CategoryProvenance
        var bytes: Int64 = 0
        var fileCount: Int = 0
    }

    let tool: ConfirmedTool
    let fileSystem: any DiscoveryFileSystem
    let homeDirectory: String
    let protectedPathListing: any ProtectedPathDirectoryListing
    let resolver: CategoryResolver
    let toolRoot: String

    private var buckets: [DataCategory: [String: Bucket]] = [:]

    private var unreadable: [UnreadableEntry] = []
    private var unfollowedLinks: [UnfollowedLink] = []

    init(
        tool: ConfirmedTool,
        rule: ToolRule?,
        fileSystem: any DiscoveryFileSystem,
        protectedPathListing: any ProtectedPathDirectoryListing,
        homeDirectory: String
    ) {
        self.tool = tool
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
        self.protectedPathListing = protectedPathListing
        self.toolRoot = PathText.normalize(tool.toolRootPath)
        self.resolver = CategoryResolver(entries: rule?.classification ?? [])
    }

    mutating func run() {
        // 工具根本身是符号链接时不进入：跟随它等于把链接目标算成这台工具的占用
        // （PRD §4.2 对浅扫的同一条纪律，深扫沿用）。依然报告这台工具，只是零占用。
        if fileType(of: toolRoot) == .typeSymbolicLink {
            recordUnfollowedLink(path: toolRoot, relativePath: "", destination: linkDestination(toolRoot))
            return
        }
        walk(
            directory: toolRoot,
            relativePath: "",
            category: .uncertain,
            pattern: nil,
            provenance: .undeclared,
            anchor: "",
            anchorIsFixed: false
        )
    }

    // MARK: 递归主体

    /// 递归一层目录。
    ///
    /// - Parameters:
    ///   - anchor: 当前**子路径锚点**：最近一条声明覆盖的那个位置（`projects`、`.tmp`），
    ///     或未声明子树在工具根下的顶层子项。汇总按它归并。
    ///   - anchorIsFixed: 锚点是否已经「钉死」。一旦路径落在某条声明之下，它下面的任何
    ///     未声明目录都挂在同一个锚点上——`projects/<路径>/sub/` 里的东西属于 `projects`，
    ///     而不是属于 `projects/<路径>/sub`（后者只会把汇总碎成一堆没意义的路径）。
    private mutating func walk(
        directory: String,
        relativePath: String,
        category: DataCategory,
        pattern: String?,
        provenance: CategoryProvenance,
        anchor: String,
        anchorIsFixed: Bool
    ) {
        let entries: [String]
        do {
            entries = try fileSystem.entryNames(inDirectory: directory)
        } catch {
            // 权限错误按目录粒度隔离：这一棵子树读不到，其余照常（PRD §4.4）。
            unreadable.append(UnreadableEntry(
                path: directory,
                relativePath: relativePath,
                toolID: tool.id,
                kind: .directory,
                reason: error.localizedDescription
            ))
            return
        }

        for name in entries.sorted() {
            let path = PathText.appending(name, to: directory)
            let childRelative = relativePath.isEmpty ? name : relativePath + "/" + name

            guard let attributes = fileSystem.attributes(ofItemAt: path) else {
                // 「读不到」与「是空的」必须分得开：前者记进清单，后者本来就什么都不贡献。
                unreadable.append(UnreadableEntry(
                    path: path,
                    relativePath: childRelative,
                    toolID: tool.id,
                    kind: .item,
                    reason: nil
                ))
                continue
            }

            guard let type = attributes[.type] as? FileAttributeType else {
                // 连类型都读不出来时**不猜**：列进读不到清单，不按文件计字节。
                unreadable.append(UnreadableEntry(
                    path: path,
                    relativePath: childRelative,
                    toolID: tool.id,
                    kind: .item,
                    reason: "文件类型不可知"
                ))
                continue
            }

            switch type {
            case .typeSymbolicLink:
                // 不跟随：既不把目标的占用算进来，也不进目标遍历。
                recordUnfollowedLink(path: path, relativePath: childRelative, destination: linkDestination(path))

            case .typeDirectory:
                let resolved = resolver.resolve(
                    relativePath: childRelative,
                    inherited: category,
                    anchor: anchor,
                    anchorIsFixed: anchorIsFixed
                )
                walk(
                    directory: path,
                    relativePath: childRelative,
                    category: resolved.category,
                    pattern: resolved.pattern,
                    provenance: resolved.provenance,
                    anchor: resolved.anchor,
                    anchorIsFixed: resolved.anchorIsFixed
                )

            default:
                // 普通文件（以及门、套接字这类非目录条目，按文件计）。只取大小，不读内容。
                //
                // 文件**自己**也要过一遍分类判定：一条声明可能就落在某个文件上
                // （`config.toml`），也可能只落在它所在的目录上（`config.toml` 是目录下的文件时
                // 靠父目录的类别继承）。只继承父目录会漏掉前者——而这恰恰是受保护条目最常见的形态。
                let resolved = resolver.resolve(
                    relativePath: childRelative,
                    inherited: category,
                    anchor: anchor,
                    anchorIsFixed: anchorIsFixed
                )
                let size = byteSize(of: attributes)
                if size == nil {
                    unreadable.append(UnreadableEntry(
                        path: path,
                        relativePath: childRelative,
                        toolID: tool.id,
                        kind: .item,
                        reason: "读不到文件大小"
                    ))
                }
                // 锚点为空只可能出现在工具根这一层（根目录本身不是一条声明）：
                // 直接放在工具根下的文件按它自己的名字成一条，不进任何目录的汇总。
                accumulate(
                    category: resolved.category,
                    anchor: resolved.anchor.isEmpty ? childRelative : resolved.anchor,
                    pattern: resolved.pattern ?? pattern,
                    provenance: resolved.provenance,
                    bytes: size ?? 0
                )
            }
        }
    }

    // MARK: 汇总

    private mutating func accumulate(
        category: DataCategory,
        anchor: String,
        pattern: String?,
        provenance: CategoryProvenance,
        bytes: Int64
    ) {
        var byAnchor = buckets[category] ?? [:]
        var bucket = byAnchor[anchor] ?? Bucket(anchor: anchor, pattern: pattern, provenance: provenance)
        bucket.bytes += bytes
        bucket.fileCount += 1
        byAnchor[anchor] = bucket
        buckets[category] = byAnchor
    }

    private mutating func recordUnfollowedLink(path: String, relativePath: String, destination: String?) {
        let resolved: String?
        if let destination {
            resolved = destination.hasPrefix("/")
                ? PathText.normalize(destination)
                : PathText.normalize(PathText.parent(of: path) + "/" + destination)
        } else {
            resolved = nil
        }
        unfollowedLinks.append(UnfollowedLink(
            path: path,
            relativePath: relativePath,
            toolID: tool.id,
            destination: destination,
            isInsideToolRoot: resolved.map { PathText.isInside($0, root: toolRoot) } ?? false
        ))
    }

    // MARK: 读取助手

    private func fileType(of path: String) -> FileAttributeType? {
        fileSystem.attributes(ofItemAt: path)?[.type] as? FileAttributeType
    }

    private func linkDestination(_ path: String) -> String? {
        fileSystem.symbolicLinkDestination(atPath: path)
    }

    private func byteSize(of attributes: [FileAttributeKey: Any]) -> Int64? {
        guard let size = attributes[.size] else { return nil }
        if let number = size as? NSNumber { return number.int64Value }
        if let value = size as? Int64 { return value }
        if let value = size as? Int { return Int64(value) }
        return nil
    }

    // MARK: 出报告

    var report: ToolScanReport {
        let categories = DataCategory.displayOrder.compactMap { category -> CategoryOccupancy? in
            guard let byAnchor = buckets[category], !byAnchor.isEmpty else { return nil }
            let summaries = byAnchor.values
                .map { bucket -> CategorySummary in
                    CategorySummary(
                        subpath: bucket.anchor,
                        pattern: bucket.pattern,
                        provenance: bucket.provenance,
                        occupancy: Occupancy(bytes: bucket.bytes, fileCount: bucket.fileCount)
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.occupancy != rhs.occupancy { return rhs.occupancy < lhs.occupancy }
                    return lhs.subpath < rhs.subpath
                }
            return CategoryOccupancy(
                category: category,
                occupancy: Occupancy.sum(summaries.map(\.occupancy)),
                holdingDirectoryCount: summaries.count,
                summaries: summaries
            )
        }

        return ToolScanReport(
            toolID: tool.id,
            displayName: tool.displayName,
            toolRootPath: tool.toolRootPath,
            occupancy: Occupancy.sum(categories.map(\.occupancy)),
            categories: categories,
            holdingDirectoryCount: categories.reduce(0) { $0 + $1.holdingDirectoryCount },
            unreadable: unreadable,
            unfollowedLinks: unfollowedLinks
        )
    }
}

// MARK: - 分类判定

/// 一条分类条目在匹配时的排序键。
private struct RankedEntry {
    let order: Int
    let specificity: Int
    let wildcardCount: Int
    let pattern: String
    let category: DataCategory
    let pathPattern: PathPattern
    /// 模式是否以 `**` 结尾：声明的是「这一层之下」，而不是这一层本身。
    let isRecursiveWildcard: Bool
}

/// 路径 → 类别（issue #23：分类**只认规则声明的映射**）。
///
/// ## 判定顺序
///
/// 1. 路径**本身**被某条声明命中 → 用这条声明的类别，锚点就是它自己；
/// 2. 否则沿父目录逐级向上，取**最近一条**把它盖住的声明（`projects/**` 覆盖
///    `projects/<编码路径>/<uuid>.jsonl` 这样的深层文件），锚点取那条声明命中过的**最高**一层；
/// 3. 路径在一条声明的**下面**却没被这条声明覆盖（`.tmp/cache/stale.dat` 之于 `.tmp/**`）：
///    锚点保持声明那一层，类别继承父目录已经定下的类别；
/// 4. 整条路径从工具根起就没被任何声明盖住：**不确定**，锚点是它在工具根下的顶层子项。
///
/// 换句话说「未声明 → 不确定」不是某一步的特例，而是整棵未声明子树的默认值：
/// 类别只可能从某条声明**继承**下来，永远不可能凭空变成可归档。
///
/// 同一层级上多条声明命中时，**更具体的一条赢**（段数多者优先、通配少者优先），
/// 相同则按规则文件里的声明顺序取第一条。声明顺序本身有意义（规则作者把特例写在前面），
/// 但「具体优先」能让 `settings*.json` 不被 `**` 之类的泛化声明吃掉。
private struct CategoryResolver {

    private let entries: [RankedEntry]

    init(entries: [ClassificationEntry]) {
        self.entries = entries.enumerated().map { order, entry in
            RankedEntry(
                order: order,
                specificity: entry.pattern.segments.count,
                wildcardCount: entry.pattern.segments.reduce(0) { total, segment in
                    total + segment.tokens.filter { $0 == .wildcard }.count
                },
                pattern: entry.pattern.canonicalString,
                category: entry.category,
                pathPattern: entry.pattern,
                isRecursiveWildcard: entry.pattern.segments.last?.tokens == [.literal("**")]
            )
        }
        .sorted { lhs, rhs in
            if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
            if lhs.wildcardCount != rhs.wildcardCount { return lhs.wildcardCount < rhs.wildcardCount }
            return lhs.order < rhs.order
        }
    }

    /// 判定一条相对路径的类别。
    func resolve(
        relativePath: String,
        inherited: DataCategory,
        anchor: String,
        anchorIsFixed: Bool
    ) -> Resolution {
        // 沿「自己 → 父目录 → 更上层」逐级比对，第一层命中的就是锚点。
        //
        //    为什么从最高层往下找：`X/**` 这类声明永远匹配不上 `X` 自己（`**` 至少吃一段），
        //    而它声明的正是「`X` 这一层之下的东西」。`X` 因此要按声明模式的**基**来认
        //    （`matchesAsDeclaredParent`），否则 `.tmp/stale.dat` 会一路落到「未声明」。
        //    取最高的那一层当锚点，才不会把汇总碎成一堆项目目录名；命中的是哪条声明并不因此
        //    改变（同一层里更具体的先被取到）。
        var prefixes = PathText.components(of: relativePath)
        var matched: (ancestor: String, entry: RankedEntry)?
        while !prefixes.isEmpty, matched == nil {
            let prefix = prefixes.joined(separator: "/")
            if let entry = firstMatch(prefix) { !$0.isRecursiveWildcard } ?? firstDeclaredParentMatch(prefix) {
                matched = (prefix, entry)
            }
            prefixes.removeLast()
        }

        if let matched {
            // 命中的就是路径自己 → 这条路径被直接声明；否则只是被一条声明覆盖着。
            let isSelf = matched.ancestor == relativePath
            return Resolution(
                category: matched.entry.category,
                anchor: matched.ancestor,
                pattern: matched.entry.pattern,
                provenance: isSelf
                    ? .declaredPath(matched.entry.pattern)
                    : .declaredAncestor(matched.entry.pattern),
                anchorIsFixed: true
            )
        }

        // 没有任何声明盖住它：类别只能继承父目录已经定下的那一类。
        //    锚点已经钉死时保持不动；否则归到工具根下的顶层子项，别把汇总碎成一堆深层路径。
        let resolvedAnchor = anchorIsFixed
            ? anchor
            : (PathText.components(of: relativePath).first ?? relativePath)

        return Resolution(
            category: inherited,
            anchor: resolvedAnchor,
            pattern: nil,
            provenance: .undeclared,
            anchorIsFixed: anchorIsFixed
        )
    }

    /// 按优先级取第一条被 `relativePath` 覆盖的声明。
    private func firstMatch(
        _ relativePath: String,
        where predicate: (RankedEntry) -> Bool
    ) -> RankedEntry? {
        guard !relativePath.isEmpty else { return nil }
        return entries.first { $0.pathPattern.matches(relativePath: relativePath) && predicate($0) }
    }

    /// 某条以 `**` 结尾的声明，其**基**是否正好是这个路径。
    ///
    /// `projects/**` 认 `projects`、`archived_sessions/**` 认 `archived_sessions`。
    /// 反过来 `projects/<编码路径>/**` 认的是 `projects/<编码路径>`，不会认 `projects`——
    /// 于是锚点仍然停在声明写的那一层，不需要知道具体编码路径长什么样。
    private func firstDeclaredParentMatch(_ relativePath: String) -> RankedEntry? {
        guard !relativePath.isEmpty else { return nil }
        return entries.first { entry in
            guard entry.isRecursiveWildcard else { return false }
            let components = entry.pathPattern.segments
            guard components.count > 1 else { return false }
            let base = PathPattern(segments: Array(components.dropLast()))
            return base.matches(relativePath: relativePath)
        }
    }

    struct Resolution {
        let category: DataCategory
        let anchor: String
        let pattern: String?
        let provenance: CategoryProvenance
        /// 从这条路径起锚点已经钉死（它落在某条声明之下，或它本身就是一层未声明子树的顶）。
        let anchorIsFixed: Bool
    }
}

// MARK: - 路径文本

/// 相对路径与绝对路径的纯文本运算。
///
/// 刻意不碰磁盘：深扫的路径运算必须能跟着注入的文件系统一起被断言，
/// 因此这里只做字符串切分与拼接（与 `ProtectedPathMath` 的分工一致）。
enum PathText {

    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(piece))
            }
        }
        guard isAbsolute || !stack.isEmpty else { return "" }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func appending(_ component: String, to path: String) -> String {
        path.hasSuffix("/") ? path + component : path + "/" + component
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        var components = self.components(of: normalized)
        guard components.count > 1 else { return normalized.hasPrefix("/") ? "/" : "" }
        components.removeLast()
        return "/" + components.joined(separator: "/")
    }

    /// `path` 是否落在 `root` 之内（含等于 root）。
    static func isInside(_ path: String, root: String) -> Bool {
        let normalizedPath = normalize(path)
        let normalizedRoot = normalize(root)
        if normalizedPath == normalizedRoot { return true }
        return normalizedPath.hasPrefix(normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/")
    }
}
