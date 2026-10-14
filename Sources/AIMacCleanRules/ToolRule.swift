import Foundation

// MARK: - 工具根目录

/// 工具根目录的角色。
public enum ToolRootRole: String, Codable, CaseIterable, Equatable, Sendable {
    /// 数据根目录：准入与结构指纹匹配的起点。
    case toolRoot
    /// 只展示占用、不参与准入的位置（如 Electron 内部存储）。
    case displayOnly
}

/// 工具在磁盘上的一个位置。
///
/// `path` 是 `$HOME` 相对的（`~/...`）或绝对路径。规则**不在加载期检查这个路径是否存在**——
/// 工具版本演进会让它消失，那属于扫描期「无匹配」，不是加载失败（issue #10 / User Story 22）。
public struct ToolRoot: Codable, Equatable, Sendable {
    public let path: String
    public let role: ToolRootRole

    public init(path: String, role: ToolRootRole = .toolRoot) {
        self.path = path
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case path, role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        role = try container.decodeIfPresent(ToolRootRole.self, forKey: .role) ?? .toolRoot
    }

    /// 路径形状是否合法：必须是 `$HOME` 相对或绝对路径。
    var hasWellFormedPath: Bool {
        path.hasPrefix("~/") || path.hasPrefix("/")
    }
}

// MARK: - 结构指纹

/// 结构指纹：准入一个目录所依据的形状声明（PRD §5.2、spec #7「结构指纹优先」）。
///
/// 这里只声明「长什么样」，不负责比对——比对与打分属于 issue #5。
public struct StructuralFingerprint: Codable, Equatable, Sendable {
    /// 会话转录文件的路径模式，相对工具根目录。
    public let sessionFilePatterns: [PathPattern]
    /// 会话目录的形态（`sessions/<date:year>` 这类）。
    public let sessionDirectoryShapes: [PathPattern]
    /// 项目目录的存在形态（`projects/<encodedPath>` 这类）。
    public let projectDirectoryShapes: [PathPattern]
    /// 只读文件头若干字节里必须出现的 key。
    public let fileHeaderKeys: [String]
    /// 读文件头的字节上限（PRD §13 第 3 条：只读元数据与文件头）。
    public let headerByteLimit: Int

    public init(
        sessionFilePatterns: [PathPattern] = [],
        sessionDirectoryShapes: [PathPattern] = [],
        projectDirectoryShapes: [PathPattern] = [],
        fileHeaderKeys: [String] = [],
        headerByteLimit: Int = 4096
    ) {
        self.sessionFilePatterns = sessionFilePatterns
        self.sessionDirectoryShapes = sessionDirectoryShapes
        self.projectDirectoryShapes = projectDirectoryShapes
        self.fileHeaderKeys = fileHeaderKeys
        self.headerByteLimit = headerByteLimit
    }

    private enum CodingKeys: String, CodingKey {
        case sessionFilePatterns, sessionDirectoryShapes, projectDirectoryShapes, fileHeaderKeys, headerByteLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionFilePatterns = try container.decodePatterns(forKey: .sessionFilePatterns)
        sessionDirectoryShapes = try container.decodePatterns(forKey: .sessionDirectoryShapes)
        projectDirectoryShapes = try container.decodePatterns(forKey: .projectDirectoryShapes)
        fileHeaderKeys = try container.decodeIfPresent([String].self, forKey: .fileHeaderKeys) ?? []
        headerByteLimit = try container.decodeIfPresent(Int.self, forKey: .headerByteLimit) ?? 4096
    }
}

// MARK: - 文件级联

/// 一个会话跨多个文件时，文件之间的关系。
public enum CascadeKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// 与主转录同目录的同级转录（如 `agent-*.jsonl`、`subagents/*.jsonl`）。
    case siblingTranscripts
    /// 以会话 ID 为目录名的关联数据目录（如 `file-history/<会话UUID>/`）。
    case sessionKeyedDirectory
    /// 以会话 ID 命名（或含会话 ID）的关联数据文件（如 `todos/<会话UUID>-agent-<会话UUID>.json`）。
    case sessionKeyedFile
}

/// 一条级联关系声明。
///
/// `pattern` 的基准随 `kind` 而定：`siblingTranscripts` 相对主转录所在目录，
/// 其余两种相对工具根目录。
public struct CascadeRelationship: Codable, Equatable, Sendable {
    public let kind: CascadeKind
    public let pattern: PathPattern

    public init(kind: CascadeKind, pattern: PathPattern) {
        self.kind = kind
        self.pattern = pattern
    }

    private enum CodingKeys: String, CodingKey {
        case kind, pattern
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(CascadeKind.self, forKey: .kind)
        pattern = try container.decodePattern(forKey: .pattern)
    }
}

// MARK: - 项目路径编码

