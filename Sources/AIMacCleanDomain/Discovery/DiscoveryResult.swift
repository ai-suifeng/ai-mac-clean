import Foundation

/// 扫描时读不到的一个目录（User Story 14：跳过并在结果里说明）。
///
/// 权限错误按**目录粒度**隔离（PRD §4.1）：一个目录读不到只影响它自己，
/// 不影响整体扫描。因此这里只记录，不抛错。
public struct UnreadableDirectory: Equatable, Sendable {

    /// 读不到的目录的绝对路径。
    public let path: String

    /// 读不到的原因（权限不足、路径已消失等），原样保留系统给出的说明。
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

extension UnreadableDirectory: CustomStringConvertible {
    /// 可直接展示给用户的中文说明：哪个位置因此没有被扫描。
    public var description: String {
        "目录 \(path) 无法读取（\(reason)），已跳过，本次扫描未覆盖该位置。"
    }
}

/// 一次浅扫的结果。
///
/// **空结果不是错误**（User Story 13）：没装任何 AI 工具时这里就是一个空候选列表，
/// 外加一份可能为空的可读性说明列表。
public struct DiscoveryResult: Equatable, Sendable {

    /// 候选列表，按置信度从高到低排列。
    public let candidates: [Candidate]

    /// 扫描过程中读不到的目录（权限不足等），逐个说明。
    public let unreadableDirectories: [UnreadableDirectory]

    public init(candidates: [Candidate] = [], unreadableDirectories: [UnreadableDirectory] = []) {
        self.candidates = candidates
        self.unreadableDirectories = unreadableDirectories
    }

    /// 候选的工具根目录路径，供确认存储按路径查记录（`ConfirmationStore.pendingToolRootPaths`）。
    public var candidateToolRootPaths: [String] {
        candidates.map(\.toolRootPath)
    }

    /// 某档置信度的候选。
    public func candidates(withConfidence tier: ConfidenceTier) -> [Candidate] {
        candidates.filter { $0.confidence == tier }
    }
}
