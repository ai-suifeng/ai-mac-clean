import Foundation

import AIMacCleanCore
import AIMacCleanRules

/// 深扫器（issue #23、PRD §4.1 第 4 步）。
///
/// 给定**已确认的工具**（工具根 + 已准入规则），递归算出占用并按 PRD §5.1 的四类归好。
///
/// ## 一个工具的所有规则声明根都要进占用（issue #31）
///
/// 规则文件里一个工具可以声明多个根：主工具根（`~/.cursor`，归档范围）与**仅展示根**
/// （`~/Library/Application Support/Cursor`，实测 14G 的 Electron 内部存储）。
/// 深扫把**规则声明的每个根**都扫进占用，并在 `ToolScanReport.roots` 里按根分列，
/// 概览页因此能显示「Cursor 2.1G + 14G 只展示」（PRD §14.1）。
/// 仅展示根内的路径**一律不可归档**（`accumulate`），缺失的仅展示根静默跳过
/// （PRD §5.4「规则容忍缺失」）。
///
/// ## 本类型的硬纪律
///
/// 1. **零写入**：接口上只有读取。文件系统那一层（`DiscoveryFileSystem`）根本没有写入口，
///    因此「不创建 / 不修改 / 不删除」不是靠自觉，而是没有可写的东西。
/// 2. **只读元数据**：只 `stat` 取大小与类型，不读文件内容——`.zst` / `.zstd`
///    只认扩展名（对深扫而言扩展名甚至不影响统计：分类来自规则声明，不来自解码）。
/// 3. **不跟随符号链接**：链接一律记进 `unfollowedLinks`，目标不计入占用、不被遍历
///    （PRD §8.2 的同一条纪律）。唯一的例外方向是「更保守」：目标被内置清单判为受保护时
///    把它计进**受保护**（`~/.codex/skills → ~/.agents/skills`），目标是规则声明的根之外
///    又不受保护时一个字节都不读。
/// 4. **权限错误按目录粒度隔离**：读不到的目录进 `unreadable`，其余照常统计，
///    绝不让一次扫描因为一个目录而整体失败（PRD §4.4）。
/// 5. **访问只在规则声明的根内**：扫描的起点只有「已确认的主工具根」与「规则声明的
///    仅展示根」，不枚举任何通用位置（issue #18/#19）。
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
    ///     每个工具要扫的根是「主工具根 + 它规则里声明的仅展示根」（issue #31）。
    ///   - rules: 已过 `RuleSetAdmission` 的规则集。没有对应规则的工具照常返回一份
    ///     零占用的报告，不会被静默丢掉（用户确认过的工具必须出现在结果里）。
    ///   - homeDirectory: 受保护判定与 `~/…` 展开用的主目录。显式传入，本层不读 `NSHomeDirectory()`。
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
        var merged: [DataCategory: [BucketKey: Bucket]] = [:]
        var unreadable: [UnreadableEntry] = []
        var unfollowedLinks: [UnfollowedLink] = []
        var roots: [ToolRootOccupancy] = []

        // 一个工具的占用由**它所有的规则声明根**贡献，不只主根（issue #31）。
        // 每个根各走一遍自己的子树，再合并到同一份「类别 / 子路径」汇总里。
        for root in scanRoots(for: tool, catalog: catalog, homeDirectory: homeDirectory) {
            var walk = DirectoryWalk(
                tool: tool,
                root: root,
                catalog: catalog,
                fileSystem: fileSystem,
                protectedPathListing: protectedPathListing,
                homeDirectory: homeDirectory
            )
            walk.run()
            roots.append(ToolRootOccupancy(path: root.path, role: root.role, occupancy: walk.occupancy))
            mergeBuckets(walk.buckets, into: &merged)
            unreadable += walk.unreadable
            unfollowedLinks += walk.unfollowedLinks
        }

        return makeReport(
            tool: tool,
            buckets: merged,
            roots: roots,
            unreadable: unreadable,
            unfollowedLinks: unfollowedLinks
        )
    }

    /// 这次要扫哪些根：已确认的**主工具根** + 规则为这个工具声明的**仅展示根**（issue #31）。
    ///
    /// 仅展示根从**规则**里取，而不是要求调用方逐个传进来：规则声明了却忘记扫，
    /// 正是 #23 留下的缺口（Cursor AppSupport 14G 完全没进占用）。从规则里取，
    /// 这个缺口就不可能再出现。`~/…` 在这里展开到 `homeDirectory`
    /// （`ToolRoot.absolutePath(homeDirectory:)`，只拼字符串、不检查存在）。
    ///
    /// 去重：展开后与主根相同、或彼此相同的根只扫一次——同一棵树被两个根声明时
    /// 算两遍就是虚报占用。
    private func scanRoots(
        for tool: ConfirmedTool,
        catalog: DeepScanRuleCatalog,
        homeDirectory: String
    ) -> [ScanRoot] {
        let primary = ScanRoot(path: PathText.normalize(tool.toolRootPath), role: .toolRoot)
        var seen: Set<String> = [primary.path]
        var roots: [ScanRoot] = [primary]

        for declared in catalog.rule(id: tool.id)?.roots ?? [] where declared.role == .displayOnly {
            let path = PathText.normalize(declared.absolutePath(homeDirectory: homeDirectory))
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            roots.append(ScanRoot(path: path, role: .displayOnly))
        }
        return roots
    }

    /// 把各根的桶合并进整台工具的桶：同一个「子路径 + 保护理由」跨根并成一条汇总。
    ///
    /// 汇总按子路径合并（而不是按根各留一条）：`CategorySummary.subpath` 相对**所属根**，
    /// 两个根下同名的 `Cache` 在工具这一层本来就是同一类数据。要区分根，
    /// `ToolScanReport.roots` 已经分别给出了每个根的占用。
    private func mergeBuckets(
        _ source: [DataCategory: [BucketKey: Bucket]],
        into target: inout [DataCategory: [BucketKey: Bucket]]
    ) {
        for (category, byKey) in source {
            for (key, bucket) in byKey {
                guard var existing = target[category]?[key] else {
                    target[category, default: [:]][key] = bucket
                    continue
                }
                existing.bytes += bucket.bytes
                existing.fileCount += bucket.fileCount
                target[category, default: [:]][key] = existing
            }
        }
    }
}

