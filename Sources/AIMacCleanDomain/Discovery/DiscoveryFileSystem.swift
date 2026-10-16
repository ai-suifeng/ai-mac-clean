import Foundation

/// 浅扫期间的**文件系统读取**（issue #18）。
///
/// ## 为什么要有这一层
///
/// 浅扫的承诺是「只碰 AI 工具的数据目录」（PRD §4.2 新口径）。要能**证明**这句话，
/// 光看候选列表不够——那只能证明「没有多报」，证明不了「没有多看」。
/// 因此把「读磁盘」这件事本身收成可注入的协议：测试套一个记录器，就能断言
/// 一次发现到底访问了哪些路径、访问了多少次。
///
/// 它替代的不是文件系统，而是**直接调用 `FileManager` 的那几处**。
/// 默认实现仍然是真实文件系统（`RealDiscoveryFileSystem`），生产行为不变。
///
/// ## 边界
///
/// - 只暴露浅扫与深扫真正需要的那几件事：列举一级条目名、读条目**自身**属性、
///   读符号链接的目标、读文件开头若干字节。**没有写操作**——深扫全称零写入
///   （issue #23 硬约束），可注入层不提供写入口，也就无从写起。
/// - **不解析符号链接**：`attributes(ofItem:)` 返回的是条目自身的属性，
///   因此判型与「不跟随符号链接」（User Story 12）仍然成立；链接指向哪里由
///   `symbolicLinkDestination(atPath:)` 单独回答（issue #23）。
/// - 列举读不到时**抛错**而不是返回空：由调用方按目录粒度隔离（User Story 14），
///   「读不到」与「目录是空的」必须能区分开。
public protocol DiscoveryFileSystem {

    /// 列举一个目录的一级条目名；读不到时抛错，由调用方按目录粒度隔离。
    func entryNames(inDirectory path: String) throws -> [String]

    /// 条目**自身**的属性；读不到时返回 `nil`（「这里没有可看的东西」，不算错误）。
    func attributes(ofItemAt path: String) -> [FileAttributeKey: Any]?

    /// 读文件开头 `limit` 字节并按 UTF-8 解码；读不到或为空时返回 `nil`。
    ///
    /// 只读开头，绝不为了判断格式而读完整个文件（User Story 11、PRD §13 第 3 条）。
    func readHeader(ofFileAt path: String, limit: Int) -> String?

    /// 符号链接的目标（`readlink`），不是符号链接时返回 `nil`。
    ///
    /// 这是**纯读取**：它回答「这个链接指向哪里」，但绝不因此去访问那个位置
    /// （issue #23 的「不跟随符号链接」）。深扫需要它来区分「工具根内的链接」与
    /// 「指向工具根之外的链接」（PRD §8.2），而两者都不进占用统计。
    ///
    /// 有默认实现（返回 `nil`），因此本方法加入协议不会破坏既有的文件系统替身；
    /// 默认实现下所有链接会被当成「目标未知」，按保守方向处理。
    func symbolicLinkDestination(atPath path: String) -> String?
}

public extension DiscoveryFileSystem {

    /// 默认实现：不报告链接目标。缺席的目标按「未知」保守处理，不影响「不跟随」。
    func symbolicLinkDestination(atPath path: String) -> String? { nil }
}

/// 真实文件系统：`DiscoveryFileSystem` 的默认实现。
///
/// 生产代码不需要显式写它——所有接缝的参数默认值都是这个。
public struct RealDiscoveryFileSystem: DiscoveryFileSystem {

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func entryNames(inDirectory path: String) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: path)
    }

    public func attributes(ofItemAt path: String) -> [FileAttributeKey: Any]? {
        try? fileManager.attributesOfItem(atPath: path)
    }

    public func readHeader(ofFileAt path: String, limit: Int) -> String? {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 符号链接目标；不是符号链接（或读不到）时返回 `nil`。
    public func symbolicLinkDestination(atPath path: String) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: path)
    }
}
