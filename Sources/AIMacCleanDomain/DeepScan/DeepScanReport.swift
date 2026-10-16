import Foundation

import AIMacCleanRules

/// 深扫的输入：一台**已确认**的工具（issue #23、PRD §4.1 第 4 步）。
///
/// 深扫只跑在已确认工具上，入口因此是「已确认工具」而不是候选列表。
/// 工具根路径用绝对路径：本类型的消费者已经把它从声明路径解析出来（浅扫与确认那一步），
/// 深扫不为它重复解析 `~`。
///
/// 这里只给**主工具根**：规则为这个工具声明的仅展示根（`displayOnly`）由深扫自己从规则里取、
/// 用 `homeDirectory` 展开（issue #31）——规则声明了却忘记扫，正是
/// 「Cursor AppSupport 14G 没进占用」的成因。
public struct ConfirmedTool: Equatable, Hashable, Sendable {

    /// 工具标识，对应 `ToolRule.id`。
    public let id: String

    /// 界面展示名。
    public let displayName: String

    /// 工具根目录的绝对路径：安全检查的原点（GLOSSARY「工具根目录」）。
    public let toolRootPath: String

    public init(id: String, displayName: String, toolRootPath: String) {
        self.id = id
        self.displayName = displayName
        self.toolRootPath = toolRootPath
    }
}

/// 深扫的一条**未声明路径**的分类归属（issue #23）。
public enum CategoryProvenance: Equatable, Hashable, Sendable {

    /// 这条路径本身被规则声明命中。
    case declaredPath(String)

    /// 这条路径没有被声明，归到最近一条把它盖住的声明（例如 `projects/**` 覆盖的深层文件）。
    case declaredAncestor(String)

    /// 规则一个都没声明到它，也没有可继承的上级：落进**不确定**。
    ///
    /// 这是本票最要紧的一条纪律（PRD §5.1、GLOSSARY「不确定」）：规则没声明的路径
    /// **绝不默认算作可归档**，宁可少报可回收空间，也不许把用户的东西误标成能归档的。
    case undeclared
}

/// 某个「工具 → 类别 → 子路径」下的占用汇总。
public struct CategorySummary: Equatable, Hashable, Sendable {

    /// 子路径：相对**所属根**（主工具根或规则声明的仅展示根，issue #31），
    /// 指向**命中规则的那一层**（`projects`、`.tmp`），
    /// 或者未声明路径的顶层目录名。根直接挂着的文件用它自己的名字。
    public let subpath: String

    /// 这次汇总到的分类条目（按模式串原样给出），界面据此说明「这条为什么是这一类」。
    ///
    /// 受保护的内置条目不算「规则声明的模式」，因此这时是 `nil`——见 `protectionReason`。
    public let pattern: String?

    /// 受保护判定的命中来源：非 `nil` 表示这一条是**内置受保护清单**判出来的
    /// （`claude-code/skills`、`credential/auth`），而不是规则声明的。
    ///
    /// 两者的区别对用户有意义：规则可以被用户改，内置清单不能（PRD §8.1）。
    public let protectionReason: String?

    /// 归属来源。
    public let provenance: CategoryProvenance

    /// 本子路径下的占用。
    public let occupancy: Occupancy

    public init(
        subpath: String,
        pattern: String?,
        protectionReason: String? = nil,
        provenance: CategoryProvenance,
        occupancy: Occupancy
    ) {
        self.subpath = subpath
        self.pattern = pattern
        self.protectionReason = protectionReason
        self.provenance = provenance
        self.occupancy = occupancy
    }
}

/// 一个工具下某一类的占用汇总。
public struct CategoryOccupancy: Equatable, Sendable {

    public let category: DataCategory

    /// 本类合计。
    public let occupancy: Occupancy

    /// 本类名下「直接装着文件」的目录数（同一目录只数一次）。
    ///
    /// 它回答的不是「有多少数据」，而是「有多少个地方」——PRD §14 的实测大头里，
    /// 「一个地方 24,849 个文件」与「24,849 个地方各一个文件」是完全不同的两件事。
    /// 工具根本身不算一个「目录」（它是扫描原点，不是数据落点）。
    public let holdingDirectoryCount: Int

    /// 本类按子路径的明细，字节数降序（相同则按子路径字典序，保证顺序稳定）。
    public let summaries: [CategorySummary]

    public init(
        category: DataCategory,
        occupancy: Occupancy,
        holdingDirectoryCount: Int,
        summaries: [CategorySummary]
    ) {
        self.category = category
        self.occupancy = occupancy
        self.holdingDirectoryCount = holdingDirectoryCount
        self.summaries = summaries
    }
}

/// 一个**读不到**的位置（PRD §4.4：权限错误按目录粒度隔离）。
///
/// 一条记录回答三件事：哪里读不到、为什么、它是什么。界面的职责是把这些位置
/// **如实列出来**并引导用户去系统设置，而不是让整次扫描失败。
public struct UnreadableEntry: Equatable, Sendable {

    /// 读不到的位置：目录的绝对路径，或查不到属性的条目路径。
    public let path: String

