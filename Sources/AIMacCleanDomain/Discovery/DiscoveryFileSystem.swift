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

    /// 条目**自身**的**大小与类型**（issue #29 的窄入口）。
    ///
    /// 深扫每个文件只需要这两件事，而 `attributes(ofItemAt:)` 会让 Foundation 构造整本
    /// 属性字典——本机实测 64µs/次，同样一次 `lstat` 只要 3.8µs/次，5 万文件里就是 3 秒。
    /// 因此把这两件事单独收成一个入口：热路径走它，其余读取仍走属性字典。
    ///
    /// 默认实现退回 `attributes(ofItemAt:)`：既有替身（记录器、审计器、并发探针）
    /// **一行都不用改**，记录器照样把这次读取记成一次 `stat`。
    ///
    /// 两项都可以为 `nil`，语义与逐项读属性字典**完全一致**（依次区分「读不到条目」
    /// 「类型不可知」「读不到大小」三种情况），调用方才不会因为走了快路而改变可观察行为。
    func metadata(ofItemAt path: String) -> ItemMetadata?

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

/// 条目自身的**大小与类型**（issue #29）。
///
/// 两项各自可为 `nil`，与逐项读 `attributes(ofItemAt:)` 的语义一一对应：
/// 字典本身读不到 → `metadata` 为 `nil`；没有 `.type` → `type` 为 `nil`；
/// 没有 `.size` → `size` 为 `nil`。
public struct ItemMetadata: Equatable, Sendable {

    public let size: Int64?
    public let type: FileAttributeType?

    public init(size: Int64?, type: FileAttributeType?) {
        self.size = size
        self.type = type
    }
}

public extension DiscoveryFileSystem {

    /// 默认实现：退回属性字典（既有替身因此不必改动），逐项取大小与类型。
    func metadata(ofItemAt path: String) -> ItemMetadata? {
        guard let attributes = attributes(ofItemAt: path) else { return nil }
        return ItemMetadata(
            size: (attributes[.size] as? NSNumber)?.int64Value,
            type: attributes[.type] as? FileAttributeType
        )
    }

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

    /// 一次 `lstat` 直接回答大小与类型（issue #29 的性能切片）。
    ///
    /// 与 `attributes(ofItemAt:)` 的结论逐项一致（`ItemMetadataSeamTests` 用文件、目录、
    /// 符号链接、FIFO、套接字、字符设备逐一对照），但不必为每个文件构造整本属性字典：
    /// 本机实测 64µs → 3.8µs，5 万文件里省下约 3 秒。
    ///
    /// 类型映射与 Foundation 一致：常规 / 目录 / 符号链接 / 字符设备 / 块设备 / 套接字，
    /// 其余（含 FIFO）归为「未知」——`FileAttributeType` 没有 FIFO 这一档。
    public func metadata(ofItemAt path: String) -> ItemMetadata? {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return nil }

        return ItemMetadata(size: Int64(info.st_size), type: Self.fileAttributeType(ofMode: info.st_mode))
    }

    private static func fileAttributeType(ofMode mode: mode_t) -> FileAttributeType {
        switch mode & S_IFMT {
        case S_IFREG: return .typeRegular
        case S_IFDIR: return .typeDirectory
        case S_IFLNK: return .typeSymbolicLink
        case S_IFCHR: return .typeCharacterSpecial
        case S_IFBLK: return .typeBlockSpecial
        case S_IFSOCK: return .typeSocket
        default: return .typeUnknown
        }
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
