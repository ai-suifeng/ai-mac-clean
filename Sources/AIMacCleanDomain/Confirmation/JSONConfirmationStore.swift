import Foundation

/// 基于本地 JSON 文件的确认存储（PRD §10「已确认工具与清单索引用本地 JSON（位于 Application Support）」）。
///
/// - 数据只落在本机，不做任何同步（User Story 46）。
/// - 本文件**不包含任何网络代码路径**（User Story 45）。
/// - 写入用 Foundation 的原子写（临时文件 + 替换），因此不会留下半截的 JSON。
public final class JSONConfirmationStore: ConfirmationStore {

    /// Application Support 下的子目录名。
    public static let directoryName = "AIMacClean"
    /// 记录文件名。
    public static let fileName = "confirmations.json"
    /// 当前存储格式版本。升级格式时用它决定能否原地读取（拒绝覆盖更高版本的未知格式）。
    public static let currentSchemaVersion = 1

    private let fileURL: URL
    private var recordsByRoot: [String: ConfirmationRecord]

    /// 读盘失败的原因（如 JSON 损坏）。非 `nil` 时本实例**拒绝写入**，不覆盖用户已有判断。
    public let loadFailure: ConfirmationStoreError?

    /// 在指定根目录下打开确认存储。
    ///
    /// - Parameter applicationSupportRoot: Application Support 的根目录。
    ///   根目录由调用方注入而不是在这里读 `FileManager`：测试才能跑在临时目录上，
    ///   绝不会写入真实的 `~/Library/Application Support`（PRD §13 第 3 条）。
    public init(applicationSupportRoot: URL) {
        fileURL = applicationSupportRoot
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)

        let outcome = Self.read(from: fileURL)
        recordsByRoot = outcome.records
        loadFailure = outcome.failure
    }

    /// 应用真实使用的入口：Application Support 由系统决定。
    ///
    /// 仅供应用本体调用；测试一律使用注入根目录的初始化方法。
    public static func standard(fileManager: FileManager = .default) -> JSONConfirmationStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return JSONConfirmationStore(applicationSupportRoot: root)
    }

    // MARK: - 读

    public var confirmedTools: [ConfirmationRecord] {
        allRecords(where: { $0.decision == .confirmed })
    }

    public var ignoredCandidates: [ConfirmationRecord] {
        allRecords(where: { $0.decision == .ignored })
    }

    public func record(forToolRootPath path: String) -> ConfirmationRecord? {
        let key = Self.key(forToolRootPath: path)
        guard !key.isEmpty else { return nil }
        return recordsByRoot[key]
    }

    public func pendingToolRootPaths(amongCandidates candidates: [String]) -> [String] {
        candidates.filter { record(forToolRootPath: $0) == nil }
    }

    // MARK: - 写

    @discardableResult
    public func decide(
        toolIdentifier: String?,
        toolRootPath: String,
        decision: ToolDecision,
        signals: ConfirmationSignals,
        decidedAt: Date
    ) throws -> ConfirmationRecord {
        if let loadFailure {
            throw loadFailure
        }
        let key = Self.key(forToolRootPath: toolRootPath)
        guard !key.isEmpty else {
            throw ConfirmationStoreError.invalidToolRootPath
        }

        // 路径按规范化后的形式存储：同一条记录不会因为尾随分隔符重复出现。
        let record = ConfirmationRecord(
            toolIdentifier: toolIdentifier,
            toolRootPath: key,
            decision: decision,
            signals: signals,
            decidedAt: decidedAt
        )
        recordsByRoot[key] = record
        try persist()
        return record
    }

    @discardableResult
    public func forgetTool(atToolRootPath path: String) throws -> Bool {
        if let loadFailure {
            throw loadFailure
        }
        let key = Self.key(forToolRootPath: path)
        guard !key.isEmpty else {
            throw ConfirmationStoreError.invalidToolRootPath
        }
        guard recordsByRoot.removeValue(forKey: key) != nil else {
            return false
        }
        try persist()
        return true
    }

    // MARK: - 内部

    /// 记录在文件中的键：规范化后的工具根目录路径。
    ///
    /// 只去掉重复与尾随分隔符，**不解析符号链接、不展开 `~`**：
    /// 发现管线不跟随符号链接（GLOSSARY「结构指纹」/ spec #7），在这里解析会把
    /// 两个不同的目录认成同一个，`~/.codex/skills → ~/.agents/skills` 这类链接尤其危险。
    private static func key(forToolRootPath path: String) -> String {
        var text = path
        while text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        // 相对路径原样保留：发现管线给的是绝对路径，相对路径不该由存储层去猜它相对谁。
        guard text.hasPrefix("/") else {
            return text
        }
        return URL(fileURLWithPath: text).standardized.path
    }

    private func allRecords(where predicate: (ConfirmationRecord) -> Bool) -> [ConfirmationRecord] {
        recordsByRoot.values
            .filter(predicate)
            .sorted { lhs, rhs in
                // 同一时刻的记录按路径排序，保证展示顺序稳定。
                lhs.decidedAt == rhs.decidedAt
                    ? lhs.toolRootPath < rhs.toolRootPath
                    : lhs.decidedAt > rhs.decidedAt
            }
    }

    private func persist() throws {
        let file = StoreFile(
            schemaVersion: Self.currentSchemaVersion,
            records: allRecords(where: { _ in true })
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // `.atomic` = 写临时文件再替换，崩溃或断电不会留下半截 JSON。
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            throw ConfirmationStoreError.writeFailed(reason: String(describing: error))
        }
    }

    private static func read(
        from fileURL: URL
    ) -> (records: [String: ConfirmationRecord], failure: ConfirmationStoreError?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([:], nil)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StoreFile.self, from: Data(contentsOf: fileURL))
            guard file.schemaVersion <= currentSchemaVersion else {
                // 比我们新：可能由更高版本的软件写的，读不懂就不动它。
                return (
                    [:],
                    .storeUnreadable(reason: "存储格式版本 \(file.schemaVersion) 高于本版本支持的 \(currentSchemaVersion)")
                )
            }
            var byRoot: [String: ConfirmationRecord] = [:]
            for record in file.records {
                byRoot[key(forToolRootPath: record.toolRootPath)] = record
            }
            return (byRoot, nil)
        } catch {
            return ([:], .storeUnreadable(reason: String(describing: error)))
        }
    }

    /// 磁盘上的文件结构。版本号在前，格式演进时旧文件仍可读。
    private struct StoreFile: Codable {
        var schemaVersion: Int
        var records: [ConfirmationRecord]
    }
}
