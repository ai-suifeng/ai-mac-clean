import Foundation

/// Core 层的通用错误类型。
///
/// 承载的是「基础操作失败」这一类事实，不承载领域语义——
/// 规则集准入的拒绝原因属于 Rules 层（issue #11），会话状态属于 Domain 层（issue #13）。
public enum CoreError: Error, Equatable, Sendable {
    /// 路径不存在或无法访问。
    case pathUnavailable(path: String)
    /// 权限不足，按目录粒度隔离（spec #7：权限错误只影响它自己）。
    case permissionDenied(path: String)
    /// 需要更完整的磁盘访问授权（PRD §15：首次遇到授权失败才提示）。
    case fullDiskAccessRequired(path: String)
    /// 尺寸无法确定。
    case sizeUnavailable(path: String)
}

extension CoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .pathUnavailable(path):
            return "无法访问路径：\(path)"
        case let .permissionDenied(path):
            return "没有读取权限，已跳过：\(path)"
        case let .fullDiskAccessRequired(path):
            return "需要完全磁盘访问权限才能读取：\(path)"
        case let .sizeUnavailable(path):
            return "无法确定占用大小：\(path)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pathUnavailable, .sizeUnavailable:
            return "该路径可能已不存在，或已被移动。"
        case .permissionDenied, .fullDiskAccessRequired:
            return "可在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中为本应用授权后重试。"
        }
    }
}
