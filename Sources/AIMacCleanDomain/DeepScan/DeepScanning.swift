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
/// 3. **不跟随符号链接**：链接一律记进 `unfollowedLinks`，目标不计入占用、不被遍历
///    （PRD §8.2 的同一条纪律）。唯一的例外方向是「更保守」：目标被内置清单判为受保护时
///    把它计进**受保护**（`~/.codex/skills → ~/.agents/skills`），目标是工具根之外
///    又不受保护时一个字节都不读。
/// 4. **权限错误按目录粒度隔离**：读不到的目录进 `unreadable`，其余照常统计，
///    绝不让一次扫描因为一个目录而整体失败（PRD §4.4）。
///
/// ## 分类只认规则声明
///
/// 分类映射来自规则文件的 `classification[{pattern, category}]`。规则没有声明到的路径
/// 落进**不确定**，绝不默认算作可归档（`CategoryProvenance.undeclared`）。
/// 受保护判定另外复用 `BuiltInProtectedPaths`（按链接真实目标），规则只展示、不改判。
/// 同一路径命中多条规则声明时报**判定顺序**最高的那一类
/// （受保护 > 不确定 > 缓存与日志 > 可归档会话，issue #25 验收 6）。
///
/// 接口刻意**不抛错**：扫描本身不会因为某个位置读不到而失败——那些位置按目录粒度
/// 进 `unreadable`（PRD §4.4）。一个会抛错的签名会诱使调用方把「读不到」升级成
/// 「整次扫描失败」，而这正是本票要避免的。
public protocol DeepScanning {
    func scan(
        tools: [ConfirmedTool],
        rules: RuleAdmissionReport,
        homeDirectory: String
    ) -> DeepScanReport

