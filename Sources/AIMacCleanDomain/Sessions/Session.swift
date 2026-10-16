import Foundation

import AIMacCleanCore
import AIMacCleanRules

/// 一个文件在**会话**里的角色（issue #26；GLOSSARY「转录」「关联数据」）。
///
/// 归档与还原都以会话为单位，因此每个文件都要说清它是谁：主转录是会话的标识来源，
/// 子代理转录与关联数据是随会话一并走的附属物。三者的区分不是装饰——M3 的归档清单
/// 要按角色说明「这个包里都有什么」，还原时也必须按同一份清单写回。
public enum SessionFileRole: String, Equatable, Hashable, Sendable {

    /// 主转录：会话 ID 由它决定（GLOSSARY「转录」）。
    case mainTranscript

    /// 子代理转录：与主转录同级、按规则声明的 `siblingTranscripts` 级联进来的转录。
    case subagentTranscript

    /// 关联数据：按会话 ID 关联、不在转录文件内的数据（GLOSSARY「关联数据」）。
    case associatedData
}

/// 会话里的一个文件。
public struct SessionFile: Equatable, Hashable, Sendable {

    /// 绝对路径（还原时要写回的位置）。
    public let path: String

    /// 相对工具根的路径，便于界面与清单里稳定引用。
    public let relativePath: String

    /// 原始字节数（`.zst`/`.zstd` 是**压缩后**的原始大小，不解码——M2 不读压缩内容）。
    public let bytes: Int64

    /// 最后修改时间；读不到时为 `nil`。
    public let lastModified: Date?

    /// 本文件在会话里的角色。
    public let role: SessionFileRole

    /// 把它声明为可归档的那条**分类条目**模式（原样给出），便于回答「凭什么算会话」。
    public let pattern: String?

    public init(
        path: String,
        relativePath: String,
        bytes: Int64,
        lastModified: Date?,
        role: SessionFileRole,
        pattern: String?
    ) {
        self.path = path
        self.relativePath = relativePath
        self.bytes = bytes
        self.lastModified = lastModified
        self.role = role
        self.pattern = pattern
    }
}

/// 会话所属项目的来源（PRD §5.3 的 4 套互不兼容编码方案）。
///
/// 只有两种可能：**编码目录名**与**文件内字段**。前者是不可逆编码，因此一律原样展示
/// （`/Users/x/.claude` → `-Users-xiaowei--claude` 这类双横线解码有歧义），本层绝不试图
/// 还原成真实路径；后者是 Codex 的权威来源，但读它属于读文件内容，M2 不做。
public enum SessionProject: Equatable, Hashable, Sendable {

    /// 规则声明的编码方案下的目录名：**原样保留**，不反向解码。
    case encodedDirectory(name: String, scheme: ProjectPathEncodingScheme)

    /// 项目路径在文件内字段里（Codex 的 `session_meta.payload.cwd`）。
    ///
    /// 本阶段**不读文件内容**（PRD §13 第 3 条、`.zst` 不解码），因此这里只有字段路径、
    /// 没有值。把它显式记下来而不是丢掉，是为了让界面能如实说「项目名要等读文件头」，
    /// 也为了让 M3/M6 有明确的落点——而不是让人以为「这个会话没有项目」。
    case declaredInFileField(fieldPath: String)

    /// 界面可展示的项目名；文件内字段在 M2 拿不到值。
    public var label: String? {
        switch self {
        case let .encodedDirectory(name, _): return name
        case .declaredInFileField: return nil
        }
    }
}

/// 一个**会话**（GLOSSARY：归档与还原的最小单位）。
public struct Session: Equatable, Sendable {

    /// 会话 ID：文件名里的会话 UUID（`sessionIDSource == .fileName`）或父目录名
    /// （`sessionIDSource == .parentDirectoryName`）。
    public let id: String

    /// 所属工具标识（`ToolRule.id`）。
    public let toolID: String

    /// 界面展示名。
    public let toolDisplayName: String

    /// 项目来源；规则没有声明任何项目编码方案时为 `nil`。
    public let project: SessionProject?

    /// 会话的全部文件，按相对路径排序（主转录、子代理转录、关联数据混在同一清单里，
    /// 由各自的 `role` 区分）。
    public let files: [SessionFile]

    /// 原始总占用：**其全部文件之和**（压缩文件按压缩后大小计）。
    public let occupancy: Occupancy

    /// 最后修改时间：全部文件里最晚的那一个（会话最后一次有动静的时刻）。
    public let lastModified: Date?

    public init(
        id: String,
        toolID: String,
        toolDisplayName: String,
        project: SessionProject?,
        files: [SessionFile],
        occupancy: Occupancy,
        lastModified: Date?
    ) {
        self.id = id
        self.toolID = toolID
        self.toolDisplayName = toolDisplayName
        self.project = project
        self.files = files
        self.occupancy = occupancy
        self.lastModified = lastModified
    }

    /// 某个角色的文件。
    public func files(withRole role: SessionFileRole) -> [SessionFile] {
        files.filter { $0.role == role }
    }
}