// MARK: - 一根 / 一次遍历

/// 一个**已展开**的根：主工具根，或规则声明里只展示、不绝动的根（issue #31）。
private struct ScanRoot: Equatable {
    let path: String
    let role: ToolRootRole
}

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

/// 把各根合并后的桶摊成一份工具级报告。
///
/// `roots` 原样带出来：概览页要能分别说「主根 2.1G」「仅展示 14G」（PRD §14.1）。
private func makeReport(
    tool: ConfirmedTool,
    buckets: [DataCategory: [BucketKey: Bucket]],
    roots: [ToolRootOccupancy],
    unreadable: [UnreadableEntry],
    unfollowedLinks: [UnfollowedLink]
) -> ToolScanReport {
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
        roots: roots,
        holdingDirectoryCount: categories.reduce(0) { $0 + $1.holdingDirectoryCount },
        unreadable: unreadable,
        unfollowedLinks: unfollowedLinks
    )
}

/// 一个根下面的递归遍历。一次性用完即弃。
private struct DirectoryWalk {

    let tool: ConfirmedTool
    let root: ScanRoot
    let catalog: DeepScanRuleCatalog
    let fileSystem: any DiscoveryFileSystem
    let homeDirectory: String
    let protectedPathListing: any ProtectedPathDirectoryListing
    let rootPath: String

    var buckets: [DataCategory: [BucketKey: Bucket]] = [:]

    var unreadable: [UnreadableEntry] = []
    var unfollowedLinks: [UnfollowedLink] = []

