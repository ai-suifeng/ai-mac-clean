import Foundation

/// 受保护判定做通配展开时**唯一**会读磁盘的动作：列举一个目录的一级条目名（issue #19）。
///
/// ## 为什么单独成一层
///
/// 「受保护判定不得列举主目录」是本票的核心验收之一。判定要是直接调
/// `FileManager.default.contentsOfDirectory`，这句话就只能靠读代码来相信；
/// 收成可注入的一层之后，它可以被记录、被断言，也能被接到发现器同一份访问记录上
/// （`ToolDiscoverer` 就是这么做的），从而「一次发现的全部列举」一起受检。
///
/// 默认实现是真实文件系统，生产行为不变。读不到时返回 `nil`——那只是「这里没有可展开
/// 的目录」，受保护判定的其余部分同样不因为路径缺失而失败。
///
/// 刻意**不要求 `Sendable`**：与 `DiscoveryFileSystem` 一样，实现可以是带状态的记录器，
/// 而判定本身是同步调用。
public protocol ProtectedPathDirectoryListing {
    func entryNames(inDirectory path: String) -> [String]?
}

/// 真实文件系统：`ProtectedPathDirectoryListing` 的默认实现。
public struct RealProtectedPathDirectoryListing: ProtectedPathDirectoryListing {

    public init() {}

    public func entryNames(inDirectory path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }
}