/// 项目路径在磁盘上的编码方案（PRD §5.3）。
///
/// 刻意保持为方案级声明而不是工具级分支：软件本体只认识这几种方案，
/// 新增一个工具就是新增一个规则文件。
public enum ProjectPathEncodingScheme: String, Codable, CaseIterable, Equatable, Sendable {
    /// `/`、`.`、空格 → 单 `-`，前导 `/` → 前导 `-`。
    case singleDash
    /// 每个分隔符 → 双 `--`。
    case doubleDash
    /// 路径不编码，权威来源是文件内字段。
    case inFileField
}

/// 项目路径编码声明。
///
/// 引擎**不依赖逆向解码**还原项目路径：Claude Code 的编码不可无损逆解
/// （`/Users/x/.claude` → `-Users-xiaowei--claude`）。`inFileField` 下的
/// `fieldPath` 是唯一权威来源，其余方案下项目路径只能做存在性校验。
public struct ProjectPathEncoding: Codable, Equatable, Sendable {
    public let scheme: ProjectPathEncodingScheme
    /// `inFileField` 必填：点分隔的文件内字段路径，如 `session_meta.payload.cwd`。
    public let fieldPath: String?
    /// 作者备注，说明该方案的实现细节。
    public let note: String?

    public init(scheme: ProjectPathEncodingScheme, fieldPath: String? = nil, note: String? = nil) {
        self.scheme = scheme
        self.fieldPath = fieldPath
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case scheme, fieldPath, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scheme = try container.decode(ProjectPathEncodingScheme.self, forKey: .scheme)
        fieldPath = try container.decodeIfPresent(String.self, forKey: .fieldPath)
        note = try container.decodeIfPresent(String.self, forKey: .note)

        // 结构合法性：只有「读文件内字段」这一种方案才谈得上有字段路径。
        switch scheme {
        case .inFileField:
            guard let fieldPath, !fieldPath.isEmpty else {
                throw RuleFormatError.invalidFieldValue(field: "projectPathEncoding.fieldPath",
                                                        reason: "编码方案为 inFileField 时必须给出文件内字段路径。")
            }
        case .singleDash, .doubleDash:
            guard fieldPath == nil else {
                throw RuleFormatError.invalidFieldValue(field: "projectPathEncoding.fieldPath",
                                                        reason: "只有 inFileField 方案才允许声明文件内字段路径，当前方案是 \(scheme.rawValue)。")
            }
        }
    }
}

// MARK: - 分类

/// 数据的分类（PRD §5.1）。
///
/// 枚举刻意封闭：规则文件不能凭空发明新类别，也不允许把「不确定」降级为「可归档」
/// （保护单调性由 issue #11 的规则集准入把关，这一层只负责「读得进来」）。
public enum DataCategory: String, Codable, CaseIterable, Equatable, Sendable {
    /// 可归档会话：文件型会话记录及其关联数据。
    case archivableSession
    /// 缓存与日志：只展示占用，不动。
    case cacheAndLog
    /// 受保护：配置、登录凭证、技能、命令。永不触碰。
    case protected
    /// 不确定：无法安全分类的数据。锁定，仅展示占用。
    case uncertain
}

/// 一条分类映射。
public struct ClassificationEntry: Codable, Equatable, Sendable {
    /// 相对工具根目录的路径模式。
    public let pattern: PathPattern
    public let category: DataCategory
    /// 作者备注，说明为什么这样分类。
    public let note: String?