    init(
        tool: ConfirmedTool,
        root: ScanRoot,
        catalog: DeepScanRuleCatalog,
        fileSystem: any DiscoveryFileSystem,
        protectedPathListing: any ProtectedPathDirectoryListing,
        homeDirectory: String
    ) {
        self.tool = tool
        self.root = root
        self.catalog = catalog
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
        self.protectedPathListing = protectedPathListing
        self.rootPath = PathText.normalize(root.path)
    }

    mutating func run() {
        switch root.role {
        case .toolRoot:
            // 工具根本身是符号链接时不进入：跟随它等于把链接目标算成这台工具的占用
            // （PRD §4.2 对浅扫的同一条纪律，深扫沿用）。依然报告这台工具，只是零占用。
            if fileType(of: rootPath) == .typeSymbolicLink {
                recordUnfollowedLink(path: rootPath, relativePath: "", destination: linkDestination(rootPath))
                return
            }
            walk(directory: rootPath, relativePath: "", protectedReason: nil)

        case .displayOnly:
            runDisplayOnlyRoot()
        }
    }

    /// 仅展示根（issue #31）。
    ///
    /// 缺失时**静默跳过**：规则声明的路径不存在只说明这台机器上没有这个东西
    /// （PRD §5.4「规则命中路径不存在时静默跳过，不得报错」），不影响主根统计，
    /// 也不在「读不到」清单里留一条——它不是读不到，是没有。
    private mutating func runDisplayOnlyRoot() {
        guard let attributes = fileSystem.attributes(ofItemAt: rootPath) else { return }

        guard let type = attributes[.type] as? FileAttributeType else {
            unreadable.append(UnreadableEntry(
                path: rootPath,
                relativePath: "",
                toolID: tool.id,
                kind: .directory,
                reason: "文件类型不可知"
            ))
            return
        }

        switch type {
        case .typeDirectory:
            walk(directory: rootPath, relativePath: "", protectedReason: nil)

        case .typeSymbolicLink:
            // 不跟随符号链接：仅展示根本身是链接时同样不展开（issue #23 硬约束）。
            recordUnfollowedLink(path: rootPath, relativePath: "", destination: linkDestination(rootPath))

        default:
            // 存在的**非目录**条目：规则里会有 `~/.claude.json` 这类文件形态的根。
            // 按不确定计入占用——宁可如实展示，也绝不算作可归档。
            let subpath = PathText.components(of: rootPath).last ?? rootPath
            let size = byteSize(of: attributes)
            if size == nil {
                unreadable.append(UnreadableEntry(
                    path: rootPath,
                    relativePath: "",
                    toolID: tool.id,
                    kind: .item,
                    reason: "读不到文件大小"
                ))
            }
            accumulate(resolution: nil, relativePath: subpath, protectionReason: nil, bytes: size ?? 0)
        }
    }

    // MARK: 递归主体