    /// 相对**所属根**（主工具根或规则声明的仅展示根）的路径，便于界面归到某个工具名下。
    public let relativePath: String

    /// 所属工具的标识。
    public let toolID: String

    /// 读不到的对象是目录还是条目。
    public let kind: UnreadableKind

    /// 文件系统给出的原因（`Error.localizedDescription`），读不到时为 `nil`。
    public let reason: String?

    public init(path: String, relativePath: String, toolID: String, kind: UnreadableKind, reason: String?) {
        self.path = path
        self.relativePath = relativePath
        self.toolID = toolID
        self.kind = kind
        self.reason = reason
    }
}

/// 读不到的对象种类。
public enum UnreadableKind: String, Equatable, Hashable, Sendable {

    /// 目录列举不了（没有读权限）：里面的东西一个都统计不到。
    case directory

    /// 条目查不到属性：算进文件数，但字节数按 0 计——宁可少报，也不许凭形状猜一个数。
    case item
}

/// 一条**没有被跟随**的符号链接（issue #23 硬约束：不跟随符号链接）。
///
/// 两个方向都要记：指向工具根**内部**的链接（用户自己想知道的冗余）与指向
/// 工具根**之外**的链接（PRD §8.2：一律拒绝处理）。
///
/// ## 它计什么、不计什么（spec #22）
///
/// **零字节、零文件**：无论目标是受保护还是不受保护，链接本身与它的目标都不进占用
/// （`~/.codex/skills → ~/.agents/skills` 的字节不能被同时算进 `~/.codex` 与 `~/.opencode`，
/// 否则概览总数对不上 `du`），也绝不遍历目标——访问永远停在规则声明的根内。
///
/// 它仍然回答「这条链接碰不碰得」：`protectionReason` 非 `nil` 表示内置清单把这条链接
/// （或它的真实目标）判为受保护。判定归判定，占用归占用，两者互不换算。
public struct UnfollowedLink: Equatable, Sendable {

    /// 链接自身的路径（绝对）。
    public let path: String

    /// 相对**所属根**（主工具根或规则声明的仅展示根）的路径。
    public let relativePath: String

    /// 所属工具的标识。
    public let toolID: String

    /// 链接指向哪里（原样读出，未解析成绝对路径）。
    public let destination: String?

    /// 链接目标是否落在**所属根**内部。
    public let isInsideToolRoot: Bool

    /// 内置受保护判定的命中来源；非 `nil` 表示这条链接按**真实目标**（PRD §8.2 / §14.5）
    /// 或链接自身的位置判为受保护。
    ///
    /// 这只是**判定**，不是占用：受保护的链接照样计 0 字节 / 0 文件。
    public let protectionReason: String?

    /// 这条链接是否被判为受保护（与 `protectionReason != nil` 等价，读起来更直白）。
    public var isProtected: Bool { protectionReason != nil }

    public init(
        path: String,
        relativePath: String,
        toolID: String,
        destination: String?,
        isInsideToolRoot: Bool,
        protectionReason: String? = nil
    ) {
        self.path = path
        self.relativePath = relativePath
        self.toolID = toolID
        self.destination = destination
        self.isInsideToolRoot = isInsideToolRoot
        self.protectionReason = protectionReason
    }
}

/// 一个**根**在这一次深扫里的占用（issue #31）。
///
/// 一个工具的占用可能由多个规则声明的根贡献：主工具根（`~/.cursor`，归档范围）
/// 与仅展示根（`~/Library/Application Support/Cursor`，只展示、绝不动）。
/// 概览页据此如实显示「Cursor 2.1G + 14G 只展示」（PRD §14.1）——
/// 把两者合成一个数会让用户以为 Cursor 只占 2.1G。
///
/// `path` 是**绝对路径**：规则里的 `~/…` 在进深扫之前已经展开。
public struct ToolRootOccupancy: Equatable, Hashable, Sendable {

    /// 根的绝对路径。
    public let path: String

    /// 根的角色：主工具根（归档范围）或仅展示根。
    public let role: ToolRootRole

    /// 这个根贡献的占用。
    public let occupancy: Occupancy

    public init(path: String, role: ToolRootRole, occupancy: Occupancy) {
        self.path = path
        self.role = role
        self.occupancy = occupancy
    }
}

/// 一台工具的深扫结果。
public struct ToolScanReport: Equatable, Sendable {

    public let toolID: String
    public let displayName: String

    /// 工具根目录的绝对路径。
    public let toolRootPath: String

    /// 本工具的总占用（四类之和，含规则声明的仅展示根；恒等于 `roots` 各根之和）。
    public let occupancy: Occupancy

    /// 四类的占用，只列出**确实有东西**的那些（没有数据的类别不留占位空行）。
    /// 顺序固定为 PRD §5.1 的表格顺序。
    public let categories: [CategoryOccupancy]

