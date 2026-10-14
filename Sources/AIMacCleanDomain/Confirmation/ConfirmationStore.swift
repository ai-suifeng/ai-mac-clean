import Foundation

/// 确认存储（spec #7 §持久化）。
///
/// 这是**唯一**的确认存储接口：UI 与未来的应用服务只认它，不认 `JSONConfirmationStore`。
/// 存储实现因此保持可替换（PRD §10「已确认工具与清单索引用本地 JSON」不是写死的承诺），
/// 但 spec 同时明确：**不为持久化单开测试 seam**——测试直接跑在真实临时文件上，
/// 所以这里没有为可替换性准备任何仓储替身或内存实现。
public protocol ConfirmationStore: AnyObject {

    /// 已确认的工具记录（GLOSSARY「工具」）。
    var confirmedTools: [ConfirmationRecord] { get }

    /// 已忽略的候选记录。
    var ignoredCandidates: [ConfirmationRecord] { get }

    /// 读一个工具根目录当前的记录；没有记录返回 `nil`。
    func record(forToolRootPath: String) -> ConfirmationRecord?

    /// 记录用户的决定（确认 / 忽略）。同一工具根目录再次决定会覆盖旧记录。
    ///
    /// - Parameter decidedAt: 决定发生的时间，由调用方给出——记录的是**用户的动作时刻**。
    @discardableResult
    func decide(
        toolIdentifier: String?,
        toolRootPath: String,
        decision: ToolDecision,
        signals: ConfirmationSignals,
        decidedAt: Date
    ) throws -> ConfirmationRecord

    /// 把某个工具根目录**移出**列表（User Story 17：「我卸载了工具后它不再出现在概览里」）。
    ///
    /// 记录被删除而不是改写成「忽略」：忽略的含义是「这不是 AI 工具」，
    /// 用它来表达「我卸载了」会往忽略列表里塞一条错误的断言。
    /// - Returns: 之前是否存在该记录。
    @discardableResult
    func removeTool(atToolRootPath: String) throws -> Bool

    /// 从候选列表中筛出**尚无记录**的工具根目录，即还需要问用户的那些
    /// （PRD §4.1 第 4 步：确认与忽略的结果都要保存，下次启动不重复询问）。
    func pendingToolRootPaths(amongCandidates candidates: [String]) -> [String]
}

/// 确认存储的失败原因。
public enum ConfirmationStoreError: Error, Equatable, Sendable {
    /// 工具根目录路径为空。
    case invalidToolRootPath
    /// 存储文件已经存在但读不出来，因此**拒绝写入**，以免覆盖用户已有的判断。
    case storeUnreadable(reason: String)
    /// 写入失败。
    case writeFailed(reason: String)
}

extension ConfirmationStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidToolRootPath:
            return "工具根目录路径为空，无法记录。"
        case let .storeUnreadable(reason):
            return "确认记录无法读取（\(reason)）。为避免覆盖已有记录，本次改动未保存。"
        case let .writeFailed(reason):
            return "确认记录保存失败：\(reason)"
        }
    }
}