    /// 递归一层目录。
    ///
    /// 类别与子路径锚点都按**每条路径自己**判定（issue #25 的判定顺序 + 模式声明的层级），
    /// 因此这里不传递类别：一条未声明的路径不可能从父目录「继承」出一个可归档，
    /// 它只会被判成不确定。唯一往下传的是 `protectedReason`——受保护是一次判定，
    /// 命中之后整棵子树都是受保护的（父目录已经判过，不必每个文件重判）。
    private mutating func walk(
        directory: String,
        relativePath: String,
        protectedReason: String?
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
                // 不跟随（issue #23 硬约束）：默认既不把目标的占用算进来，也不进目标遍历。
                //
                // 只有一个例外，而且方向是「更保守」：链接的真实目标被内置清单判为**受保护**
                // 时，链接指向的就是用户碰不得的东西（`~/.codex/skills → ~/.agents/skills`）。
                // 这时把它按受保护统计进来，界面上才能如实说「这里有一份受保护的技能，别动它」；
                // 目标仍不会被归档、不会被移除。
                //
                // 目标落在所属根**之外**且不受保护时一律跳过：跟随它等于把扫描带出规则声明的根
                // （PRD §8.2「指向外部目录的链接一律拒绝处理」）。
                let destination = resolvedLinkDestination(path: path, destination: linkDestination(path))
                recordUnfollowedLink(path: path, relativePath: childRelative, destination: linkDestination(path))

                // 只有「目标在内置清单里受保护」的链接才继续统计，这是安全边界：
                // 指向所属根之外、又不受保护的目录的链接（用户自己的媒体库、别人的仓库）
                // 一律拒绝处理（PRD §8.2）——一个字节都不读、不跟随。
                let protectedTarget = destination.flatMap {
                    BuiltInProtectedPaths.protection(
                        forPath: $0,
                        underToolRoot: rootPath,
                        homeDirectory: homeDirectory,
                        listing: protectedPathListing
                    )?.ruleIdentifier
                }

                if let destination, let reason = protectedTarget {
                    walk(directory: destination, relativePath: childRelative, protectedReason: reason)
                }

            case .typeDirectory:
                // 目录这一层只认「能形容目录本身」的内置条目；文件级条目留给文件自己判。
                let reason = protectedReason ?? directoryProtectionReason(forRelativePath: childRelative)
                walk(directory: path, relativePath: childRelative, protectedReason: reason)

            default:
                // 普通文件（以及门、套接字这类非目录条目，按文件计）。只取大小，不读内容。
                //
                // 类别按**这条路径自己**判：命中多条时报判定顺序最高的那一类（issue #25），
                // 一条都没命中就落进不确定。受保护有三个来源，任一命中即受保护：
                // 已经在受保护目录里、自己命中文件级内置条目、或自己是受保护目标的链接。
                let fileProtection = protectedReason
                    ?? protectionReason(forRelativePath: childRelative)
                    ?? resolvedLinkDestination(path: path, destination: linkDestination(path))
                        .flatMap { protectionReason(forPath: $0, relativePath: childRelative) }
                let resolution = catalog.resolution(
                    forRelativePath: childRelative,
                    toolID: tool.id,
                    isBuiltInProtected: fileProtection != nil
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
        let declared = resolution?.category ?? .uncertain
        let category: DataCategory
        if protectionReason != nil {
            category = .protected
        } else if root.role == .displayOnly, declared == .archivableSession {
            // issue #31 的硬不变量：**仅展示根内的路径一律不可归档**。
            // 规则就算在这条路径上声明了 archivableSession（用户规则可能这么写），
            // 也只当「不确定」——宁可少报可回收空间，也绝不把只展示的数据标成能归档的
            // （PRD §2.3、§5.4、§14.1「Cursor AppSupport 14G、范围内可归档 0」）。
            category = .uncertain
        } else {
            category = declared
        }
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
    /// 判定以**所属根**为作用域：仅展示根（Electron 内部存储）不属于任何已知工具根形状，
    /// 因此落到「未识别位置」的文件名黑名单上——那是保护的下界，宁可多保护
    /// （PRD §2.3：这些位置只展示、绝不动），也不会少保护。
    func protectionReason(forRelativePath relativePath: String) -> String? {
        protectionReason(
            forPath: PathText.appending(relativePath, to: rootPath),
            relativePath: relativePath
        )
    }

    /// 绝对路径的内置受保护判定；`relativePath` 只用于保证判定确实落在所属根内。
    func protectionReason(forPath path: String, relativePath: String) -> String? {
        guard !relativePath.isEmpty,
              PathText.isInside(path, root: rootPath)
        else { return nil }
        return BuiltInProtectedPaths.protection(
            forPath: path,
            underToolRoot: rootPath,
            homeDirectory: homeDirectory,
            listing: protectedPathListing
        )?.ruleIdentifier
    }

    /// **目录**这一层是否直接命中受保护条目。
    ///
    /// 必须与 `protectionReason(forRelativePath:)` 区分开：后者连「目录里有个 `auth.json`」
    /// 都会命中（文件级条目按最后一段比较，对任何相对路径都成立），于是整棵子树会被
    /// 判成受保护——那是错的。目录这一层只认能形容目录本身的条目：目录型条目
    /// （`skills*`、`.agents/skills*`）与真正的目录路径。
    func directoryProtectionReason(forRelativePath relativePath: String) -> String? {
        guard !relativePath.isEmpty else { return nil }
        guard let reason = protectionReason(forRelativePath: relativePath) else { return nil }
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
            isInsideToolRoot: resolved.map { PathText.isInside($0, root: rootPath) } ?? false
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

    private func byteSize(of attributes: [FileAttributeKey: Any]) -> Int64? {
        guard let size = attributes[.size] else { return nil }
        if let number = size as? NSNumber { return number.int64Value }
        if let value = size as? Int64 { return value }
        if let value = size as? Int { return Int64(value) }
        return nil
    }

    // MARK: 出报告

    /// 这一个根贡献的占用（各桶之和）。
    var occupancy: Occupancy {
        Occupancy.sum(buckets.values.flatMap { $0.values }.map {
            Occupancy(bytes: $0.bytes, fileCount: $0.fileCount)
        })
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

    private let report: RuleAdmissionReport
    private let rulesByID: [String: ToolRule]

    init(report: RuleAdmissionReport) {
        self.report = report
        self.rulesByID = Dictionary(
            report.usableRules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 某个工具**已准入**的规则；没有对应规则时为 `nil`。
    ///
    /// issue #31 用它取规则声明的根：一个工具要扫的根由规则决定（主根 + 仅展示根），
    /// 不是由调用方逐个列举。
    func rule(id: String) -> ToolRule? {
        rulesByID[id]
    }

    /// 某条相对路径的规则声明命中情况。
    func resolution(
        forRelativePath relativePath: String,
        toolID: String,
        isBuiltInProtected: Bool
    ) -> RuleMatchResolution? {
        guard rulesByID[toolID] != nil else { return nil }

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
        if let declared = declaredBase(forRelativePath: relativePath, toolID: toolID) {
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
    private func declaredBase(forRelativePath relativePath: String, toolID: String) -> DeclaredBase? {
        guard let rule = rulesByID[toolID], !relativePath.isEmpty else { return nil }
        guard let entry = firstMatchingEntry(relativePath, rule: rule) else { return nil }

        // 锚点取模式的**字面部分**，而不是匹配到的路径本身：
        // `projects/<编码路径>/<uuid>.jsonl` 声明的是「每个项目下的每份转录」，
        // 字面部分是 `projects`，因此这一类汇总到 `projects` 一条；
        // 而 `projects/**` 的字面部分同样是 `projects`。两者因此归到一起，
        // 不会把汇总碎成几百个项目目录名。
        let base = literalBase(of: entry.pattern)
        return DeclaredBase(path: base.isEmpty ? relativePath : base, pattern: entry.pattern.canonicalString)
    }

    /// 按判定顺序取第一条覆盖该路径的分类条目。
    private func firstMatchingEntry(_ relativePath: String, rule: ToolRule) -> ClassificationEntry? {
        rule.classification
            .filter { $0.pattern.matches(relativePath: relativePath) }
            .min { lhs, rhs in
                let lhsRank = Self.precedenceRank(lhs.category)
                let rhsRank = Self.precedenceRank(rhs.category)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.pattern.segments.count > rhs.pattern.segments.count
            }
    }

    /// 模式的**字面前缀**：第一个带通配或占位符的段之前的所有段。
    ///
    /// `projects/**` → `projects`；`projects/<编码路径>/<uuid>.jsonl` → `projects`；
    /// `config.toml` → `config.toml`。尾部的 `**` 也算通配（它意味着「这一层之下」），
    /// 因此不会把 `**` 当成目录名写进子路径。
    private func literalBase(of pattern: PathPattern) -> String {
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
