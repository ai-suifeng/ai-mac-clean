import Foundation

import AIMacCleanCore
import AIMacCleanRules

/// 会话识别与级联（issue #26）。
///
/// 深扫（issue #23）回答「每个工具占了多少、其中多少可归档」；这一层把**可归档的文件**
/// 按会话归组，为 M3 的「按会话归档」打底。GLOSSARY：会话 = 归档与还原的最小单位，
/// 一个会话可能由主转录 + 子代理转录 + 关联数据多个文件组成。
///
/// ## 本类型的硬纪律
///
/// 1. **零写入**：与深扫同源，接口上只有读取；`.zst`/`.zstd` 只按扩展名识别，
///    **绝不解码**（M2 不读压缩内容）。
/// 2. **不跟随符号链接**：链接一律记进 `unfollowedLinks`，既不进会话，也不跟着它走。
/// 3. **不反向解码项目路径**：编码目录名原样给出（PRD §5.3：Claude 的编码不可逆解）。
/// 4. **类别判定只有一处**：可归档与否走深扫那条判定链（`DeepScanRuleCatalog`），
///    因此「会话里的字节数之和 + 归不了组的」必然等于深扫的「可归档会话」占用。
/// 5. **不静默丢弃**：规则声明为可归档、却归不进任何会话的文件进 `unmatched` 并说明原因。
/// 6. **权限错误按目录粒度隔离**：读不到的目录进 `unreadable`，绝不让一次归组整体失败。
///
/// 接口刻意**不抛错**：路径缺失（旧结构的 `file-history/`、`todos/` 在新版
/// `~/.claude` 里根本不存在）是常态，静默跳过即可（PRD §5.4）。
public protocol SessionGrouping {

    func group(
        tools: [ConfirmedTool],
        rules: RuleAdmissionReport,
        homeDirectory: String
    ) -> SessionGroupingReport

    /// 便利入口：直接给一组**已准入**的规则。
    func group(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String
    ) -> SessionGroupingReport
}

/// 会话归组的默认实现。
public struct SessionGrouper: SessionGrouping, @unchecked Sendable {

    private let fileSystem: any DiscoveryFileSystem
    private let protectedPathListing: any ProtectedPathDirectoryListing

    /// - Parameters:
    ///   - fileSystem: 可注入的文件系统读取层（与深扫同一个 `DiscoveryFileSystem`）。
    ///     测试套 `WriteRecordingDiscoveryFileSystem` 后可以断言「一次归组有没有写过」。
    ///   - protectedPathListing: 内置受保护判定做通配展开时的目录列举（issue #19）。
    public init(
        fileSystem: any DiscoveryFileSystem = RealDiscoveryFileSystem(),
        protectedPathListing: any ProtectedPathDirectoryListing = RealProtectedPathDirectoryListing()
    ) {
        self.fileSystem = fileSystem
        self.protectedPathListing = protectedPathListing
    }

    public func group(
        tools: [ConfirmedTool],
        rules: RuleAdmissionReport,
        homeDirectory: String
    ) -> SessionGroupingReport {
        let catalog = DeepScanRuleCatalog(report: rules)
        let rulesByID = Dictionary(
            rules.usableRules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let reports = tools.map { tool in
            ToolGrouping(
                tool: tool,
                rule: rulesByID[tool.id],
                catalog: catalog,
                fileSystem: fileSystem,
                protectedPathListing: protectedPathListing,
                homeDirectory: homeDirectory
            ).run()
        }
        // 固定按工具标识排序：结果必须确定，不反映扫描顺序（与深扫一致）。
        return SessionGroupingReport(toolReports: reports.sorted { $0.toolID < $1.toolID })
    }

    public func group(
        tools: [ConfirmedTool],
        rules: [ToolRule],
        homeDirectory: String
    ) -> SessionGroupingReport {
        group(
            tools: tools,
            rules: RuleAdmissionReport(usableRules: rules, rejections: []),
            homeDirectory: homeDirectory
        )
    }
}

// MARK: - 磁盘上的一条文件事实

/// 遍历读到的一个文件：会话归组只需要这四件事。
private struct SessionFileFact {
    let path: String
    let relativePath: String
    let bytes: Int64
    let lastModified: Date?
}

// MARK: - 单台工具的归组

/// 单台工具的会话归组。一次性用完即弃。
private struct ToolGrouping {