    /// 本工具的占用由哪几个根贡献：主工具根在前，规则声明的仅展示根按声明顺序在后。
    ///
    /// 没被扫到的根不在这个列表里——**缺失的仅展示根静默跳过**（PRD §5.4「规则容忍缺失」），
    /// 而主工具根永远在（它是扫描原点，哪怕一个字节都读不到）。
    public let roots: [ToolRootOccupancy]

    /// 本工具下所有「直接装着文件」的目录数（同一目录只数一次，工具根本身不算）。
    public let holdingDirectoryCount: Int

    /// 本次扫描里读不到的位置。
    public let unreadable: [UnreadableEntry]

    /// 本次扫描里没有被跟随的符号链接。
    public let unfollowedLinks: [UnfollowedLink]

    public init(
        toolID: String,
        displayName: String,
        toolRootPath: String,
        occupancy: Occupancy,
        categories: [CategoryOccupancy],
        roots: [ToolRootOccupancy],
        holdingDirectoryCount: Int,
        unreadable: [UnreadableEntry],
        unfollowedLinks: [UnfollowedLink]
    ) {
        self.toolID = toolID
        self.displayName = displayName
        self.toolRootPath = toolRootPath
        self.occupancy = occupancy
        self.categories = categories
        self.roots = roots
        self.holdingDirectoryCount = holdingDirectoryCount
        self.unreadable = unreadable
        self.unfollowedLinks = unfollowedLinks
    }

    /// 取某一类的汇总；本工具下没有该类数据时返回 `nil`。
    public func category(_ category: DataCategory) -> CategoryOccupancy? {
        categories.first { $0.category == category }
    }

    /// 本工具可归档会话的占用（PRD §9 的「可归档占比」）。
    public var archivableOccupancy: Occupancy {
        category(.archivableSession)?.occupancy ?? Occupancy()
    }

    /// **主工具根**贡献的占用（归档范围的占用）。
    ///
    /// 与 `archivableOccupancy` 不是一回事：这里说的是「归档范围有多大」，
    /// 后者说的是「范围内真正能归档的字节有多少」。仅展示根一个字节都不算进来。
    public var toolRootOccupancy: Occupancy {
        Occupancy.sum(roots.filter { $0.role == .toolRoot }.map(\.occupancy))
    }

    /// **仅展示根**合计（PRD §14.1 的「Cursor AppSupport 14G」）。
    ///
    /// 这部分永远不进可归档：它只出现在占用里，用于如实展示（PRD §2.3、§5.4）。
    public var displayOnlyOccupancy: Occupancy {
        Occupancy.sum(roots.filter { $0.role == .displayOnly }.map(\.occupancy))
    }
}

/// 一次深扫的完整结果。
public struct DeepScanReport: Equatable, Sendable {

    /// 各工具的占用，**按工具标识排序**。
    ///
    /// 顺序刻意不反映扫描完成顺序：并行扫描下完成顺序本来就不确定，
    /// 而「结果与串行一致」是本票的硬约束（issue #23 验收 7）。
    public let toolReports: [ToolScanReport]

    public init(toolReports: [ToolScanReport]) {
        self.toolReports = toolReports
    }

    /// 所有工具的总占用。
    public var totalOccupancy: Occupancy {
        Occupancy.sum(toolReports.map(\.occupancy))
    }

    /// 总字节数。
    public var totalBytes: Int64 { totalOccupancy.bytes }

    /// 总文件数。
    public var totalFileCount: Int { totalOccupancy.fileCount }

    /// 各工具加起来的可归档占用。
    public var archivableOccupancy: Occupancy {
        Occupancy.sum(toolReports.map(\.archivableOccupancy))
    }

    /// 可归档字节占比（总字节为 0 时返回 0）。算法只有一处：`ArchivableShare`。
    public var archivableShare: Double {
        ArchivableShare.share(of: archivableOccupancy.bytes, totalBytes: totalOccupancy.bytes)
    }

    /// 按工具标识取一份报告。
    public func toolReport(id: String) -> ToolScanReport? {
        toolReports.first { $0.toolID == id }
    }

    /// 本次扫描里所有读不到的位置（按工具、再按路径排序）。
    public var unreadable: [UnreadableEntry] {
        toolReports.flatMap(\.unreadable)
    }

    /// 本次扫描里所有没有被跟随的符号链接。
    public var unfollowedLinks: [UnfollowedLink] {
        toolReports.flatMap(\.unfollowedLinks)
    }
}

/// 深扫的扫描**选项**。
public struct DeepScanOptions: Equatable, Sendable {

    /// 同时扫描几台工具。
    ///
    /// 默认 4：本机实测的大头是单台工具内的数万文件（`~/.codex/.tmp` 一处 24,849 个），
    /// 台数并不多，因此并行度不必高；4 已经足以避免「一台 12G 的工具把其余工具排在后面」。
    /// 设成 1 即退化为串行，测试用它对照「结果与串行一致」。
    public let maxConcurrentTools: Int

    public init(maxConcurrentTools: Int = 4) {
        self.maxConcurrentTools = max(1, maxConcurrentTools)
    }

    /// 串行扫描（测试与诊断用）。
    public static let serial = DeepScanOptions(maxConcurrentTools: 1)
}