/// 一个可归档文件**没能归进任何会话**的原因。
///
/// 这一层存在的理由是「不得静默丢弃」（issue #26 范围最后一条）：归不进会话的可归档
/// 文件可能意味着规则缺口（形状没声明）或数据残缺（转录已不在），两种都得说出来，
/// 但都**不许**把它随手并进某个会话——那会让用户以为它会跟着那个会话一起被归档。
public enum SessionGroupingGap: Equatable, Hashable, Sendable {

    /// 规则声明它是可归档，但它不符合任何会话形状（散落文件）。
    case shapeNotDeclared

    /// 按会话 ID 级联（`file-history/`、`todos/`），但树里没有这个会话的转录。
    case sessionNotFound(sessionID: String)

    /// 同级转录，但所在目录里没有主转录。
    case noMainTranscript(directory: String)

    /// 同级转录，但所在目录里有多个主转录，无法确定归属。**保守取值：不猜。**
    case ambiguousMainTranscript(directory: String, candidates: [String])
}

/// 一个归不进会话的**可归档**文件（如实呈现，不静默丢弃）。
public struct UnmatchedArchivableFile: Equatable, Sendable {

    public let toolID: String

    /// 绝对路径。
    public let path: String

    /// 相对工具根的路径。
    public let relativePath: String

    public let bytes: Int64
    public let lastModified: Date?

    /// 为什么没归组。
    public let gap: SessionGroupingGap

    /// 把它声明为可归档的那条分类条目模式。
    public let pattern: String?

    public init(
        toolID: String,
        path: String,
        relativePath: String,
        bytes: Int64,
        lastModified: Date?,
        gap: SessionGroupingGap,
        pattern: String?
    ) {
        self.toolID = toolID
        self.path = path
        self.relativePath = relativePath
        self.bytes = bytes
        self.lastModified = lastModified
        self.gap = gap
        self.pattern = pattern
    }
}

/// 一台工具的会话归组结果。
public struct ToolSessionReport: Equatable, Sendable {

    public let toolID: String
    public let displayName: String
    public let toolRootPath: String

    /// 会话，按会话 ID 排序。
    public let sessions: [Session]

    /// 归不进会话的可归档文件，按相对路径排序。
    public let unmatched: [UnmatchedArchivableFile]

    /// 本次归组里读不到的位置（权限问题按目录粒度隔离，PRD §4.4）。
    public let unreadable: [UnreadableEntry]

    /// 本次归组里没有被跟随的符号链接（硬约束：不跟随符号链接）。
    public let unfollowedLinks: [UnfollowedLink]

    public init(
        toolID: String,
        displayName: String,
        toolRootPath: String,
        sessions: [Session],
        unmatched: [UnmatchedArchivableFile],
        unreadable: [UnreadableEntry],
        unfollowedLinks: [UnfollowedLink]
    ) {
        self.toolID = toolID
        self.displayName = displayName
        self.toolRootPath = toolRootPath
        self.sessions = sessions
        self.unmatched = unmatched
        self.unreadable = unreadable
        self.unfollowedLinks = unfollowedLinks
    }

    /// 会话内文件的占用合计。
    public var occupancy: Occupancy {
        Occupancy.sum(sessions.map(\.occupancy))
    }

    /// 没归进会话的可归档文件的占用合计。
    public var unmatchedOccupancy: Occupancy {
        Occupancy.sum(unmatched.map { Occupancy(bytes: $0.bytes, fileCount: 1) })
    }

    /// 本工具**全部可归档**文件的占用：会话内 + 未归组。
    ///
    /// 这个数必须与深扫给出的「可归档会话」占用逐字节相等——两层的分类来自同一条
    /// 判定链（`DeepScanRuleCatalog`），分家就说明会话归组漏掉或凭空多出了文件。
    public var archivableOccupancy: Occupancy {
        occupancy + unmatchedOccupancy
    }

    /// 按会话 ID 取一个会话。
    public func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }
}

/// 一次会话归组的完整结果。
public struct SessionGroupingReport: Equatable, Sendable {

    /// 各工具的结果，**按工具标识排序**（顺序不反映扫描顺序，结果必须确定）。
    public let toolReports: [ToolSessionReport]

    public init(toolReports: [ToolSessionReport]) {
        self.toolReports = toolReports
    }

    /// 所有工具的会话，按（工具标识，会话 ID）排序。
    public var sessions: [Session] {
        toolReports.flatMap(\.sessions)
    }

    /// 所有工具里没归进会话的可归档文件。
    public var unmatched: [UnmatchedArchivableFile] {
        toolReports.flatMap(\.unmatched)
    }

    /// 会话内文件的占用合计。
    public var occupancy: Occupancy {
        Occupancy.sum(toolReports.map(\.occupancy))
    }

    /// 全部可归档文件的占用合计（会话内 + 未归组）。
    public var archivableOccupancy: Occupancy {
        Occupancy.sum(toolReports.map(\.archivableOccupancy))
    }

    /// 本次归组里所有读不到的位置。
    public var unreadable: [UnreadableEntry] {
        toolReports.flatMap(\.unreadable)
    }

    /// 本次归组里所有没有被跟随的符号链接。
    public var unfollowedLinks: [UnfollowedLink] {
        toolReports.flatMap(\.unfollowedLinks)
    }

    /// 按工具标识取一份结果。
    public func toolReport(id: String) -> ToolSessionReport? {
        toolReports.first { $0.toolID == id }
    }
}