    /// 一次「这条路径属于谁」的判定结果（连同把它判为可归档的那条分类条目）。
    private struct Decision {
        let association: Association
        /// 分类表里把它声明为可归档的那条模式（原样给出），供清单说明「凭什么算会话」。
        let declaredBy: String?
    }

    private enum Association {
        /// 不参与归组（规则没声明为可归档，或内置清单判为受保护）。
        case notArchivable
        /// 会话文件（主转录）：由规则声明的一条会话形状命中。
        case sessionFile(pattern: PathPattern)
        /// 按会话 ID 关联的关联数据。
        case keyed(sessionID: String)
        /// 与主转录同级的子代理转录，基准目录为 `base`。
        case sibling(base: String)
        /// 规则声明为可归档，却归不进任何会话。
        case unmatched(SessionGroupingGap)
    }

    /// 一个会话的累积体（出报告前可变）。
    private struct Working {
        let id: String
        var project: SessionProject?
        var mainDirectory: String?
        var files: [SessionFile] = []
    }

    let tool: ConfirmedTool
    let rule: ToolRule?
    let catalog: DeepScanRuleCatalog
    let fileSystem: any DiscoveryFileSystem
    let protectedPathListing: any ProtectedPathDirectoryListing
    let homeDirectory: String
    let toolRoot: String

    init(
        tool: ConfirmedTool,
        rule: ToolRule?,
        catalog: DeepScanRuleCatalog,
        fileSystem: any DiscoveryFileSystem,
        protectedPathListing: any ProtectedPathDirectoryListing,
        homeDirectory: String
    ) {
        self.tool = tool
        self.rule = rule
        self.catalog = catalog
        self.fileSystem = fileSystem
        self.protectedPathListing = protectedPathListing
        self.homeDirectory = homeDirectory
        self.toolRoot = PathText.normalize(tool.toolRootPath)
    }