    public init(pattern: PathPattern, category: DataCategory, note: String? = nil) {
        self.pattern = pattern
        self.category = category
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case pattern, category, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try container.decodePattern(forKey: .pattern)

        // 类别是封闭枚举：未知取值要给出指名道姓的可读原因，而不是一个裸的解码错误
        // （否则「凭空新增类别」会退化成一句看不懂的 type mismatch）。
        let rawCategory = try container.decode(String.self, forKey: .category)
        guard let category = DataCategory(rawValue: rawCategory) else {
            throw RuleFormatError.unknownDataCategory(rawCategory)
        }
        self.category = category
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - 会话文件名形态

/// 会话 ID 从哪来。
public enum SessionIDSource: String, Codable, CaseIterable, Equatable, Sendable {
    /// 会话 ID 在转录文件名里。
    case fileName
    /// 会话 ID 在父目录名里（一个会话一个目录）。
    case parentDirectoryName
}

/// 会话文件名形态的声明。
public struct SessionFileNaming: Codable, Equatable, Sendable {
    /// 文件名是否是稳定 ID。fork 出来的会话文件名里含两个 UUID，
    /// 一个逻辑会话会跨多个文件，因此**不是**稳定 ID（PRD §5.4）。
    public let stableSessionIdentifier: Bool
    public let sessionIDSource: SessionIDSource
    public let note: String?

    public init(stableSessionIdentifier: Bool, sessionIDSource: SessionIDSource, note: String? = nil) {
        self.stableSessionIdentifier = stableSessionIdentifier
        self.sessionIDSource = sessionIDSource
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case stableSessionIdentifier, sessionIDSource, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stableSessionIdentifier = try container.decode(Bool.self, forKey: .stableSessionIdentifier)
        sessionIDSource = try container.decode(SessionIDSource.self, forKey: .sessionIDSource)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - 规则

/// 一个工具的声明式规则。
///
/// 规则文件描述「这个工具的数据在哪、长什么样、怎么分类」，
/// 软件本体是通用引擎：新增一个已知工具 = 新增一个规则文件（spec #7 User Story 20）。
public struct ToolRule: Codable, Equatable, Sendable {
    /// 本加载器支持的规则文件版本。
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// 工具标识（稳定 slug，小写短横线）。
    public let id: String
    /// 界面展示名。
    public let displayName: String
    public let roots: [ToolRoot]
    public let structuralFingerprint: StructuralFingerprint?
    public let cascade: [CascadeRelationship]
    public let projectPathEncoding: ProjectPathEncoding?
    public let classification: [ClassificationEntry]
    /// 该工具是否自带压缩（Codex 的 `.zst`、Harness 的 `.zstd`）。
    ///
    /// 自带压缩的文件不再重压缩，走归档的 store 模式（ADR-0001）。本阶段只留声明位。
    public let selfCompressed: Bool
    public let sessionFileNaming: SessionFileNaming?

    public init(
        schemaVersion: Int = ToolRule.currentSchemaVersion,
        id: String,
        displayName: String,
        roots: [ToolRoot],
        structuralFingerprint: StructuralFingerprint? = nil,
        cascade: [CascadeRelationship] = [],
        projectPathEncoding: ProjectPathEncoding? = nil,
        classification: [ClassificationEntry] = [],
        selfCompressed: Bool = false,
        sessionFileNaming: SessionFileNaming? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.roots = roots
        self.structuralFingerprint = structuralFingerprint
        self.cascade = cascade
        self.projectPathEncoding = projectPathEncoding
        self.classification = classification
        self.selfCompressed = selfCompressed
        self.sessionFileNaming = sessionFileNaming
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, displayName, roots, structuralFingerprint, cascade
        case projectPathEncoding, classification, selfCompressed, sessionFileNaming
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard container.contains(.schemaVersion) else {
            throw RuleFormatError.missingRequiredField(field: "schemaVersion")
        }
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == ToolRule.currentSchemaVersion else {
            throw RuleFormatError.unsupportedSchemaVersion(found: version, supported: ToolRule.currentSchemaVersion)
        }
        schemaVersion = version

        for key in [CodingKeys.id, .displayName, .roots] where !container.contains(key) {
            throw RuleFormatError.missingRequiredField(field: key.stringValue)
        }
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        roots = try container.decode([ToolRoot].self, forKey: .roots)

        guard !id.isEmpty else {
            throw RuleFormatError.invalidFieldValue(field: "id", reason: "工具标识不能为空。")
        }
        guard !roots.isEmpty else {
            throw RuleFormatError.invalidFieldValue(field: "roots", reason: "至少要声明一个工具根目录。")
        }
        if let bad = roots.first(where: { !$0.hasWellFormedPath }) {
            throw RuleFormatError.invalidFieldValue(field: "roots.path",
                                                    reason: "路径必须以 ~/ 开头（相对 $HOME）或以 / 开头（绝对路径）：\(bad.path)")
        }

        structuralFingerprint = try container.decodeIfPresent(StructuralFingerprint.self, forKey: .structuralFingerprint)
        cascade = try container.decodeIfPresent([CascadeRelationship].self, forKey: .cascade) ?? []
        projectPathEncoding = try container.decodeIfPresent(ProjectPathEncoding.self, forKey: .projectPathEncoding)
        classification = try container.decodeIfPresent([ClassificationEntry].self, forKey: .classification) ?? []
        selfCompressed = try container.decodeIfPresent(Bool.self, forKey: .selfCompressed) ?? false
        sessionFileNaming = try container.decodeIfPresent(SessionFileNaming.self, forKey: .sessionFileNaming)
    }

    // MARK: 序列化

    /// 规范化的 JSON 字节。
    ///
    /// 键排序、缩进固定、不转义斜杠：同一份规则反复序列化得到同样的字节，
    /// 因此「写入 → 读出 → 再序列化」可以断言等价。
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 从 JSON 字节读入一条规则。
    public static func decode(from data: Data) throws -> ToolRule {
        try JSONDecoder().decode(ToolRule.self, from: data)
    }
}