    /// 便利入口：直接给一组**已准入**的规则。
    func scan(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String
    ) -> DeepScanReport
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
        rules: RuleAdmissionReport,
        homeDirectory: String,
        options: DeepScanOptions = DeepScanOptions()
    ) -> DeepScanReport {
        let catalog = DeepScanRuleCatalog(report: rules)
        let results = scanTools(tools, catalog: catalog, homeDirectory: homeDirectory, options: options)
        // 固定按工具标识排序：并行下完成顺序不确定，而结果必须确定（验收 7）。
        return DeepScanReport(toolReports: results.sorted { $0.toolID < $1.toolID })
    }

    public func scan(
        tools: [ConfirmedTool],
        rules: RuleAdmissionReport,
        homeDirectory: String
    ) -> DeepScanReport {
        scan(tools: tools, rules: rules, homeDirectory: homeDirectory, options: DeepScanOptions())
    }

    public func scan(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String,
        options: DeepScanOptions = DeepScanOptions()
    ) -> DeepScanReport {
        scan(
            tools: tools,
            rules: RuleAdmissionReport(usableRules: rules, rejections: []),
            homeDirectory: homeDirectory,
            options: options
        )
    }

    public func scan(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String
    ) -> DeepScanReport {
        scan(tools: tools, rules: rules, homeDirectory: homeDirectory, options: DeepScanOptions())
    }

    // MARK: - 并发

    private func scanTools(
        _ tools: [ConfirmedTool],
        catalog: DeepScanRuleCatalog,
        homeDirectory: String,
        options: DeepScanOptions
    ) -> [ToolScanReport] {
        guard !tools.isEmpty else { return [] }

        let parallelism = min(options.maxConcurrentTools, tools.count)
        guard parallelism > 1 else {
            return tools.map { scanTool($0, catalog: catalog, homeDirectory: homeDirectory) }
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
                let report = self.scanTool(tool, catalog: catalog, homeDirectory: homeDirectory)
                lock.lock()
                results.append(report)
                lock.unlock()
            }
        }
        group.wait()

        return results
    }

    // MARK: - 单台工具

    private func scanTool(
        _ tool: ConfirmedTool,
        catalog: DeepScanRuleCatalog,
        homeDirectory: String
    ) -> ToolScanReport {
        var walk = DirectoryWalk(
            tool: tool,
            catalog: catalog,
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

    /// 一个「工具 → 类别 → 子路径」桶的身份。
    ///
    /// 受保护理由进键：同一个目录下的文件可能一部分受保护、一部分不受
    /// （`~/.codex` 本身就是「受保护的顶层」这类内置条目会盖住整棵子树，而普通目录不会）。
    /// 合成一条会把两类数混在一起，界面就说不清哪部分碰不得。
    private struct BucketKey: Hashable {
        let anchor: String
        let protectionReason: String?
    }

    /// 一个桶的累加值。
    private struct Bucket {
        let anchor: String
        let protectionReason: String?
        let pattern: String?
        let provenance: CategoryProvenance
        var bytes: Int64 = 0
        var fileCount: Int = 0
    }

    let tool: ConfirmedTool
    let catalog: DeepScanRuleCatalog
    let fileSystem: any DiscoveryFileSystem
    let homeDirectory: String
    let protectedPathListing: any ProtectedPathDirectoryListing
    let toolRoot: String

    /// 受保护判定的**扫描期快照**（issue #29）。
    ///
    /// 逐文件调用 `BuiltInProtectedPaths.protection(...)` 时，每次判定都要重新解析工具根与
    /// 主目录的符号链接、重新展开受保护目录——本机实测 5 万文件因此要 132 秒。这些信息在
    /// 一次扫描期间不变，建一份快照（每台工具一份，随遍历用完即弃）后逐路径判定只剩文本比较。
    /// 判定结论与本文件此前逐次调用的行为逐字段相同（见 `ProtectedPathContextTests`）。
    let protection: ProtectedPathContext

    /// 这台工具的真实根（已解析符号链接）：遍历时按目录递推每条路径的真实形态，
    /// 于是逐文件判定不必再自己解析整条路径。
    private var realToolRoot: String { protection.realToolRoot }

    private var buckets: [DataCategory: [BucketKey: Bucket]] = [:]

    private var unreadable: [UnreadableEntry] = []
    private var unfollowedLinks: [UnfollowedLink] = []

    init(
        tool: ConfirmedTool,
        catalog: DeepScanRuleCatalog,
        fileSystem: any DiscoveryFileSystem,
        protectedPathListing: any ProtectedPathDirectoryListing,
        homeDirectory: String
    ) {
        self.tool = tool
        self.catalog = catalog
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
        self.protectedPathListing = protectedPathListing
        self.toolRoot = PathText.normalize(tool.toolRootPath)
        self.protection = ProtectedPathContext(
            toolRoot: self.toolRoot,
            homeDirectory: homeDirectory,
            listing: protectedPathListing
        )
    }

    mutating func run() {
        // 工具根本身是符号链接时不进入：跟随它等于把链接目标算成这台工具的占用
        // （PRD §4.2 对浅扫的同一条纪律，深扫沿用）。依然报告这台工具，只是零占用。
        if fileType(of: toolRoot) == .typeSymbolicLink {
            recordUnfollowedLink(path: toolRoot, relativePath: "", destination: linkDestination(toolRoot))
            return
        }
        walk(directory: toolRoot, relativePath: "", protectedReason: nil, realDirectory: realToolRoot)
    }

    // MARK: 递归主体

    /// 递归一层目录。
    ///
    /// 类别与子路径锚点都按**每条路径自己**判定（issue #25 的判定顺序 + 模式声明的层级），
    /// 因此这里不传递类别：一条未声明的路径不可能从父目录「继承」出一个可归档，
    /// 它只会被判成不确定。唯一往下传的是 `protectedReason`——受保护是一次判定，
    /// 命中之后整棵子树都是受保护的（父目录已经判过，不必每个文件重判）。
    ///
    /// - Parameter realDirectory: 本目录的**真实路径**（已解析符号链接）。子项的
    ///   `真实路径 = realDirectory + "/" + 子项名`：本目录是我们逐层走下来的真目录，
    ///   子项若是普通文件/目录，这个递推与 `ProtectedPathMath.resolvingSymlinks` 逐段解析
    ///   的结果一致，因此逐文件判定不必再解析整条路径（issue #29 的性能切片）。
    private mutating func walk(
        directory: String,
        relativePath: String,
        protectedReason: String?,
        realDirectory: String
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
            let realPath = PathText.appending(name, to: realDirectory)

            guard let metadata = fileSystem.metadata(ofItemAt: path) else {
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

            guard let type = metadata.type else {
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
                // 不跟随（issue #23 硬约束）：默认既不把目标的占用算进来，也不进目标遍历。
                //
                // 只有一个例外，而且方向是「更保守」：链接的真实目标被内置清单判为**受保护**
                // 时，链接指向的就是用户碰不得的东西（`~/.codex/skills → ~/.agents/skills`）。
                // 这时把它按受保护统计进来，界面上才能如实说「这里有一份受保护的技能，别动它」；
                // 目标仍不会被归档、不会被移除。
                //
                // 目标落在工具根**之外**且不受保护时一律跳过：跟随它等于把扫描带出工具根
                // （PRD §8.2「指向外部目录的链接一律拒绝处理」）。
                // 链接目标只读一次：同一件事读两遍在 5 万文件里就是多一次系统调用
                // （issue #29；对结果没有任何影响）。
                let rawDestination = linkDestination(path)
                let destination = resolvedLinkDestination(path: path, destination: rawDestination)
                recordUnfollowedLink(path: path, relativePath: childRelative, destination: rawDestination)

                // 只有「目标在内置清单里受保护」的链接才继续统计，这是安全边界：
                // 指向工具根之外、又不受保护的目录的链接（用户自己的媒体库、别人的仓库）
                // 一律拒绝处理（PRD §8.2）——一个字节都不读、不跟随。
                //
                // 链接目标是少量路径，这里仍让它自己解析符号链接（`protection(forPath:)`）：
                // 目标可能整条路径都带链接，不值得为它再维护一套递推。
                let protectedTarget = destination.flatMap {
                    protection.protection(forPath: $0)?.ruleIdentifier
                }

                if let destination, let reason = protectedTarget {
                    walk(
                        directory: destination,
                        relativePath: childRelative,
                        protectedReason: reason,
                        realDirectory: protection.resolvedPath(forPath: destination)
                    )
                }

            case .typeDirectory:
                // 目录这一层只认「能形容目录本身」的内置条目；文件级条目留给文件自己判。
                let reason = protectedReason ?? directoryProtectionReason(
                    forPath: path,
                    relativePath: childRelative,
                    resolvedPath: realPath
                )
                walk(directory: path, relativePath: childRelative, protectedReason: reason, realDirectory: realPath)

            default:
                // 普通文件（以及门、套接字这类非目录条目，按文件计）。只取大小，不读内容。
                //
                // 类别按**这条路径自己**判：命中多条时报判定顺序最高的那一类（issue #25），
                // 一条都没命中就落进不确定。受保护有两个来源，任一命中即受保护：
                // 已经在受保护目录里、或自己命中内置条目（含真实目标落在受保护目录之下）。
                //
                // `type` 来自条目**自身**的属性（lstat），因此这一支不可能是符号链接；
                // 指向受保护目标的链接在上一支处理。这里也就无需再读一次链接目标
                // （issue #29：那曾是每个文件一次多余的 `readlink`）。
                let fileProtection = protectedReason
                    ?? protectionReason(forPath: path, relativePath: childRelative, resolvedPath: realPath)
                let resolution = catalog.resolution(
                    forRelativePath: childRelative,
                    toolID: tool.id,
                    isBuiltInProtected: fileProtection != nil
                )
                let size = metadata.size
                if size == nil {
                    unreadable.append(UnreadableEntry(
                        path: path,
                        relativePath: childRelative,
                        toolID: tool.id,
                        kind: .item,
                        reason: "读不到文件大小"
                    ))
                }
                accumulate(
                    resolution: resolution,
                    relativePath: childRelative,
                    protectionReason: fileProtection,
                    bytes: size ?? 0
                )
            }
        }
    }

    // MARK: 汇总

    /// 把一个文件记进某个「类别 / 子路径」桶。
    ///
    /// - Parameters:
    ///   - resolution: 规则层的判定结果；`nil` 表示这台工具没有对应规则，
    ///     一律按「未声明 → 不确定」处理。
    ///   - protectionReason: 非 `nil` 表示受保护。它压过规则声明的任何类别
    ///     （PRD §8.1：内置清单是下界，规则不能把它改判）。
    private mutating func accumulate(
        resolution: DeepScanRuleCatalog.RuleMatchResolution?,
        relativePath: String,
        protectionReason: String?,
        bytes: Int64
    ) {
        let category: DataCategory = protectionReason == nil
            ? (resolution?.category ?? .uncertain)
            : .protected
        let anchor = resolution?.anchor ?? relativePath
        let key = BucketKey(anchor: anchor, protectionReason: protectionReason)

        var byKey = buckets[category] ?? [:]
        var bucket = byKey[key] ?? Bucket(
            anchor: anchor,
            protectionReason: protectionReason,
            pattern: protectionReason == nil ? resolution?.pattern : nil,
            provenance: protectionReason == nil ? (resolution?.provenance ?? .undeclared) : .undeclared
        )
        bucket.bytes += bytes
        bucket.fileCount += 1
        byKey[key] = bucket
        buckets[category] = byKey
    }

    /// 相对路径 → 内置受保护条目名（未命中为 `nil`）。**只看这条路径本身。**
    ///
    /// 复用 M1 的 `BuiltInProtectedPaths`，**按链接真实目标**判定（PRD §8.2 / §14.5）。
    /// 它只展开规则声明的工具根，不列举主目录（issue #19）。
    ///
    /// `resolvedPath` 由调用方按目录递推给出（issue #29）；这里只再确认一次路径确实落在
    /// 工具根内，判定本身交给扫描期快照。
    func protectionReason(forPath path: String, relativePath: String, resolvedPath: String) -> String? {
        guard !relativePath.isEmpty,
              isInsideToolRoot(path)
        else { return nil }
        return protection.protection(forPath: path, resolvedPath: resolvedPath)?.ruleIdentifier
    }

    /// 这条路径确实落在工具根内。
    ///
    /// 与 `PathText.isInside(path, root: toolRoot)` 等价，但不必把同一个工具根逐字符重新
    /// 标准化（issue #29：逐文件判定里那是一次纯浪费的字符串拆分）。
    /// `path` 是本类型按「工具根 + 逐层目录名」拼出来的：目录名里不可能有 `/`，
    /// `contentsOfDirectory` 也不返回 `.` 与 `..`，因此「已标准化」是构造出来的事实。
    private func isInsideToolRoot(_ path: String) -> Bool {
        path.hasPrefix(toolRoot + "/")
    }

    /// **目录**这一层是否直接命中受保护条目。
    ///
    /// 必须与文件级的 `protectionReason(forPath:...)` 区分开：后者连「目录里有个 `auth.json`」
    /// 都会命中（文件级条目按最后一段比较，对任何相对路径都成立），于是整棵子树会被
    /// 判成受保护——那是错的。目录这一层只认能形容目录本身的条目：目录型条目
    /// （`skills*`、`.agents/skills*`）与真正的目录路径。
    func directoryProtectionReason(forPath path: String, relativePath: String, resolvedPath: String) -> String? {
        guard !relativePath.isEmpty else { return nil }
        guard let reason = protectionReason(forPath: path, relativePath: relativePath, resolvedPath: resolvedPath)
        else { return nil }
        let last = PathText.components(of: relativePath).last ?? relativePath
        let isDirectoryRule = BuiltInProtectedPaths.rules.contains { rule in
            rule.kind == .directory && PathText.matches(pattern: rule.pattern, component: last)
        }
        return isDirectoryRule ? reason : nil
    }

    private mutating func recordUnfollowedLink(path: String, relativePath: String, destination: String?) {
        let resolved = resolvedLinkDestination(path: path, destination: destination)
        unfollowedLinks.append(UnfollowedLink(
            path: path,
            relativePath: relativePath,
            toolID: tool.id,
            destination: destination,
            isInsideToolRoot: resolved.map { PathText.isInside($0, root: toolRoot) } ?? false
        ))
    }

    /// 把链接目标解成绝对路径（相对目标按链接所在目录解释）。读不到目标时为 `nil`。
    private func resolvedLinkDestination(path: String, destination: String?) -> String? {
        guard let destination else { return nil }
        if destination.hasPrefix("/") { return PathText.normalize(destination) }
        return PathText.normalize(PathText.appending(destination, to: PathText.parent(of: path)))
    }

    // MARK: 读取助手

    private func fileType(of path: String) -> FileAttributeType? {
        fileSystem.attributes(ofItemAt: path)?[.type] as? FileAttributeType
    }

    private func linkDestination(_ path: String) -> String? {
        fileSystem.symbolicLinkDestination(atPath: path)
    }

    // MARK: 出报告

    var report: ToolScanReport {
        let categories = DataCategory.displayOrder.compactMap { category -> CategoryOccupancy? in
            guard let byKey = buckets[category], !byKey.isEmpty else { return nil }
            let summaries = byKey.values
                .map { bucket -> CategorySummary in
                    CategorySummary(
                        subpath: bucket.anchor,
                        pattern: bucket.pattern,
                        protectionReason: bucket.protectionReason,
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

// MARK: - 规则目录

/// 深扫要用的「规则目录」：把已准入的规则集包成按工具标识取类别的东西。
///
/// 类别判定**不在本层实现**：它由规则层的 `RuleSetAdmission` +
/// `ClassificationResolution`（issue #25）负责。深扫只做两件事——把该判的路径送去判、
/// 把判出来的结论归到子路径上。这样「同一路径命中多条时报哪一类」只有一处实现，
/// 深扫不会和界面给出两套答案。
struct DeepScanRuleCatalog {

    /// 一条分类条目的**预编译形态**（issue #29）。
    ///
    /// 分类条目在一次扫描期间不变，而判定要对每个文件跑一遍：字面前缀与
    /// 段数（判定顺序相同时的第二判据）都是模式的常量属性，没有理由每个文件重算一次。
    private struct CompiledEntry {
        let pattern: PathPattern
        let canonicalPattern: String
        let category: DataCategory
        let literalBase: String
        let segmentCount: Int
    }

    private let report: RuleAdmissionReport
    private let entriesByToolID: [String: [CompiledEntry]]

    init(report: RuleAdmissionReport) {
        self.report = report
        var entriesByToolID: [String: [CompiledEntry]] = [:]
        for rule in report.usableRules where entriesByToolID[rule.id] == nil {
            entriesByToolID[rule.id] = rule.classification.map { entry in
                CompiledEntry(
                    pattern: entry.pattern,
                    canonicalPattern: entry.pattern.canonicalString,
                    category: entry.category,
                    literalBase: Self.literalBase(of: entry.pattern),
                    segmentCount: entry.pattern.segments.count
                )
            }
        }
        self.entriesByToolID = entriesByToolID
    }

    /// 某条相对路径的规则声明命中情况。
    func resolution(
        forRelativePath relativePath: String,
        toolID: String,
        isBuiltInProtected: Bool
    ) -> RuleMatchResolution? {
        guard let entries = entriesByToolID[toolID] else { return nil }

        // 按判定顺序归属（受保护 > 不确定 > 缓存与日志 > 可归档会话），
        // 未命中任何条目则按「不确定」（issue #25、PRD §5.1）。
        let category = report.category(
            forRelativePath: relativePath,
            ruleID: toolID,
            isBuiltInProtected: isBuiltInProtected
        )
        guard let category else { return nil }

        // 类别定了，子路径锚点还要定：同一类别的多个文件要能汇总到一处，
        // 界面才看得清「这一类的占用集中在哪」。
        if let declared = declaredBase(forRelativePath: relativePath, entries: entries) {
            return RuleMatchResolution(
                category: category,
                anchor: declared.path,
                pattern: declared.pattern,
                provenance: declared.path == relativePath
                    ? .declaredPath(declared.pattern)
                    : .declaredAncestor(declared.pattern)
            )
        }

        // 没有任何声明覆盖它（类别因此来自「未命中 → 不确定」这一档）：
        // 锚点取它在工具根下的顶层子项，别把汇总碎成一堆深层路径。
        let components = PathText.components(of: relativePath)
        return RuleMatchResolution(
            category: category,
            anchor: components.first ?? relativePath,
            pattern: nil,
            provenance: .undeclared
        )
    }

    /// 判出一条路径是被哪条模式声明的（只看这条路径**自己**，不看上级）。
    private struct DeclaredBase {
        let path: String
        let pattern: String
    }

    /// 路径自己是否被某条模式声明；是的话给出「声明的那一层」。
    private func declaredBase(forRelativePath relativePath: String, entries: [CompiledEntry]) -> DeclaredBase? {
        guard !relativePath.isEmpty, let entry = firstMatchingEntry(relativePath, entries: entries) else { return nil }

        // 锚点取模式的**字面部分**，而不是匹配到的路径本身：
        // `projects/<编码路径>/<uuid>.jsonl` 声明的是「每个项目下的每份转录」，
        // 字面部分是 `projects`，因此这一类汇总到 `projects` 一条；
        // 而 `projects/**` 的字面部分同样是 `projects`。两者因此归到一起，
        // 不会把汇总碎成几百个项目目录名。
        let base = entry.literalBase
        return DeclaredBase(path: base.isEmpty ? relativePath : base, pattern: entry.canonicalPattern)
    }

    /// 按判定顺序取第一条覆盖该路径的分类条目（单趟扫描，不先建一个中间数组）。
    private func firstMatchingEntry(_ relativePath: String, entries: [CompiledEntry]) -> CompiledEntry? {
        var best: CompiledEntry?
        var bestRank = Int.max
        for entry in entries where entry.pattern.matches(relativePath: relativePath) {
            let rank = Self.precedenceRank(entry.category)
            guard let current = best else {
                best = entry
                bestRank = rank
                continue
            }
            if rank < bestRank || (rank == bestRank && entry.segmentCount > current.segmentCount) {
                best = entry
                bestRank = rank
            }
        }
        return best
    }

    /// 模式的**字面前缀**：第一个带通配或占位符的段之前的所有段。
    ///
    /// `projects/**` → `projects`；`projects/<编码路径>/<uuid>.jsonl` → `projects`；
    /// `config.toml` → `config.toml`。尾部的 `**` 也算通配（它意味着「这一层之下」），
    /// 因此不会把 `**` 当成目录名写进子路径。
    private static func literalBase(of pattern: PathPattern) -> String {
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

    private static func precedenceRank(_ category: DataCategory) -> Int {
        ClassificationResolution.precedence.firstIndex(of: category) ?? ClassificationResolution.precedence.count
    }

    /// 一次「路径 → 类别 + 子路径锚点」的判定结果。
    struct RuleMatchResolution {
        let category: DataCategory
        let anchor: String
        let pattern: String?
        let provenance: CategoryProvenance
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

    /// 单段通配符匹配（`*` 匹配任意字符，忽略大小写），与 `PathPattern` 的单段语义一致。
    ///
    /// 深扫只需要这一种形态：内置受保护条目的 `pattern` 就是单段通配符
    /// （`skills*`、`.credentials*`、`*.sqlite*`），而 `PathPattern` 的完整语义
    /// 由规则层负责，本层不重复实现它。
    static func matches(pattern: String, component: String) -> Bool {
        let patternCharacters = Array(pattern.lowercased())
        let characters = Array(component.lowercased())
        var patternIndex = 0
        var componentIndex = 0
        var lastStarIndex = -1
        var resumeIndex = 0

        while componentIndex < characters.count {
            if patternIndex < patternCharacters.count,
               patternCharacters[patternIndex] == characters[componentIndex] {
                patternIndex += 1
                componentIndex += 1
            } else if patternIndex < patternCharacters.count,
                      patternCharacters[patternIndex] == "*" {
                lastStarIndex = patternIndex
                resumeIndex = componentIndex
                patternIndex += 1
            } else if lastStarIndex >= 0 {
                patternIndex = lastStarIndex + 1
                resumeIndex += 1
                componentIndex = resumeIndex
            } else {
                return false
            }
        }

        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }

    /// `path` 是否落在 `root` 之内（含等于 root）。
    static func isInside(_ path: String, root: String) -> Bool {
        let normalizedPath = normalize(path)
        let normalizedRoot = normalize(root)
        if normalizedPath == normalizedRoot { return true }
        return normalizedPath.hasPrefix(normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/")
    }
}