    func run() -> ToolSessionReport {
        // 没有对应规则的工具：没有任何路径被判为可归档，也就没有任何会话。
        // 工具照常出现在结果里（用户确认过的工具不许被静默丢掉），只是空的。
        guard let rule else {
            return ToolSessionReport(
                toolID: tool.id,
                displayName: tool.displayName,
                toolRootPath: tool.toolRootPath,
                sessions: [],
                unmatched: [],
                unreadable: [],
                unfollowedLinks: []
            )
        }

        let shapes = SessionShapeCatalog(rule: rule)
        var walker = DirectoryWalk(
            tool: tool,
            toolRoot: toolRoot,
            shapes: shapes,
            fileSystem: fileSystem
        )
        let walk = walker.run()

        var working: [String: Working] = [:]
        var sessionsByDirectory: [String: Set<String>] = [:]
        var waiting: [(SessionFileFact, Decision)] = []
        var unmatched: [UnmatchedArchivableFile] = []

        // 第一遍：先认出所有会话（主转录），这样第二遍的级联文件才有东西可挂。
        for fact in walk.files {
            let decision = association(for: fact, shapes: shapes)
            switch decision.association {
            case let .sessionFile(shape):
                let id = SessionIdentity.sessionID(
                    forRelativePath: fact.relativePath,
                    source: rule.sessionFileNaming?.sessionIDSource ?? .fileName
                )
                let directory = parentDirectory(of: fact.relativePath)

                var session = working[id] ?? Working(id: id)
                if session.mainDirectory == nil {
                    session.mainDirectory = directory
                    session.project = project(for: fact, pattern: shape, rule: rule)
                }
                session.files.append(file(fact, role: .mainTranscript, declaredBy: decision.declaredBy))
                working[id] = session
                sessionsByDirectory[directory, default: []].insert(id)

            case .keyed, .sibling, .unmatched:
                waiting.append((fact, decision))

            case .notArchivable:
                continue
            }
        }

        // 第二遍：级联与「归不进会话」的如实呈现。
        for (fact, decision) in waiting {
            switch decision.association {
            case let .keyed(sessionID):
                guard var session = working[sessionID] else {
                    unmatched.append(unmatchedFile(fact, gap: .sessionNotFound(sessionID: sessionID), declaredBy: decision.declaredBy))
                    continue
                }
                session.files.append(file(fact, role: .associatedData, declaredBy: decision.declaredBy))
                working[sessionID] = session

            case let .sibling(base):
                let candidates = (sessionsByDirectory[base] ?? []).sorted()
                switch candidates.count {
                case 1:
                    let id = candidates[0]
                    guard var session = working[id] else { break }
                    session.files.append(file(fact, role: .subagentTranscript, declaredBy: decision.declaredBy))
                    working[id] = session
                case 0:
                    unmatched.append(unmatchedFile(fact, gap: .noMainTranscript(directory: base), declaredBy: decision.declaredBy))
                default:
                    // 同目录下有多份主转录：`agent-*.jsonl` 这类文件名里没有会话 UUID，
                    // 归属无法确定。**保守取值：不猜**，如实列出候选。
                    unmatched.append(unmatchedFile(
                        fact,
                        gap: .ambiguousMainTranscript(directory: base, candidates: candidates),
                        declaredBy: decision.declaredBy
                    ))
                }

            case let .unmatched(gap):
                unmatched.append(unmatchedFile(fact, gap: gap, declaredBy: decision.declaredBy))

            case .sessionFile, .notArchivable:
                continue
            }
        }

        let sessions = working.values
            .map { session -> Session in
                let files = session.files.sorted { $0.relativePath < $1.relativePath }
                return Session(
                    id: session.id,
                    toolID: tool.id,
                    toolDisplayName: tool.displayName,
                    project: session.project,
                    files: files,
                    occupancy: Occupancy.sum(files.map { Occupancy(bytes: $0.bytes, fileCount: 1) }),
                    lastModified: files.compactMap(\.lastModified).max()
                )
            }
            .sorted { $0.id < $1.id }

        return ToolSessionReport(
            toolID: tool.id,
            displayName: tool.displayName,
            toolRootPath: tool.toolRootPath,
            sessions: sessions,
            unmatched: unmatched.sorted { $0.relativePath < $1.relativePath },
            unreadable: walk.unreadable,
            unfollowedLinks: walk.unfollowedLinks
        )
    }

    // MARK: - 判定

    /// 这条路径属于谁。
    private func association(for fact: SessionFileFact, shapes: SessionShapeCatalog) -> Decision {
        // 1. 类别先判：只有规则声明为可归档的文件才谈得上会话。
        //
        //    先按「不受内置保护」问一次：受保护只会把它改成受保护，绝不会改成可归档，
        //    因此这一步问出来的「不是可归档」就已经是最终答案，不必再做受保护判定
        //    （那一步要读磁盘，能省则省）。
        guard let resolution = catalog.resolution(
            forRelativePath: fact.relativePath,
            toolID: tool.id,
            isBuiltInProtected: false
        ), resolution.category == .archivableSession else {
            return Decision(association: .notArchivable, declaredBy: nil)
        }

        // 2. 内置受保护压过规则声明（PRD §8.1：内置清单是下界，规则不能把它改判）。
        if protectionReason(for: fact) != nil {
            return Decision(association: .notArchivable, declaredBy: resolution.pattern)
        }

        let declaredBy = resolution.pattern

        // 3. 级联声明优先于「会话文件」：同一条路径既可能命中会话形状又命中级联
        //    （Claude 的 `agent-<uuid>.jsonl` 两边都有），而级联给出的角色更具体。
        for cascade in shapes.cascades {
            switch cascade.kind {
            case .siblingTranscripts:
                if let base = shapes.siblingBaseDirectory(for: fact.relativePath, pattern: cascade.pattern) {
                    return Decision(association: .sibling(base: base), declaredBy: declaredBy)
                }
            case .sessionKeyedDirectory:
                if let id = shapes.keyedDirectorySessionID(for: fact.relativePath, pattern: cascade.pattern) {
                    return Decision(association: .keyed(sessionID: id), declaredBy: declaredBy)
                }
            case .sessionKeyedFile:
                if let id = shapes.keyedFileSessionID(for: fact.relativePath, pattern: cascade.pattern) {
                    return Decision(association: .keyed(sessionID: id), declaredBy: declaredBy)
                }
            }
        }

        // 4. 会话文件形状。
        if let shape = shapes.bestSessionPattern(for: fact.relativePath) {
            return Decision(association: .sessionFile(pattern: shape), declaredBy: declaredBy)
        }

        // 5. 规则说它可归档，可它不符合任何会话形状：如实呈现，不静默丢弃。
        return Decision(association: .unmatched(.shapeNotDeclared), declaredBy: declaredBy)
    }

    /// 会话文件所属项目的来源（PRD §5.3）。
    private func project(for fact: SessionFileFact, pattern: PathPattern, rule: ToolRule) -> SessionProject? {
        guard let encoding = rule.projectPathEncoding else { return nil }
        switch encoding.scheme {
        case .singleDash, .doubleDash:
            // 编码目录名原样给出：绝不反向解码（Claude 的编码有歧义）。
            guard let name = pattern.firstCapture(kind: .encodedPath, in: fact.relativePath),
                  !name.isEmpty
            else { return nil }
            return .encodedDirectory(name: name, scheme: encoding.scheme)
        case .inFileField:
            guard let fieldPath = encoding.fieldPath else { return nil }
            return .declaredInFileField(fieldPath: fieldPath)
        }
    }

    private func file(_ fact: SessionFileFact, role: SessionFileRole, declaredBy: String?) -> SessionFile {
        SessionFile(
            path: fact.path,
            relativePath: fact.relativePath,
            bytes: fact.bytes,
            lastModified: fact.lastModified,
            role: role,
            pattern: declaredBy
        )
    }

    private func unmatchedFile(
        _ fact: SessionFileFact,
        gap: SessionGroupingGap,
        declaredBy: String?
    ) -> UnmatchedArchivableFile {
        UnmatchedArchivableFile(
            toolID: tool.id,
            path: fact.path,
            relativePath: fact.relativePath,
            bytes: fact.bytes,
            lastModified: fact.lastModified,
            gap: gap,
            pattern: declaredBy
        )
    }

    /// 内置受保护判定（按链接真实目标，与深扫同一条）。
    ///
    /// 只对「候选可归档」的文件调用：绝大多数文件（缓存、受保护目录里的文件）在
    /// 第 1 步就被规则挡掉了，不必为它们读磁盘。
    private func protectionReason(for fact: SessionFileFact) -> String? {
        BuiltInProtectedPaths.protection(
            forPath: fact.path,
            underToolRoot: toolRoot,
            homeDirectory: homeDirectory,
            listing: protectedPathListing
        )?.ruleIdentifier
    }

    private func parentDirectory(of relativePath: String) -> String {
        let components = PathText.components(of: relativePath)
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }
}

// MARK: - 递归

/// 单台工具的递归遍历：只收**文件事实**（路径、字节数、最后修改时间）。
///
/// 与深扫的遍历同源但目标不同：深扫要按类别汇总占用，这里要按形状归组成会话。
/// 两者共用同一个可注入的文件系统接缝（`DiscoveryFileSystem`）与同一条路径运算
/// （`PathText`），因此「碰了哪些路径」「有没有写」可以被同一套记录器断言。
///
/// 目录剪枝：只进「可能命中声明形状」的子树（见 `SessionShapeCatalog.pruningBases`）。
/// 本机实测的大头 `~/.claude/plugins`（247M）、`~/.codex/.tmp`（879M / 24,849 个文件）
/// 因此连列举都不必——它们本来就不可能是会话文件。
private struct DirectoryWalk {

    struct Result {
        let files: [SessionFileFact]
        let unreadable: [UnreadableEntry]
        let unfollowedLinks: [UnfollowedLink]
    }

    let tool: ConfirmedTool
    let toolRoot: String
    let shapes: SessionShapeCatalog
    let fileSystem: any DiscoveryFileSystem

    private var files: [SessionFileFact] = []
    private var unreadable: [UnreadableEntry] = []
    private var unfollowedLinks: [UnfollowedLink] = []

    init(
        tool: ConfirmedTool,
        toolRoot: String,
        shapes: SessionShapeCatalog,
        fileSystem: any DiscoveryFileSystem
    ) {
        self.tool = tool
        self.toolRoot = toolRoot
        self.shapes = shapes
        self.fileSystem = fileSystem
    }

    mutating func run() -> Result {
        // 工具根本身是符号链接时不进入：跟随它等于把链接目标的会话算成这台工具的。
        if fileType(of: toolRoot) == .typeSymbolicLink {
            unfollowedLinks.append(UnfollowedLink(
                path: toolRoot,
                relativePath: "",
                toolID: tool.id,
                destination: fileSystem.symbolicLinkDestination(atPath: toolRoot),
                isInsideToolRoot: false
            ))
            return Result(files: files, unreadable: unreadable, unfollowedLinks: unfollowedLinks)
        }
        walk(directory: toolRoot, relativePath: "")
        return Result(files: files, unreadable: unreadable, unfollowedLinks: unfollowedLinks)
    }

    private mutating func walk(directory: String, relativePath: String) {
        let entries: [String]
        do {
            entries = try fileSystem.entryNames(inDirectory: directory)
        } catch {
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
                // 不跟随：链接不进会话，也不进它指向的位置（issue #26 验收 7）。
                unfollowedLinks.append(UnfollowedLink(
                    path: path,
                    relativePath: childRelative,
                    toolID: tool.id,
                    destination: fileSystem.symbolicLinkDestination(atPath: path),
                    isInsideToolRoot: resolvedLinkDestination(path: path).map {
                        PathText.isInside($0, root: toolRoot)
                    } ?? false
                ))

            case .typeDirectory:
                guard shapes.shouldDescend(into: childRelative) else { continue }
                walk(directory: path, relativePath: childRelative)

            default:
                files.append(SessionFileFact(
                    path: path,
                    relativePath: childRelative,
                    bytes: byteSize(of: attributes) ?? 0,
                    lastModified: attributes[.modificationDate] as? Date
                ))
            }
        }
    }

    private func fileType(of path: String) -> FileAttributeType? {
        fileSystem.attributes(ofItemAt: path)?[.type] as? FileAttributeType
    }

    private func resolvedLinkDestination(path: String) -> String? {
        guard let destination = fileSystem.symbolicLinkDestination(atPath: path) else { return nil }
        if destination.hasPrefix("/") { return PathText.normalize(destination) }
        return PathText.normalize(PathText.appending(destination, to: PathText.parent(of: path)))
    }

    private func byteSize(of attributes: [FileAttributeKey: Any]) -> Int64? {
        guard let size = attributes[.size] else { return nil }
        if let number = size as? NSNumber { return number.int64Value }
        if let value = size as? Int64 { return value }
        if let value = size as? Int { return Int64(value) }
        return nil
    }
}
